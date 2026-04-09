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

    var errorDescription: String? {
        switch self {
        case .chapterOutOfRange(let index):
            return "章節索引超出範圍：\(index)"
        }
    }
}

protocol AttributedStringBuilding {
    var chapterCount: Int { get }
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
    func chapterSourceHref(at index: Int) -> String? { nil }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }
}
