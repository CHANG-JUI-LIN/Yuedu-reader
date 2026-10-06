import Foundation

/// One chapter of a converted Aozora book: the blocks it holds, its entries in
/// the table of contents, its text as both engines read it, and where that
/// text comes from in the source.
struct AozoraChapter: Equatable, Sendable {
    enum Role: Equatable, Sendable { case titlePage, body, colophon }
    var role: Role
    var spans: [AozoraBlockSpan]
    var navigation: [AozoraNavigationEntry]
    /// Each block's displayed text followed by "\n"; page breaks add nothing.
    var text: String
    /// Between UTF-16 offsets of `text` and of the source text.
    var sourceMap: AozoraSourceMap
}

struct AozoraNavigationEntry: Equatable, Sendable {
    var title: String
    /// 1 大, 2 中, 3 小. The title page, parts and the colophon are 1.
    var level: Int
    /// The element id, or nil for the chapter's start.
    var anchor: String?
}

/// Cuts an Aozora document into EPUB chapters and their navigation
/// (docs/superpowers/plans/2026-10-05-aozora-bunko-support.md, Task 14):
/// - the header is the title page, and the colophon is the last chapter;
/// - a 大見出し or 中見出し block starts a chapter, and every page break ends one;
/// - blank blocks at a chapter's edges go, and an empty chapter goes;
/// - a chapter longer than `limit` splits before the block that would cross it.
enum AozoraChapterPlanner {
    /// The TXT path splits at 100 KB of source bytes (`TXTChapterParser`), which
    /// is 51,200 characters of Shift_JIS text.
    static let limit = 51_200

    /// The element id of a heading: `h` and its block's index among all spans, so
    /// regeneration keeps it; a block's second inline heading and later add `-2`, `-3`, ….
    static func anchor(blockIndex: Int, ordinal: Int = 1) -> String {
        ordinal == 1 ? "h\(blockIndex)" : "h\(blockIndex)-\(ordinal)"
    }

    static func plan(_ document: AozoraDocument, source: String, limit: Int = limit) -> [AozoraChapter] {
        let units = Array(source.utf16)
        let spans = document.blockSpans
        func block(_ span: AozoraBlockSpan) -> AozoraBlock {
            switch span.section {
            case .header: return document.headerBlocks[span.index]
            case .body: return document.body[span.index]
            case .colophon: return document.colophon[span.index]
            }
        }
        let workTitle = document.header?.title ?? document.headerBlocks.first?.displayedText ?? ""

        // Chapters as runs of positions in `spans`.
        struct Draft {
            var role: AozoraChapter.Role
            var positions: [Int] = []
        }
        var drafts: [Draft] = []
        var current: Draft?
        func close() {
            if let draft = current { drafts.append(draft) }
            current = nil
        }
        for (position, span) in spans.enumerated() {
            let role: AozoraChapter.Role = switch span.section {
            case .header: .titlePage
            case .body: .body
            case .colophon: .colophon
            }
            if current?.role != role { close() }
            switch block(span) {
            case .pageBreak:
                close()
                continue
            case .heading(let level, _, _, _) where role == .body && level != .small:
                close()
            default:
                break
            }
            if current == nil { current = Draft(role: role) }
            current?.positions.append(position)
        }
        close()

        func isBlank(_ position: Int) -> Bool {
            if case .paragraph = block(spans[position]) { return block(spans[position]).displayedText.isEmpty }
            return false
        }
        func trimmed(_ positions: [Int]) -> [Int] {
            guard let first = positions.firstIndex(where: { !isBlank($0) }),
                  let last = positions.lastIndex(where: { !isBlank($0) }) else { return [] }
            return Array(positions[first...last])
        }
        func cost(_ position: Int) -> Int { block(spans[position]).displayedText.utf16.count + 1 }
        func parts(of positions: [Int]) -> [[Int]] {
            var result: [[Int]] = []
            var part: [Int] = []
            var length = 0
            for position in positions {
                if !part.isEmpty, length + cost(position) > limit {
                    result.append(part)
                    part = []
                    length = 0
                }
                part.append(position)
                length += cost(position)
            }
            if !part.isEmpty { result.append(part) }
            return result.map(trimmed).filter { !$0.isEmpty }
        }

        var chapters: [AozoraChapter] = []
        var lastHeadingTitle: String?
        for draft in drafts {
            let positions = trimmed(draft.positions)
            guard !positions.isEmpty else { continue }
            let pieces = draft.role == .body ? parts(of: positions) : [positions]
            // The chapter's own title: the heading it starts with.
            var startTitle: (title: String, level: Int)?
            if case .heading(let level, _, let inlines, _) = block(spans[positions[0]]), isListed(headingTitle(inlines)) {
                startTitle = (headingTitle(inlines), level.navigationLevel)
            }
            let partTitle = startTitle?.title ?? lastHeadingTitle ?? workTitle
            for (pieceIndex, piece) in pieces.enumerated() {
                var navigation: [AozoraNavigationEntry] = []
                switch draft.role {
                case .titlePage where isListed(workTitle):
                    navigation.append(AozoraNavigationEntry(title: workTitle, level: 1, anchor: nil))
                case .titlePage:
                    break
                case .colophon:
                    navigation.append(AozoraNavigationEntry(title: "底本", level: 1, anchor: nil))
                case .body:
                    if pieces.count > 1 {
                        navigation.append(AozoraNavigationEntry(title: "\(partTitle)(\(pieceIndex + 1))", level: 1, anchor: nil))
                    } else if let startTitle {
                        navigation.append(AozoraNavigationEntry(title: startTitle.title, level: startTitle.level, anchor: nil))
                    }
                    for position in piece {
                        let isStart = pieceIndex == 0 && position == positions[0] && startTitle != nil
                        for entry in headings(in: block(spans[position]), blockIndex: position) where !isStart {
                            navigation.append(entry)
                        }
                    }
                }
                chapters.append(chapter(role: draft.role, positions: piece, navigation: navigation,
                                        document: document, units: units, block: block))
            }
            // A chapter without a heading of its own, split into parts, names them after
            // the last heading before it.
            if let last = positions.flatMap({ headings(in: block(spans[$0]), blockIndex: $0) }).last {
                lastHeadingTitle = last.title
            }
        }
        return chapters
    }

    /// The table-of-contents entries for the headings a block holds: the block
    /// itself when it is a heading, and every inline heading in it, but for one
    /// whose title shows nothing.
    private static func headings(in block: AozoraBlock, blockIndex: Int) -> [AozoraNavigationEntry] {
        allHeadings(in: block, blockIndex: blockIndex).filter { isListed($0.title) }
    }

    /// Every heading, numbered as the writer numbers their ids.
    private static func allHeadings(in block: AozoraBlock, blockIndex: Int) -> [AozoraNavigationEntry] {
        switch block {
        case .heading(let level, _, let inlines, _):
            return [AozoraNavigationEntry(title: headingTitle(inlines), level: level.navigationLevel,
                                          anchor: anchor(blockIndex: blockIndex))]
        case .paragraph(let inlines, _):
            var entries: [AozoraNavigationEntry] = []
            func walk(_ inlines: [AozoraInline]) {
                for inline in inlines {
                    if case .heading(let level, _, let children) = inline {
                        entries.append(AozoraNavigationEntry(
                            title: headingTitle(children), level: level.navigationLevel,
                            anchor: anchor(blockIndex: blockIndex, ordinal: entries.count + 1)))
                    } else {
                        walk(inline.children)
                    }
                }
            }
            walk(inlines)
            return entries
        case .pageBreak, .image:
            return []
        }
    }

    /// Whether a title gets an entry. A reading system ignores an entry whose label
    /// is blank once white space is trimmed, and every entry nested under it (EPUB 3
    /// Content Documents, nav); some works set U+3000 alone as a heading, as
    /// ［＃大見出し］　［＃大見出し終わり］.
    private static func isListed(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A heading's title: its displayed text, its lines joined by a space.
    static func headingTitle(_ inlines: [AozoraInline]) -> String {
        inlines.displayedText.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static func chapter(role: AozoraChapter.Role, positions: [Int], navigation: [AozoraNavigationEntry],
                                document: AozoraDocument, units: [UInt16],
                                block: (AozoraBlockSpan) -> AozoraBlock) -> AozoraChapter {
        let spans = document.blockSpans
        var segments: [AozoraSourceMap.Segment] = []
        var text = ""
        for position in positions {
            let span = spans[position]
            segments.append(contentsOf: document.segments[span.leaves])
            text += block(span).displayedText + "\n"
            // The "\n" after a block stands for the line break that followed it: the
            // separator of the next block in the document, or nothing at the end.
            let next = position + 1 < spans.count ? spans[position + 1].separator : nil
            let source = next.map { document.segments[$0].source } ?? units.count..<units.count
            segments.append(AozoraSourceMap.Segment(text: "\n", source: source))
        }
        return AozoraChapter(role: role, spans: positions.map { spans[$0] }, navigation: navigation,
                             text: text, sourceMap: AozoraSourceMap(segments: segments, source: units))
    }
}

private extension AozoraHeadingLevel {
    var navigationLevel: Int {
        switch self {
        case .large: return 1
        case .medium: return 2
        case .small: return 3
        }
    }
}
