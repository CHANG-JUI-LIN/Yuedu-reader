import Foundation
import UIKit

struct AttributedChapterBuildResult {
    let attributedString: NSAttributedString
    let imagePage: HTMLAttributedStringBuilder.ImagePage?
    let pageBackgroundImage: UIImage?
    let anchorOffsets: [String: Int]
}

enum AttributedStringBuildingError: LocalizedError {
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
