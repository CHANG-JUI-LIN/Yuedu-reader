import CryptoKit
import Testing
import UIKit
@testable import yuedu_app

/// LINE-BREAK REGRESSION NET for the whole book.
///
/// Phase 3 (CSS Float) moves line layout out of `BoxTreeBuilder` (where it runs
/// today, at box-tree build time) and into `BlockLayout`, because a float's
/// exclusion region is a function of the block position `y` — which does not
/// exist yet when the lines are currently shaped. That reorder touches EVERY
/// chapter, not just the 5 that actually float, so it needs a net first.
///
/// The net is a per-chapter fingerprint of every laid-out line: its rect and a
/// hash of its text. Book text is NEVER written to disk — only geometry and
/// digests — so the golden is committable and small (one line per chapter).
///
/// Regenerate deliberately with `YUEDU_LINEBREAK_REGEN=1`; a run with no golden
/// present writes one and reports that it did, rather than passing silently.
@MainActor
struct BrowserLayoutLineBreakBaselineTests {

    static let viewport = CGSize(width: 390, height: 844)
    static let settings = ReaderRenderSettings(
        theme: "paper", textColor: .black, backgroundColor: .white,
        fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
        letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
        contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    )
    static var contentSize: CGSize {
        CGSize(width: viewport.width - settings.contentInsets.left - settings.contentInsets.right,
               height: viewport.height - settings.contentInsets.top - settings.contentInsets.bottom)
    }

    nonisolated static var epubPath: String? {
        if let env = ProcessInfo.processInfo.environment["YUEDU_HONGLOUMENG_EPUB_PATH"], !env.isEmpty {
            return env
        }
        let local = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub"
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    /// Repo-relative golden, resolved from this source file's own location.
    nonisolated static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // yuedu appTests
            .deletingLastPathComponent()   // iOS
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/browser-layout/line-break-baseline/redchamber.tsv")
    }

    nonisolated static var attributionURL: URL {
        goldenURL.deletingLastPathComponent()
            .appendingPathComponent("attribution-2026-08-31.tsv")
    }

    nonisolated static var coreTextNormalizationAttributionURL: URL {
        goldenURL.deletingLastPathComponent()
            .appendingPathComponent("coretext-advance-normalization-attribution-2026-09-02.tsv")
    }

    nonisolated static var approvedUpdateRequested: Bool {
        FileManager.default.fileExists(
            atPath: "/tmp/yuedu-update-linebreak-baseline-approved"
        )
    }

    nonisolated static var coreTextNormalizationUpdateRequested: Bool {
        FileManager.default.fileExists(
            atPath: "/tmp/yuedu-update-linebreak-coretext-normalization-approved"
        )
    }

    /// Chapters to cover. Default: the whole spine. `YUEDU_LINEBREAK_STRIDE=n`
    /// samples every n-th chapter for a fast local loop.
    nonisolated static var stride: Int {
        Int(ProcessInfo.processInfo.environment["YUEDU_LINEBREAK_STRIDE"] ?? "") ?? 1
    }

    // MARK: - Fingerprint

    /// `spine <TAB> pages <TAB> lines <TAB> firstRect <TAB> lastRect <TAB> sha`
    /// Text never appears — only its digest, folded into `sha`.
    struct ChapterPrint: Equatable {
        var spine: Int
        var pages: Int
        var lines: Int
        var first: String
        var last: String
        var sha: String

        var row: String { "\(spine)\t\(pages)\t\(lines)\t\(first)\t\(last)\t\(sha)" }

        static func parse(_ row: String) -> ChapterPrint? {
            let f = row.components(separatedBy: "\t")
            guard f.count == 6, let spine = Int(f[0]), let pages = Int(f[1]), let lines = Int(f[2]) else {
                return nil
            }
            return ChapterPrint(spine: spine, pages: pages, lines: lines,
                                first: f[3], last: f[4], sha: f[5])
        }
    }

    struct AttributionRow {
        let spine: Int
        let classification: String
        let provenance: String
        let goldenPages: Int
        let afterPages: Int
        let goldenLines: Int
        let afterLines: Int

        static func parse(_ row: String) -> AttributionRow? {
            let fields = row.components(separatedBy: "\t")
            guard fields.count == 12,
                  let spine = Int(fields[0]),
                  let goldenPages = Int(fields[6]),
                  let afterPages = Int(fields[8]),
                  let goldenLines = Int(fields[9]),
                  let afterLines = Int(fields[11]) else {
                return nil
            }
            return AttributionRow(
                spine: spine,
                classification: fields[1],
                provenance: fields[3],
                goldenPages: goldenPages,
                afterPages: afterPages,
                goldenLines: goldenLines,
                afterLines: afterLines
            )
        }
    }

    static func rect(_ r: CGRect) -> String {
        String(format: "%.2f,%.2f,%.2f,%.2f", r.minX, r.minY, r.width, r.height)
    }

    static func fingerprint(spine: Int, pages: [PageFragments], sourceText: String) -> ChapterPrint {
        var details: [String] = []
        for page in pages {
            for fragment in BrowserLayoutTestSupport.allTextFragments([page]) {
                let ns = sourceText as NSString
                let text: String
                if fragment.sourceRange.location >= 0,
                   fragment.sourceRange.location + fragment.sourceRange.length <= ns.length,
                   fragment.sourceRange.length > 0 {
                    text = ns.substring(with: fragment.sourceRange)
                } else {
                    text = ""
                }
                var hasher = SHA256()
                hasher.update(data: Data(text.utf8))
                let textDigest = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined().prefix(8)
                details.append("\(rect(fragment.rect.rawValue))|\(String(format: "%.2f", fragment.baselineY))|\(textDigest)")
            }
        }
        var all = SHA256()
        all.update(data: Data(details.joined(separator: "\n").utf8))
        let sha = all.finalize().compactMap { String(format: "%02x", $0) }.joined()
        return ChapterPrint(
            spine: spine, pages: pages.count, lines: details.count,
            first: details.first ?? "-", last: details.last ?? "-", sha: String(sha.prefix(16))
        )
    }

    // MARK: - Layout one chapter exactly as the batch path does

    static func layout(session: PublicationSession, spine: Int) async -> (pages: [PageFragments], sourceText: String)? {
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        guard let html = try? await adapter.chapterHTML(at: spine), !html.isEmpty else { return nil }
        let css = await adapter.processedCSS(forChapter: spine)
        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
        guard scan.supported else { return nil }
        let images = await adapter.prefetchImages(
            forChapter: spine, html: html, renderWidth: contentSize.width
        )
        let config = BrowserLayoutConfig(
            renderWidth: contentSize.width, renderHeight: contentSize.height,
            rootFontSize: settings.fontSize, fontFamilies: [],
            textColor: settings.textColor, backgroundColor: settings.backgroundColor,
            contentInsets: settings.contentInsets, lineHeight: settings.lineHeightMultiple,
            fontResolver: adapter.fontResolver()
        )
        var metrics = LayoutMetrics()
        guard let frontend = try? LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: config,
            metrics: &metrics
        ) else { return nil }
        let zeroRoot = cloneWithZeroTextIndent(frontend.rootNode)
        guard HorizontalRubySupport.validate(
            zeroRoot,
            writingMode: config.writingMode
        ).isSupported else { return nil }

        var sourceText = SourceTextBuilder()
        var anchors: [String: Int] = [:]
        let rootBox = BoxTreeBuilder.buildBlock(
            for: zeroRoot,
            config: config,
            sourceText: &sourceText,
            anchors: &anchors,
            imageLoader: { images[$0] }
        )
        _ = BlockLayout.layOut(
            root: rootBox,
            containerWidth: contentSize.width,
            inlineContainingSize: config.renderWidth,
            rootFontSize: config.rootFontSize,
            writingMode: config.writingMode,
            sourceText: sourceText.text,
            fontResolver: config.fontResolver,
            fragmentHeight: contentSize.height
        )
        let pages = PageFragmentation.fragment(
            box: rootBox,
            pageSize: viewport,
            contentInsets: settings.contentInsets
        )
        return (pages, sourceText.text)
    }

    /// This golden predates CSS text-indent and remains the no-indent ordinary
    /// inline geometry gate. Phase 4E1 changes are covered by their own
    /// attributed corpus comparison; do not re-record this baseline for them.
    static func cloneWithZeroTextIndent(_ node: ComputedStyleNode) -> ComputedStyleNode {
        var style = node.style
        style.textIndent = .initial
        let children = node.children.map { child -> StyleTreeChild in
            switch child {
            case .text(let text):
                return .text(text)
            case .element(let element):
                return .element(cloneWithZeroTextIndent(element))
            }
        }
        return ComputedStyleNode(
            tag: node.tag,
            element: node.element,
            style: style,
            children: children,
            nodeID: node.nodeID,
            linkTarget: node.linkTarget,
            anchorID: node.anchorID
        )
    }

    // MARK: - The net

    @Test("line breaking is byte-identical across the whole book", .enabled(if: epubPath != nil))
    func lineBreakingMatchesGolden() async throws {
        let path = try #require(Self.epubPath)
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))

        var prints: [ChapterPrint] = []
        var skipped: [Int] = []
        let started = Date()
        for spine in Swift.stride(from: 0, to: session.chapters.count, by: Self.stride) {
            guard let (pages, sourceText) = await Self.layout(session: session, spine: spine) else {
                skipped.append(spine)
                continue
            }
            prints.append(Self.fingerprint(spine: spine, pages: pages, sourceText: sourceText))
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        print("LINEBREAK covered=\(prints.count) skipped(unsupported)=\(skipped.count) stride=\(Self.stride) in \(elapsed)s")

        let regen = ProcessInfo.processInfo.environment["YUEDU_LINEBREAK_REGEN"] == "1"
        let url = Self.goldenURL
        let existing = try? String(contentsOf: url, encoding: .utf8)

        if regen || existing == nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let body = ([
                "# line-break baseline — geometry + text DIGESTS only, no book text",
                "# spine\tpages\tlines\tfirstLine\tlastLine\tsha",
            ] + prints.map(\.row)).joined(separator: "\n") + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
            // A missing golden must NOT pass silently — the net only has value
            // once it exists and a later run compares against it.
            #expect(regen, "no golden existed; wrote \(prints.count) chapters to \(url.path). Re-run to compare.")
            return
        }

        let goldenRows = existing!
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { ChapterPrint.parse(String($0)) }
        #expect(!goldenRows.isEmpty, "golden is present but unparsable: \(url.path)")

        let goldenBySpine = Dictionary(uniqueKeysWithValues: goldenRows.map { ($0.spine, $0) })
        let mineBySpine = Dictionary(uniqueKeysWithValues: prints.map { ($0.spine, $0) })

        let onlyGolden = Set(goldenBySpine.keys).subtracting(mineBySpine.keys).sorted().prefix(10)
        let onlyNow = Set(mineBySpine.keys).subtracting(goldenBySpine.keys).sorted().prefix(10)
        let coverageNote = "chapter coverage changed: only-in-golden=\(Array(onlyGolden)) only-now=\(Array(onlyNow))"
        #expect(Set(goldenBySpine.keys) == Set(mineBySpine.keys), "\(coverageNote)")

        if Self.coreTextNormalizationUpdateRequested {
            try Self.updateCoreTextNormalizationRows(
                existing: existing!,
                goldenBySpine: goldenBySpine,
                currentBySpine: mineBySpine,
                url: url
            )
            return
        }

        if Self.approvedUpdateRequested {
            try Self.updateApprovedRows(
                existing: existing!,
                goldenBySpine: goldenBySpine,
                currentBySpine: mineBySpine,
                url: url
            )
            return
        }

        var changed: [String] = []
        for (spine, want) in goldenBySpine.sorted(by: { $0.key < $1.key }) {
            guard let got = mineBySpine[spine] else { continue }
            guard got != want else { continue }
            changed.append(
                "spine \(spine): pages \(want.pages)→\(got.pages) lines \(want.lines)→\(got.lines)\n"
                + "    first  want=\(want.first)\n           got =\(got.first)\n"
                + "    last   want=\(want.last)\n           got =\(got.last)"
            )
        }
        let changedNote = "\(changed.count) chapters changed their line breaking:\n"
            + changed.prefix(8).joined(separator: "\n")
        #expect(changed.isEmpty, "\(changedNote)")
    }

    nonisolated static func updateApprovedRows(
        existing: String,
        goldenBySpine: [Int: ChapterPrint],
        currentBySpine: [Int: ChapterPrint],
        url: URL
    ) throws {
        let attributionText = try String(contentsOf: attributionURL, encoding: .utf8)
        let attributionRows = attributionText
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("spine\t") }
            .compactMap { AttributionRow.parse(String($0)) }
        let attributionBySpine = Dictionary(
            uniqueKeysWithValues: attributionRows.map { ($0.spine, $0) }
        )
        let expectedGroupCounts = [
            "ROOT_FRAGMENT_X": 32,
            "USED_VALUE_FINAL_WIDTH": 243,
            "USED_VALUE_FINAL_WIDTH+LINE_HEIGHT_FINALIZATION": 115,
            "PHASE_4F0_HINTS+USED_VALUE_FINAL_WIDTH": 43,
        ]
        let actualGroupCounts = Dictionary(grouping: attributionRows, by: \.provenance)
            .mapValues(\.count)

        guard attributionRows.count == 433,
              attributionBySpine.count == attributionRows.count,
              actualGroupCounts == expectedGroupCounts else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey:
                    "attribution gate mismatch rows=\(attributionRows.count) groups=\(actualGroupCounts)"]
            )
        }

        let changedSpines = Set(goldenBySpine.compactMap { spine, golden in
            currentBySpine[spine] == golden ? nil : spine
        })
        let attributedSpines = Set(attributionBySpine.keys)
        guard changedSpines == attributedSpines else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey:
                    "approved diff set mismatch only-current=\(changedSpines.subtracting(attributedSpines).sorted()) "
                    + "only-attribution=\(attributedSpines.subtracting(changedSpines).sorted())"]
            )
        }

        for attribution in attributionRows {
            guard let golden = goldenBySpine[attribution.spine],
                  let current = currentBySpine[attribution.spine],
                  golden.pages == attribution.goldenPages,
                  current.pages == attribution.afterPages,
                  golden.lines == attribution.goldenLines,
                  current.lines == attribution.afterLines else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [NSLocalizedDescriptionKey:
                        "attribution row drift at spine \(attribution.spine)"]
                )
            }
            if attribution.provenance == "ROOT_FRAGMENT_X" {
                guard attribution.classification == "EXPECTED_X_ONLY",
                      golden.pages == current.pages,
                      golden.lines == current.lines else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSLocalizedDescriptionKey:
                            "root-X row changed line/page count at spine \(attribution.spine)"]
                    )
                }
            }
        }

        for provenance in expectedGroupCounts.keys.sorted() {
            let group = attributionRows.filter { $0.provenance == provenance }
            let oldPages = group.reduce(0) { $0 + $1.goldenPages }
            let newPages = group.reduce(0) { $0 + $1.afterPages }
            let oldLines = group.reduce(0) { $0 + $1.goldenLines }
            let newLines = group.reduce(0) { $0 + $1.afterLines }
            print(
                "LINEBREAK_APPROVED_GROUP provenance=\(provenance) rows=\(group.count) "
                    + "pages=\(oldPages)->\(newPages) textFragments=\(oldLines)->\(newLines)"
            )
        }

        let updatedLines = existing.split(separator: "\n", omittingEmptySubsequences: false).map {
            line -> String in
            let value = String(line)
            guard let golden = ChapterPrint.parse(value),
                  attributedSpines.contains(golden.spine),
                  let current = currentBySpine[golden.spine] else {
                return value
            }
            return current.row
        }
        let updated = updatedLines.joined(separator: "\n")
        try updated.write(to: url, atomically: true, encoding: .utf8)
        print(
            "LINEBREAK_APPROVED_UPDATE wrote=\(attributedSpines.count) "
                + "preserved=\(goldenBySpine.count - attributedSpines.count) path=\(url.path)"
        )
    }

    nonisolated static func updateCoreTextNormalizationRows(
        existing: String,
        goldenBySpine: [Int: ChapterPrint],
        currentBySpine: [Int: ChapterPrint],
        url: URL
    ) throws {
        let attributionText = try String(
            contentsOf: coreTextNormalizationAttributionURL,
            encoding: .utf8
        )
        let attributionRows = attributionText
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("spine\t") }
            .compactMap { AttributionRow.parse(String($0)) }
        let attributionBySpine = Dictionary(
            uniqueKeysWithValues: attributionRows.map { ($0.spine, $0) }
        )
        let changedSpines = Set(goldenBySpine.compactMap { spine, golden in
            currentBySpine[spine] == golden ? nil : spine
        })
        let attributedSpines = Set(attributionBySpine.keys)

        guard attributionRows.count == 18,
              attributionBySpine.count == attributionRows.count,
              changedSpines == attributedSpines else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey:
                    "CoreText normalization attribution mismatch rows=\(attributionRows.count) "
                    + "only-current=\(changedSpines.subtracting(attributedSpines).sorted()) "
                    + "only-attribution=\(attributedSpines.subtracting(changedSpines).sorted())"]
            )
        }

        for attribution in attributionRows {
            guard attribution.classification == "EXPECTED_SUBNANOPOINT_X_ONLY",
                  attribution.provenance == "CORETEXT_ADVANCE_NORMALIZATION",
                  let golden = goldenBySpine[attribution.spine],
                  let current = currentBySpine[attribution.spine],
                  golden.pages == current.pages,
                  golden.lines == current.lines,
                  golden.pages == attribution.goldenPages,
                  current.pages == attribution.afterPages,
                  golden.lines == attribution.goldenLines,
                  current.lines == attribution.afterLines else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [NSLocalizedDescriptionKey:
                        "CoreText normalization row drift at spine \(attribution.spine)"]
                )
            }
        }

        let updatedLines = existing.split(separator: "\n", omittingEmptySubsequences: false).map {
            line -> String in
            let value = String(line)
            guard let golden = ChapterPrint.parse(value),
                  attributedSpines.contains(golden.spine),
                  let current = currentBySpine[golden.spine] else {
                return value
            }
            return current.row
        }
        try updatedLines.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        print(
            "LINEBREAK_CORETEXT_NORMALIZATION_UPDATE wrote=\(attributedSpines.count) "
                + "pages=\(attributionRows.reduce(0) { $0 + $1.goldenPages })"
                + "->\(attributionRows.reduce(0) { $0 + $1.afterPages }) "
                + "textFragments=\(attributionRows.reduce(0) { $0 + $1.goldenLines })"
                + "->\(attributionRows.reduce(0) { $0 + $1.afterLines })"
        )
    }
}
