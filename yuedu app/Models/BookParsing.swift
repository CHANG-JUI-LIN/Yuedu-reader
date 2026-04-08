import Foundation

/// Unified chapter model consumed by CoreText layout/render pipeline.
/// Any external format parser should normalize into this structure.
struct UnifiedChapter: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let title: String
    let paragraphs: [String]
    let sourceHref: String?

    var plainText: String {
        paragraphs.joined(separator: "\n")
    }
}

struct ParsedBookDocument: Equatable {
    let title: String
    let author: String
    let chapters: [UnifiedChapter]
}

protocol BookParser {
    static var supportedExtensions: [String] { get }
    func parse(fileURL: URL, titleOverride: String?) throws -> ParsedBookDocument
}
