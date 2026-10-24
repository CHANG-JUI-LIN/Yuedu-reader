import CoreGraphics
import Foundation

/// What a source review card says — its heading, its count, its comments — read out of the
/// SVG it ships as, so a reader's own template (`ReviewCardTemplate`) can draw the same card.
///
/// Sources draw these cards as positioned `<text>` runs and nothing else carries the meaning,
/// so the reading follows how every known card is laid out: a heading run naming the kind
/// (本章说 / 作家說 / 热评 …), a count on the heading's row, then per comment a user row
/// (bold, or with its like count at the row's end) followed by the comment's lines, or signed
/// under them (`—— 书友名`); a link to the full list (`查看全部 〉`) is not a comment. A 作者說
/// is one note: the author's name on a line of its own, set larger than the note, then the
/// note. A card the source built without a heading (起点's dimensionless 神评论, rebuilt by
/// `ReaderHTMLUtilities.normalizeQidianGodReviewImage`) names its kind on the root instead,
/// as `data-yd-card-kind`. A comment the source cut for its card reads whole when the card
/// carries the full text (`ReviewCardFullText`).
struct ReviewCardContent: Equatable, Sendable {
    struct Comment: Equatable, Sendable {
        var user: String
        var likes: String
        var content: String
    }

    var kind: ReaderCommentCardKind
    /// The heading as the source wrote it (本章说, 熱評 …).
    var title: String
    /// The count with its words, as the source wrote it (`12条评论`), arrows dropped.
    var count: String
    /// The count's digits alone (`12`).
    var number: String
    var comments: [Comment]

    /// The attribute a rebuilt card names its kind by.
    static let kindHintAttribute = "data-yd-card-kind"

    /// Reads `svg` as a review card, or nil when it is not one this reading understands —
    /// no heading naming a kind and no kind hint, or nothing a comment could be made of.
    static func extract(from svg: String) -> ReviewCardContent? {
        guard let rootRange = svg.range(of: #"<svg\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let root = String(svg[rootRange])
        let hintedKind = attribute(kindHintAttribute, in: root).flatMap(ReaderCommentCardKind.init(rawValue:))

        var runs = textRuns(in: svg)
        guard !runs.isEmpty else { return nil }

        var kind = hintedKind
        var title = ""
        var headingRow: CGFloat?
        if let index = runs.firstIndex(where: { headingKind(of: $0.text) != nil }) {
            let heading = runs.remove(at: index)
            kind = kind ?? headingKind(of: heading.text)
            title = heading.text
            headingRow = heading.y
        }
        guard let kind else { return nil }

        // A heading with nothing under it is a 热评 pill: what shares its row is the comment,
        // however much it looks like a count (`666`) or a like count (`666赞`).
        let isPill = headingRow.map { row in !runs.contains { !sameRow($0, row) } } ?? false

        var count = ""
        var number = ""
        if !isPill, let countIndex = runs.firstIndex(where: { run in
            countDigits(in: run.text) != nil && !isMarkedLikeCount(run.text)
                && (headingRow.map { sameRow(run, $0) } ?? false)
        }) {
            let run = runs.remove(at: countIndex)
            count = cleanedCount(run.text)
            number = countDigits(in: run.text) ?? ""
        }
        runs.removeAll { isLinkLabel($0.text) }

        var comments = kind == .authorSay
            ? authorNote(from: runs)
            : comments(from: runs, headingRow: headingRow, isPill: isPill)
        if let fullTexts = fullTexts(in: root) {
            for index in comments.indices {
                if let full = ReviewCardFullText.fullText(of: comments[index].content, among: fullTexts) {
                    comments[index].content = full
                }
            }
        }
        guard comments.contains(where: { !$0.content.isEmpty || !$0.user.isEmpty }) else { return nil }
        return ReviewCardContent(kind: kind, title: title, count: count, number: number, comments: comments)
    }

    /// What 氣泡設定's previews fill a template with.
    static func sample(for kind: ReaderCommentCardKind) -> ReviewCardContent {
        switch kind {
        case .chapterSay:
            return ReviewCardContent(
                kind: kind,
                title: kind.localizedTitle,
                count: String(format: localized("%d 條評論"), 128),
                number: "128",
                comments: [
                    Comment(user: localized("範例書友甲"), likes: "57", content: localized("範例評論：這章的轉折完全沒想到，作者太會了。")),
                    Comment(user: localized("範例書友乙"), likes: "12", content: localized("範例評論：追更到這裡，終於等到主角出場。")),
                ]
            )
        case .authorSay:
            return ReviewCardContent(
                kind: kind,
                title: kind.localizedTitle,
                count: "",
                number: "",
                comments: [
                    Comment(user: "", likes: "", content: localized("範例作者說：今天兩更，感謝大家的月票與推薦，我們明天見。")),
                ]
            )
        case .hotComment:
            return ReviewCardContent(
                kind: kind,
                title: kind.localizedTitle,
                count: "",
                number: "",
                comments: [
                    Comment(user: localized("範例書友甲"), likes: "306", content: localized("範例神評論：這一句我反覆看了三遍。")),
                ]
            )
        }
    }

    // MARK: - Reading

    /// The headings sources draw, longest first so 神评论 is not read as 神评.
    private static let headings: [(String, ReaderCommentCardKind)] = [
        ("本章说", .chapterSay), ("本章說", .chapterSay), ("本章讨论", .chapterSay), ("本章討論", .chapterSay),
        ("作者的话", .authorSay), ("作者的話", .authorSay), ("作者说", .authorSay), ("作者說", .authorSay),
        ("作家的话", .authorSay), ("作家的話", .authorSay), ("作家说", .authorSay), ("作家說", .authorSay),
        ("神评论", .hotComment), ("神評論", .hotComment), ("神评", .hotComment), ("神評", .hotComment),
        ("热评", .hotComment), ("熱評", .hotComment),
    ]

    /// A heading is a short run that is the keyword, give or take a little decoration — not a
    /// comment that happens to mention 本章说.
    private static func headingKind(of text: String) -> ReaderCommentCardKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        guard trimmed.count <= 6 else { return nil }
        return headings.first { trimmed.hasPrefix($0.0) }?.1
    }

    /// Counts are written in `0-9`. Not `\d`: the iOS 27 Foundation's
    /// `String.range(of:options: .regularExpression)` matches it against 一 / 十 / 〇 as well
    /// (`NSRegularExpression` does not), and read 「还只是这一批」 as a count.
    private static func countDigits(in text: String) -> String? {
        guard let range = text.range(of: #"[0-9][0-9,.]*\s*[万萬kKwW]?"#, options: .regularExpression) else { return nil }
        let digits = String(text[range]).trimmingCharacters(in: .whitespaces)
        // A count run is the number with its words — `12条评论 〉` — not a sentence.
        let rest = text.replacingCharacters(in: range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.symbols).union(.punctuationCharacters))
        guard rest.count <= 6 else { return nil }
        return digits
    }

    private static func cleanedCount(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "〉❯›>»→")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The labels a card puts on its link to the full list, as 聚合段评's 章末卡 does with
    /// `查看全部 〉` under its comments.
    private static let linkLabels: Set<String> = ["查看全部", "查看更多"]

    private static func isLinkLabel(_ text: String) -> Bool {
        linkLabels.contains(text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)))
    }

    private static func comments(from runs: [TextRun], headingRow: CGFloat?, isPill: Bool) -> [Comment] {
        let rows = rows(of: runs)
        let isHeadingRow: ([TextRun]) -> Bool = { row in headingRow.map { sameRow(row[0], $0) } ?? false }
        // Bold marks a user only where the comments' own lines are not bold: 聚合段评 sets
        // every run of its card bold, and there only the like count tells a user row apart.
        let boldMarksUsers = rows.contains { row in !isHeadingRow(row) && !row.contains(where: \.isBold) }
        var comments: [Comment] = []
        var previousLine: [TextRun]?
        for row in rows {
            if isHeadingRow(row) {
                // A 热评 pill: the comment sits on the heading's own row. So may its like count,
                // with the comment below (聚合段评's 段卡: 神评论 … 👍 4138).
                let likesRun = isPill ? nil : row.last(where: { isMarkedLikeCount($0.text) })
                let line = row.filter { $0 != likesRun }
                comments.append(Comment(
                    user: "",
                    likes: likesRun.map { likeDigits($0.text) } ?? "",
                    content: line.isEmpty ? "" : joined(line)
                ))
                previousLine = nil
                continue
            }
            let likesRun = row.count > 1 ? row.last(where: { isLikeCount($0.text) }) : nil
            let userRun = boldMarksUsers ? row.first { $0.isBold && $0 != likesRun } : nil
            if userRun != nil || likesRun != nil {
                let user = userRun?.text ?? joined(row.filter { $0 != likesRun })
                comments.append(Comment(user: user, likes: likesRun.map { likeDigits($0.text) } ?? "", content: ""))
                previousLine = nil
                continue
            }
            if let name = byline(row, after: previousLine), comments.last?.user.isEmpty == true {
                comments[comments.count - 1].user = name
                previousLine = nil
                continue
            }
            // A comment's lines: wrapped by the source, so they continue the comment above.
            if comments.isEmpty {
                comments.append(Comment(user: "", likes: "", content: ""))
            }
            comments[comments.count - 1].content = appending(row, after: previousLine, to: comments[comments.count - 1].content)
            previousLine = row
        }
        return comments
    }

    /// A 作者說 as one comment: the author's name, when the card sets it on a line of its own
    /// larger than the note (含遇見's 作家說), and every other line as the note.
    private static func authorNote(from runs: [TextRun]) -> [Comment] {
        let rows = rows(of: runs)
        guard let first = rows.first else { return [] }
        var noteRows = rows[...]
        var user = ""
        let noteSize = rows.dropFirst().joined().map(\.fontSize).max()
        if first.count == 1, let noteSize, first[0].fontSize > noteSize + 0.5 {
            user = first[0].text
            noteRows = rows.dropFirst()
        }
        var note = ""
        var previousLine: [TextRun]?
        for row in noteRows {
            note = appending(row, after: previousLine, to: note)
            previousLine = row
        }
        return [Comment(user: user, likes: "", content: note)]
    }

    /// `row` added to a comment's text: on a line of its own when it is set differently from
    /// the line before (a 推薦 line, a sign-off), else as the wrapped continuation it is.
    private static func appending(_ row: [TextRun], after previous: [TextRun]?, to text: String) -> String {
        let line = joined(row)
        guard !text.isEmpty else { return line }
        if let previous, let before = previous.first, let now = row.first,
           before.fontSize != now.fontSize || before.isBold != now.isBold || before.fill != now.fill {
            return text + "\n" + line
        }
        return continued(text, with: line)
    }

    /// Joins a wrapped line onto the text before it: CJK lines meet directly, Latin words
    /// get their space back.
    private static func continued(_ text: String, with line: String) -> String {
        guard let last = text.unicodeScalars.last, let first = line.unicodeScalars.first else { return text + line }
        let isLatin: (Unicode.Scalar) -> Bool = { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        return isLatin(last) && isLatin(first) ? text + " " + line : text + line
    }

    /// A comment's signature underneath it, `—— 书友名`, set smaller than the comment (聚合段评's
    /// 段卡): the comment's user, not one more line of it.
    private static func byline(_ row: [TextRun], after previous: [TextRun]?) -> String? {
        guard row.count == 1, let previous = previous?.first, row[0].fontSize < previous.fontSize,
              let dash = row[0].text.range(of: #"^[—―-]+\s*"#, options: .regularExpression) else { return nil }
        let name = row[0].text[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static let likeMarks = #"[♡♥❤️👍赞讚点贊]"#

    private static func isLikeCount(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: likeMarks, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return !stripped.isEmpty && stripped.range(of: #"^[0-9][0-9,.]*\s*[万萬kKwW]?$"#, options: .regularExpression) != nil
    }

    /// A like count that says so (`👍 4138`): beside a heading it is the comment's likes, not the
    /// card's count.
    private static func isMarkedLikeCount(_ text: String) -> Bool {
        isLikeCount(text) && text.range(of: likeMarks, options: .regularExpression) != nil
    }

    private static func likeDigits(_ text: String) -> String {
        guard let range = text.range(of: #"[0-9][0-9,.]*\s*[万萬kKwW]?"#, options: .regularExpression) else { return "" }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func joined(_ row: [TextRun]) -> String {
        row.map(\.text).joined(separator: " ")
    }

    // MARK: - Runs and rows

    private struct TextRun: Equatable {
        let x: CGFloat
        let y: CGFloat
        let fontSize: CGFloat
        let isBold: Bool
        /// The run's `fill`, lowercased; nil when it inherits one.
        let fill: String?
        let text: String
    }

    private static func sameRow(_ run: TextRun, _ y: CGFloat) -> Bool {
        abs(run.y - y) <= max(run.fontSize * 0.5, 4)
    }

    /// Runs grouped into rows by baseline, top to bottom, each left to right.
    private static func rows(of runs: [TextRun]) -> [[TextRun]] {
        var rows: [[TextRun]] = []
        for run in runs.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            if let last = rows.last?.first, sameRow(run, last.y) {
                rows[rows.count - 1].append(run)
            } else {
                rows.append([run])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }

    private static func textRuns(in svg: String) -> [TextRun] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<text\b([^>]*)>(.*?)</text>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = svg as NSString
        var previousY: CGFloat = 0
        return regex.matches(in: svg, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let attributes = ns.substring(with: match.range(at: 1))
            let raw = ns.substring(with: match.range(at: 2))
            let text = decodedEntities(
                raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A run with no y of its own continues where the last one was.
            let y = attribute("y", in: attributes).flatMap(number) ?? previousY
            previousY = y
            let weight = (attribute("font-weight", in: attributes) ?? styleValue("font-weight", in: attributes) ?? "")
                .lowercased()
            let isBold = weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600
            return TextRun(
                x: attribute("x", in: attributes).flatMap(number) ?? 0,
                y: y,
                fontSize: (attribute("font-size", in: attributes) ?? styleValue("font-size", in: attributes))
                    .flatMap(number) ?? 16,
                isBold: isBold,
                fill: (attribute("fill", in: attributes) ?? styleValue("fill", in: attributes))?.lowercased(),
                text: text
            )
        }
    }

    /// The comments the source cut, whole again (`ReviewCardFullText`).
    private static func fullTexts(in root: String) -> [String]? {
        guard let value = attribute(ReviewCardFullText.attribute, in: root) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: Data(decodedEntities(value).utf8)) as? [String]
        } catch {
            AppLogger.parse("⟐ reviewCard fullText unreadable", error: error)
            return nil
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?:^|\\s)\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in [2, 3] where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
    }

    private static func styleValue(_ property: String, in attributes: String) -> String? {
        guard let style = attribute("style", in: attributes),
              let range = style.range(
                of: "\(NSRegularExpression.escapedPattern(for: property))\\s*:\\s*([^;]+)",
                options: [.regularExpression, .caseInsensitive]
              ) else { return nil }
        let declaration = String(style[range])
        guard let colon = declaration.firstIndex(of: ":") else { return nil }
        return declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func number(_ raw: String) -> CGFloat? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // `y="20 40"` lists a position per glyph; the first one is the run's.
        if let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "," }).first {
            trimmed = String(first)
        }
        for unit in ["px", "pt"] where trimmed.hasSuffix(unit) {
            trimmed = String(trimmed.dropLast(unit.count))
        }
        return Double(trimmed).map { CGFloat($0) }
    }

    private static func decodedEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            var decoded = ""
            var cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                decoded += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let isHex = match.range(at: 1).length > 0
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    decoded += String(Character(scalar))
                } else {
                    decoded += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            decoded += ns.substring(from: cursor)
            result = decoded
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
