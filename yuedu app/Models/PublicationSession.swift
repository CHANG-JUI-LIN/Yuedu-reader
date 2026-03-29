import Foundation
import UIKit
import ReadiumShared
import ReadiumStreamer

struct PublicationChapterDescriptor: Equatable {
    let index: Int
    let href: String
    let title: String
    let mediaType: String
}

struct PublicationResourceResponse {
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

enum PublicationSessionError: LocalizedError {
    case fileNotFound
    case parsingFailed(String)
    case resourceNotFound(String)
    case resourceReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "EPUB 檔案不存在"
        case .parsingFailed(let reason):
            return "EPUB 解析失敗：\(reason)"
        case .resourceNotFound(let href):
            return "找不到資源：\(href)"
        case .resourceReadFailed(let reason):
            return "讀取資源失敗：\(reason)"
        }
    }
}

final class PublicationSessionRegistry {
    static let shared = PublicationSessionRegistry()

    private let lock = NSLock()
    private var sessions: [String: PublicationSession] = [:]

    private init() {}

    func register(_ session: PublicationSession) {
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
    }

    func unregister(id: String) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    func session(for id: String) -> PublicationSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }
}

final class PublicationSession {
    static let scheme = "reader-book"

    let id: String
    let sourceURL: URL
    let publication: Publication
    let bookTitle: String
    let author: String
    let chapters: [PublicationChapterDescriptor]
    let tocEntries: [EPUBTocEntry]

    private init(
        id: String,
        sourceURL: URL,
        publication: Publication,
        bookTitle: String,
        author: String,
        chapters: [PublicationChapterDescriptor],
        tocEntries: [EPUBTocEntry]
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.publication = publication
        self.bookTitle = bookTitle
        self.author = author
        self.chapters = chapters
        self.tocEntries = tocEntries
    }

    deinit {
        PublicationSessionRegistry.shared.unregister(id: id)
    }

    static func open(sourceURL: URL) async throws -> PublicationSession {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PublicationSessionError.fileNotFound
        }

        let publication = try await openPublication(sourceURL: sourceURL)
        let tocEntries = flattenTableOfContents(publication.manifest.tableOfContents)
        let chapterTitleMap = Dictionary(
            tocEntries.map { (normalizedHREF($0.href), $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let readingOrder = chapterLinks(from: publication)
        let chapters = readingOrder.enumerated().map { (index, link) in
            let href = normalizedHREF(link.href)
            let fallbackTitle = chapterTitleMap[href] ?? chapterTitleMap.first(where: {
                href.hasSuffix($0.key) || $0.key.hasSuffix(href)
            })?.value
            return PublicationChapterDescriptor(
                index: index,
                href: href,
                title: sanitizedTitle(
                    link.title ?? fallbackTitle,
                    fallbackHref: href,
                    chapterIndex: index
                ),
                mediaType: link.mediaType?.string ?? "application/xhtml+xml"
            )
        }

        let title = publication.metadata.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = publication.metadata.authors
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")

        let session = PublicationSession(
            id: UUID().uuidString.lowercased(),
            sourceURL: sourceURL,
            publication: publication,
            bookTitle: title?.isEmpty == false
                ? title!
                : sourceURL.deletingPathExtension().lastPathComponent,
            author: authors,
            chapters: chapters,
            tocEntries: tocEntries
        )
        PublicationSessionRegistry.shared.register(session)
        return session
    }

    static func extractCoverImage(sourceURL: URL) async -> UIImage? {
        guard let publication = try? await openPublication(sourceURL: sourceURL) else {
            return nil
        }
        switch await publication.cover() {
        case .success(let image):
            return image
        case .failure:
            return nil
        }
    }

    func resourceURL(for href: String) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = id
        let normalized = href.hasPrefix("/") ? href : "/\(href)"
        components.percentEncodedPath = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return components.url ?? URL(string: "\(Self.scheme)://\(id)\(normalized)")!
    }

    func chapterBaseURL(at index: Int) -> URL {
        resourceURL(for: chapters[index].href)
    }

    func chapterIndex(for href: String) -> Int? {
        let normalized = Self.normalizedHREF(href)
        return chapters.firstIndex(where: {
            $0.href == normalized || normalized.hasSuffix($0.href) || $0.href.hasSuffix(normalized)
        })
    }

    func chapterHTML(at index: Int) async throws -> String {
        let descriptor = chapters[index]
        guard let resource = resource(for: descriptor.href) else {
            throw PublicationSessionError.resourceReadFailed(descriptor.href)
        }

        let data: Data
        switch await resource.read() {
        case .success(let value):
            data = value
        case .failure:
            throw PublicationSessionError.resourceReadFailed(descriptor.href)
        }

        let mediaType = link(for: descriptor.href)?.mediaType
        if let encoding = mediaType?.encoding,
           let html = String(data: data, encoding: encoding)
        {
            return html
        }

        for encoding in [String.Encoding.utf8, .unicode, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let html = String(data: data, encoding: encoding) {
                return html
            }
        }

        throw PublicationSessionError.resourceReadFailed(descriptor.href)
    }

    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        guard requestURL.scheme == Self.scheme, requestURL.host == id else {
            throw PublicationSessionError.resourceNotFound(requestURL.absoluteString)
        }
        let href = Self.normalizedHREF(resolvedHREF(from: requestURL))
        guard let resource = resource(for: href) else {
            throw PublicationSessionError.resourceNotFound(href)
        }

        let data: Data
        switch await resource.read() {
        case .success(let value):
            data = value
        case .failure:
            throw PublicationSessionError.resourceNotFound(href)
        }

        let properties = try? await resource.properties().get()
        let mimeType =
            link(for: href)?.mediaType?.string
            ?? properties?.mediaType?.string
            ?? fallbackMimeType(for: href)
        let isText =
            mimeType.contains("html")
            || mimeType.contains("xml")
            || mimeType.contains("css")
            || mimeType.contains("javascript")
            || mimeType.hasPrefix("text/")

        return PublicationResourceResponse(
            data: data,
            mimeType: mimeType,
            textEncodingName: isText ? "utf-8" : nil
        )
    }

    func readerLocator(
        chapterIndex: Int,
        pageInChapter: Int,
        totalPagesInChapter: Int,
        globalPage: Int,
        totalPages: Int,
        generationId: Int
    ) async -> ReaderLocator {
        let chapterProgression = totalPagesInChapter > 1
            ? Double(pageInChapter) / Double(max(totalPagesInChapter - 1, 1))
            : 0
        let totalProgression = totalPages > 1
            ? Double(globalPage) / Double(max(totalPages - 1, 1))
            : chapterProgression

        return ReaderLocator(
            spineHref: chapters[chapterIndex].href,
            chapterIndex: chapterIndex,
            pageInChapter: pageInChapter,
            totalPagesInChapter: totalPagesInChapter,
            globalPage: globalPage,
            progression: totalProgression,
            generationId: generationId,
            title: chapters[chapterIndex].title,
            chapterProgression: chapterProgression,
            totalProgression: totalProgression
        )
    }

    func resolve(locator: ReaderLocator) async -> (chapterIndex: Int, chapterProgression: Double)? {
        let chapterIndex = chapterIndex(for: locator.spineHref)
            ?? (chapters.indices.contains(locator.chapterIndex) ? locator.chapterIndex : nil)
        guard let chapterIndex else { return nil }
        return (chapterIndex, locator.chapterProgression ?? locator.progression)
    }

    // MARK: - 內部

    private func resolvedHREF(from url: URL) -> String {
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let decodedPath = path.removingPercentEncoding ?? path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        if let query, !query.isEmpty {
            return "\(decodedPath)?\(query)"
        }
        return decodedPath
    }

    private func resource(for href: String) -> Resource? {
        readiumURLs(for: href).lazy
            .compactMap { [self] href in
                self.publication.get(href)
                    ?? self.publication.linkWithHREF(href).flatMap(self.publication.get(_:))
            }
            .first
    }

    private func link(for href: String) -> Link? {
        readiumURLs(for: href).lazy
            .compactMap(publication.linkWithHREF(_:))
            .first
    }

    private func readiumURLs(for href: String) -> [AnyURL] {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePath = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let candidates = [trimmed, basePath, "/\(basePath)"]
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let url = AnyURL(legacyHREF: candidate) else {
                return nil
            }
            let normalized = url.normalized
            guard seen.insert(normalized.string).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func fallbackMimeType(for href: String) -> String {
        switch URL(fileURLWithPath: href).pathExtension.lowercased() {
        case "html", "htm":
            return "text/html"
        case "xhtml":
            return "application/xhtml+xml"
        case "css":
            return "text/css"
        case "js":
            return "text/javascript"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        default:
            return "application/octet-stream"
        }
    }

    private static func openPublication(sourceURL: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: sourceURL) else {
            throw PublicationSessionError.parsingFailed("無效的檔案 URL")
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL, hints: FormatHints(mediaType: .epub)) {
        case .success(let value):
            asset = value
        case .failure(let error):
            throw PublicationSessionError.parsingFailed(error.localizedDescription)
        }

        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        switch await opener.open(asset: asset, allowUserInteraction: false) {
        case .success(let publication):
            return publication
        case .failure(let error):
            throw PublicationSessionError.parsingFailed(error.localizedDescription)
        }
    }

    private static func chapterLinks(from publication: Publication) -> [Link] {
        let htmlLinks = publication.readingOrder.filter {
            if let mediaType = $0.mediaType {
                return mediaType.isHTML
            }
            let ext = URL(fileURLWithPath: $0.href).pathExtension.lowercased()
            return ext == "html" || ext == "htm" || ext == "xhtml"
        }
        return htmlLinks.isEmpty ? publication.readingOrder : htmlLinks
    }

    private static func flattenTableOfContents(_ links: [Link], level: Int = 0) -> [EPUBTocEntry] {
        links.flatMap { link in
            let href = normalizedHREF(link.href)
            let ownEntry: [EPUBTocEntry]
            if !href.isEmpty {
                ownEntry = [
                    EPUBTocEntry(
                        href: href,
                        title: sanitizedTitle(link.title, fallbackHref: href),
                        level: level
                    )
                ]
            } else {
                ownEntry = []
            }
            return ownEntry + flattenTableOfContents(link.children, level: level + 1)
        }
    }

    private static func normalizedHREF(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        if let url = URL(string: noFragment), url.scheme != nil {
            return (url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path)
        }
        return noFragment.hasPrefix("/") ? String(noFragment.dropFirst()) : noFragment
    }

    private static func sanitizedTitle(
        _ rawTitle: String?,
        fallbackHref: String,
        chapterIndex: Int? = nil
    ) -> String {
        let fallback = fallbackTitle(for: fallbackHref, chapterIndex: chapterIndex)
        guard var title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return fallback
        }

        title = title.replacingOccurrences(
            of: #"<\?xml[\s\S]*?\?>"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"<!DOCTYPE[\s\S]*?>"#,
            with: " ",
            options: .regularExpression
        )

        if title.contains("<") || title.contains("&") {
            if
                let data = title.data(using: .utf8),
                let decoded = try? NSAttributedString(
                    data: data,
                    options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ],
                    documentAttributes: nil
                ).string
            {
                title = decoded
            }
        }

        title = title.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !looksLikeMarkup(title) else {
            return fallback
        }

        if title.count > 240 {
            return fallback
        }

        return title
    }

    private static func fallbackTitle(for href: String, chapterIndex: Int?) -> String {
        let normalized = normalizedHREF(href)
        let filename = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        if !filename.isEmpty {
            return filename
        }
        if let chapterIndex {
            return "Chapter \(chapterIndex + 1)"
        }
        return "Untitled"
    }

    private static func looksLikeMarkup(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("<?xml")
            || lowercased.contains("<html")
            || lowercased.contains("<body")
            || lowercased.contains("<svg")
    }
}
