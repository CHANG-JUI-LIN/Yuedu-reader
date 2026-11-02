import Foundation
import YueduCoreText

/// A `BookResourceProvider` over the package's files alone, for the shelf: it reads chapters and
/// stylesheets straight from the container, without constructing a Readium publication, so that a book's
/// direction can be decided at tap time through the same stylesheet ingestion the reader lays it out with.
///
/// `@unchecked Sendable`: every stored property is immutable, and the container is only read.
final class PackageResourcesBookResourceProvider: BookResourceProvider, @unchecked Sendable {
    private static let host = "package"
    private let resources: EPUBPackageResources
    let chapters: [BookResourceChapterDescriptor]

    init(resources: EPUBPackageResources, spineReferences: [EPUBSpineReference]) {
        self.resources = resources
        chapters = spineReferences.enumerated().map { index, reference in
            BookResourceChapterDescriptor(index: index, href: reference.href, title: "",
                                          mediaType: "application/xhtml+xml")
        }
    }

    var customScheme: String { PublicationSession.scheme }

    /// The reading order holds no stylesheets in a package read this way.
    func cssResourceHrefs() -> [String] { [] }

    func resourceURL(for href: String) -> URL {
        var components = URLComponents()
        components.scheme = customScheme
        components.host = Self.host
        let normalized = href.hasPrefix("/") ? href : "/\(href)"
        components.percentEncodedPath = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return components.url ?? URL(string: "\(customScheme)://\(Self.host)\(normalized)")!
    }

    func chapterDataSize(at index: Int) async throws -> Int {
        try await resources.read(try href(at: index)).count
    }

    func chapterIndex(for href: String) -> Int? {
        chapters.firstIndex { $0.href == href }
    }

    func chapterHTML(at index: Int) async throws -> String {
        let href = try href(at: index)
        guard let text = try await resources.optionalText(href) else {
            throw PublicationSessionError.resourceNotFound(href)
        }
        return text
    }

    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        let path = requestURL.path
        let href = String(path.hasPrefix("/") ? path.dropFirst() : Substring(path))
        return PublicationResourceResponse(data: try await resources.read(href), mimeType: "", textEncodingName: nil)
    }

    /// The chapter's markup and stylesheets, as `EPUBBrowserLayoutResourceAdapter` collects them.
    @MainActor
    func cssFrontendInput(forChapter index: Int) async throws -> CSSFrontendInput {
        let html = try await chapterHTML(at: index)
        let styleResolver = EPUBStyleResolver(resourceProvider: self,
                                              fontRegistrationService: CoreTextFontRegistrationService())
        return await EPUBStylesheetIngestion.collect(html: html, chapterHref: chapters[index].href,
                                                     resourceProvider: self, styleResolver: styleResolver)
    }

    private func href(at index: Int) throws -> String {
        guard chapters.indices.contains(index) else { throw PublicationSessionError.chapterOutOfRange(index) }
        return chapters[index].href
    }
}
