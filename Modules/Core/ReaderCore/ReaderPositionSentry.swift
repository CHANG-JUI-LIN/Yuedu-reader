import Foundation

/// Watches the reading position for moves the reader never asked for.
///
/// The reader has had a recurring, hard-to-pin family of bugs — "翻頁跳章節",
/// "章末往前撥會連跳到下一章第二頁" — that users can feel but cannot evidence. The
/// logs needed to diagnose them already exist (`[FlipTrace]`), but reading them
/// requires knowing which of several hundred lines was the wrong one. That judgement
/// is exactly what this type makes mechanical.
///
/// Two invariants, both structural rather than statistical, and neither using a
/// time window — a race hidden behind a timeout is still a race
/// (`Technotes/ReaderPagingContract.md`).
///
/// **G1 — a step lands where the walker said it would.** One page turn moves to one
/// neighbour. For a programmatic turn that neighbour is named up front
/// (`expectStep`); for a gesture, UIKit picks a direction, so the legal set is
/// `{start, before, after}` (`expectGesture`). Landing outside it is the bug, stated
/// directly. This is the guard that catches the current report: the spine only moves
/// by one there, so "jumped too many chapters" would never have seen it.
///
/// **G2 — a jump of two or more chapters was asked for by someone.** Anything that
/// moves the position that far has a named cause: a TOC tap, a TTS anchor, a link, a
/// restore, a source change. Those declare themselves through `declareIntent`.
/// A move that large with nothing declared is a stale index, an evicted layout, or a
/// snapshot from a previous pagination.
///
/// Not a fallback and not a repair: it never changes the position, only reports.
@MainActor
final class ReaderPositionSentry {

    static let shared = ReaderPositionSentry()

    /// What the sentry concluded. Surfaced as a value so the invariants can be tested
    /// without reading them back out of the log.
    struct Report: Equatable {
        let severity: DiagnosticSeverity
        let summary: String
        let detail: String
    }

    /// Reasons the position may legitimately move any distance at all.
    enum JumpIntent: String {
        case tocJump
        case ttsAnchor
        case contentLink
        case openRestore
        case sourceChange
        /// A bookmark, search result, or progress-bar drag.
        case userSeek
    }

    /// Which surface committed the position.
    enum CommitSource: String {
        case pagedTurn
        case scrollSettle
    }

    /// How far a declared intent may stay outstanding, counted in commits rather
    /// than seconds. A jump normally settles in two — the placeholder, then the real
    /// page (`Technotes/ReaderChapterSupply.md` invariant 1). Past this the intent is
    /// dropped so it cannot mask a later real anomaly, and the fact that it never
    /// arrived is itself reported.
    private static let intentCommitBudget = 3

    /// Commits kept for the report attached to an anomaly. Enough to see the run-up
    /// without turning one anomaly into a wall of text.
    private static let trailLimit = 20

    // MARK: - State

    private struct Expectation {
        let start: CoreTextReadingPosition
        /// Positions the turn may legally land on.
        let allowed: [CoreTextReadingPosition]
        let describedAs: String
    }

    private struct Intent {
        let kind: JumpIntent
        let target: CoreTextReadingPosition?
        var unmatchedCommits: Int
    }

    private var expectation: Expectation?
    private var intent: Intent?
    private var lastCommitted: CoreTextReadingPosition?
    private var trail: [String] = []
    private var bookLabel: String = "-"
    private let emit: (Report) -> Void

    init(emit: @escaping (Report) -> Void = ReaderPositionSentry.emitToLog) {
        self.emit = emit
    }

    /// Production sink. An anomaly goes through `AppLogger.anomaly`, which is what
    /// the diagnostics screen counts for its report banner; anything quieter stays a
    /// normal reader log line so the banner is not diluted.
    static func emitToLog(_ report: Report) {
        if report.severity == .anomaly {
            AppLogger.anomaly(report.summary, category: .reader, detail: report.detail)
        } else {
            AppLogger.render("⟐ positionSentry \(report.summary)", level: report.severity)
        }
    }

    // MARK: - Book lifecycle

    /// Clears everything carried over from the previous book. A position from
    /// another book shares no coordinate space with this one, so comparing them
    /// would manufacture anomalies at every book open.
    func beginBook(label: String) {
        expectation = nil
        intent = nil
        lastCommitted = nil
        trail.removeAll(keepingCapacity: true)
        bookLabel = label
        note("beginBook \(label)")
    }

    // MARK: - Declaring movement

    /// Names a move that is allowed to go anywhere. Call *before* the navigation is
    /// issued.
    func declareIntent(_ kind: JumpIntent, target: CoreTextReadingPosition?) {
        intent = Intent(kind: kind, target: target, unmatchedCommits: 0)
        note("intent \(kind.rawValue) target=\(Self.describe(target))")
    }

    /// A page turn the app issued itself, with the single position it resolved to.
    func expectStep(
        from start: CoreTextReadingPosition,
        to destination: CoreTextReadingPosition,
        direction: String
    ) {
        // A deliberate turn ends any outstanding jump episode: the user has moved on,
        // and an intent left standing would suppress the next real anomaly.
        intent = nil
        expectation = Expectation(start: start, allowed: [destination], describedAs: direction)
        note("expect \(direction) from=\(Self.describe(start)) to=\(Self.describe(destination))")
    }

    /// A gesture-driven turn. UIKit has not yet decided which way it goes, and it may
    /// also snap back, so all three outcomes are legal.
    func expectGesture(
        from start: CoreTextReadingPosition,
        before: CoreTextReadingPosition?,
        after: CoreTextReadingPosition?
    ) {
        intent = nil
        var allowed = [start]
        if let before { allowed.append(before) }
        if let after { allowed.append(after) }
        expectation = Expectation(start: start, allowed: allowed, describedAs: "gesture")
        note("expect gesture from=\(Self.describe(start)) before=\(Self.describe(before)) after=\(Self.describe(after))")
    }

    /// Abandons an outstanding expectation — the turn was cancelled before it landed.
    func cancelExpectation() {
        guard expectation != nil else { return }
        expectation = nil
        note("expect cancelled")
    }

    // MARK: - Observing

    /// The position the reader actually settled on.
    ///
    /// `isPlaceholder` matters because a placeholder page is anchored at a real
    /// character offset but its chapter has not finished paginating. By contract it
    /// should not move when the layout lands; until that is proven on real devices,
    /// a disagreement involving one is reported a notch quieter.
    func observeCommit(
        _ position: CoreTextReadingPosition,
        source: CommitSource,
        isPlaceholder: Bool = false
    ) {
        defer { lastCommitted = position }
        note("commit \(source.rawValue)\(isPlaceholder ? " placeholder" : "") \(Self.describe(position))")

        if resolveIntent(against: position) { return }

        if let expectation {
            self.expectation = nil
            guard !expectation.allowed.contains(position) else { return }
            report(
                localized("翻頁落點與步進目的地不符"),
                english: "page turn landed off its stepped destination",
                severity: isPlaceholder ? .notice : .anomaly,
                lines: [
                    "guard=G1 (\(expectation.describedAs))",
                    "start=\(Self.describe(expectation.start))",
                    "expected=\(expectation.allowed.map(Self.describe).joined(separator: " | "))",
                    "landed=\(Self.describe(position))",
                    "placeholder=\(isPlaceholder)",
                ]
            )
            return
        }

        guard let previous = lastCommitted else { return }
        let delta = abs(position.spineIndex - previous.spineIndex)
        guard delta >= 2 else { return }
        report(
            localized("章節位置無故跳動"),
            english: "reading position jumped chapters with nothing asking it to",
            severity: isPlaceholder ? .notice : .anomaly,
            lines: [
                "guard=G2",
                "from=\(Self.describe(previous))",
                "to=\(Self.describe(position))",
                "spineDelta=\(delta)",
                "source=\(source.rawValue)",
                "placeholder=\(isPlaceholder)",
            ]
        )
    }

    // MARK: - Intent bookkeeping

    /// Returns true when this commit is explained by a declared intent.
    private func resolveIntent(against position: CoreTextReadingPosition) -> Bool {
        guard var current = intent else { return false }

        // No target named — the caller knew a jump was coming but not to where. Take
        // the first commit as its landing and stop vouching for anything after it.
        guard let target = current.target else {
            intent = nil
            expectation = nil
            return true
        }

        if target.spineIndex == position.spineIndex {
            intent = nil
            expectation = nil
            return true
        }

        current.unmatchedCommits += 1
        if current.unmatchedCommits >= Self.intentCommitBudget {
            intent = nil
            report(
                localized("導航要求沒有抵達目的地"),
                english: "declared navigation never reached its target",
                severity: .notice,
                lines: [
                    "intent=\(current.kind.rawValue)",
                    "target=\(Self.describe(target))",
                    "settledAt=\(Self.describe(position))",
                    "commitsObserved=\(current.unmatchedCommits)",
                ]
            )
            return false
        }
        intent = current
        // Still on its way — the placeholder commit of a jump in progress.
        return true
    }

    // MARK: - Reporting

    private func report(
        _ chineseSummary: String,
        english: String,
        severity: DiagnosticSeverity,
        lines: [String]
    ) {
        let detail = ([
            "book=\(bookLabel)",
            english,
        ] + lines + ["", "--- recent position events (oldest first) ---"] + trail)
            .joined(separator: "\n")

        emit(Report(severity: severity, summary: chineseSummary, detail: detail))
    }

    private func note(_ line: String) {
        trail.append(line)
        if trail.count > Self.trailLimit { trail.removeFirst(trail.count - Self.trailLimit) }
        AppLogger.render("[FlipTrace] sentry \(line)")
    }

    private static func describe(_ position: CoreTextReadingPosition?) -> String {
        guard let position else { return "nil" }
        let offset = position.charOffset == .max ? "end" : String(position.charOffset)
        return "(ch\(position.spineIndex),off\(offset))"
    }
}
