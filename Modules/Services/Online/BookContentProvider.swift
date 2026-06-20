import Foundation

enum ChapterRenderBody: Equatable {
    case plainText(String)
    case html(String)

    var byteCount: Int {
        switch self {
        case .plainText(let text), .html(let text):
            return text.lengthOfBytes(using: .utf8)
        }
    }

    var debugKind: String {
        switch self {
        case .plainText: return "plainText"
        case .html: return "html"
        }
    }
}

struct ChapterContentPayload: Equatable {
    let index: Int
    let title: String
    let plainText: String
    let body: ChapterRenderBody
    let sourceHref: String?
}

protocol BookContentProvider {
    var totalChapters: Int { get }
    func chapterTitle(at index: Int) -> String
    func contentForChapter(index: Int) async throws -> ChapterContentPayload
}

enum BookContentProviderError: LocalizedError, Equatable {
    case chapterIndexOutOfRange(Int)
    case contentNotCached(Int)
    case unsupportedChapterContent(String)

    var errorDescription: String? {
        switch self {
        case .chapterIndexOutOfRange(let index):
            return "章節索引超出範圍：\(index)"
        case .contentNotCached(let index):
            return "章節尚未快取：\(index)"
        case .unsupportedChapterContent(let type):
            return "不支援的章節內容：\(type)"
        }
    }
}

struct UnifiedChapterContentProvider: BookContentProvider {
    private let chapters: [UnifiedChapter]

    init(chapters: [UnifiedChapter]) {
        self.chapters = chapters
    }

    var totalChapters: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return chapters[index].title
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard chapters.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        let chapter = chapters[index]
        return ChapterContentPayload(
            index: chapter.index,
            title: chapter.title,
            plainText: chapter.plainText,
            body: .plainText(chapter.plainText),
            sourceHref: chapter.sourceHref
        )
    }
}
