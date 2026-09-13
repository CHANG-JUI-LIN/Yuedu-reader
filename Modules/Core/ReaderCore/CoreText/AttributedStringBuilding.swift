import Foundation
import UIKit

/// Opaque identity for one attributed-content build.
///
/// Create a new revision whenever any layout-affecting output changes. Reuse a
/// revision only for first-page, full, and warm pagination of that same build result.
struct ContentRevision: Hashable, Sendable {
    private let identity: UUID

    init() {
        identity = UUID()
    }
}

struct AttributedChapterBuildResult {
    let attributedString: NSAttributedString
    let imagePage: HTMLAttributedStringBuilder.ImagePage?
    let pageBackgroundImage: UIImage?
    let pageBackgroundColor: UIColor?
    /// Dark `@media (prefers-color-scheme: dark)` variant of `pageBackgroundColor`. nil when the
    /// publication has no dark body fill — the light authored fill (or reader theme) carries over.
    let darkPageBackgroundColor: UIColor?
    let anchorOffsets: [String: Int]
    let revision: ContentRevision

    init(
        attributedString: NSAttributedString,
        imagePage: HTMLAttributedStringBuilder.ImagePage?,
        pageBackgroundImage: UIImage?,
        pageBackgroundColor: UIColor? = nil,
        darkPageBackgroundColor: UIColor? = nil,
        anchorOffsets: [String: Int],
        revision: ContentRevision = ContentRevision()
    ) {
        self.attributedString = attributedString
        self.imagePage = imagePage
        self.pageBackgroundImage = pageBackgroundImage
        self.pageBackgroundColor = pageBackgroundColor
        self.darkPageBackgroundColor = darkPageBackgroundColor
        self.anchorOffsets = anchorOffsets
        self.revision = revision
    }
}

enum AttributedStringBuildingError: LocalizedError, Equatable {
    case chapterOutOfRange(Int)
    case contentNotCached(Int)

    var errorDescription: String? {
        switch self {
        case .chapterOutOfRange(let index):
            return "Chapter index out of range: \(index)"
        case .contentNotCached(let index):
            return "Chapter \(index) content is not yet cached"
        }
    }
}

protocol AttributedStringBuilding {
    var chapterCount: Int { get }
    /// When true, CoreTextPageEngine skips the O(N) byte-size scan at startup
    /// and initialises sizes to zero. Sizes are filled incrementally via
    /// `notifyChapterDataChanged`. Online books should return true.
    var prefersLazyByteScan: Bool { get }
    func chapterTitle(at index: Int) -> String
    func chapterSourceHref(at index: Int) -> String?
    func chapterDataSize(at index: Int) async -> Int
    func chapterIndex(for href: String) -> Int?
    func cssResourceHrefs() -> [String]
    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult

    /// The chapter's plain text, read from the source without laying it out and without
    /// going to the network.
    ///
    /// Whole-book work — the AI index, 人物卡's book scan — cannot read the laid-out text:
    /// `LayoutCache` holds five chapters, so a reader 94% of the way through a novel was
    /// indexing five chapters of it and finding two speakers. Returning nil means this
    /// chapter's text is not on the device; the caller skips it rather than fetching.
    func chapterPlainText(at index: Int) async -> String?
    func localChapterText(at index: Int) async -> AILocalChapterText
}

extension AttributedStringBuilding {
    /// Default for builders with no source text of their own. The caller then sees only the
    /// laid-out chapters, which is the old behaviour — not silently wrong, just narrow.
    func chapterPlainText(at index: Int) async -> String? { nil }
    func localChapterText(at index: Int) async -> AILocalChapterText { .init(text: nil, status: .unsupported) }
}

/// Markup to plain text for whole-book work.
enum ChapterPlainText {
    /// Keeps paragraph breaks. Dialogue attribution is read one paragraph at a time, so
    /// collapsing them the way `displayText` does by default erases every speaker.
    static func fromHTML(_ html: String) -> String {
        // Tag stripping alone leaves the *contents* of script and style elements behind as
        // prose, and EPUB chapters routinely carry an inline stylesheet.
        let stripped = html.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#,
            with: "",
            options: .regularExpression
        )
        return ReaderHTMLUtilities.displayText(
            fromHTMLFragment: stripped,
            preservingLineBreaks: true
        )
    }
}

@MainActor
protocol RenderSizeAwareAttributedStringBuilding: AnyObject {
    func updateRenderSize(_ size: CGSize)
}

extension AttributedStringBuilding {
    var prefersLazyByteScan: Bool { false }
    func chapterSourceHref(at index: Int) -> String? { nil }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }
}

enum ReaderTypographyCorrection {
    static func targetLineHeight(font: UIFont, fontSize: CGFloat, lineHeightMultiple: CGFloat) -> CGFloat {
        let requested = fontSize * max(1.0, lineHeightMultiple)
        let glyphBoxHeight = ceil(font.ascender + abs(font.descender))
        // Keep at least glyph bounds to reduce clipping for fonts with unusual metrics.
        return max(requested, glyphBoxHeight + 1)
    }

    static func baselineOffset(font: UIFont, targetLineHeight: CGFloat) -> CGFloat {
        let naturalLineHeight = font.ascender + abs(font.descender) + max(0, font.leading)
        guard targetLineHeight > naturalLineHeight else { return 0 }
        return (targetLineHeight - naturalLineHeight) / 2 - max(0, font.leading) / 2
    }
}
