import Foundation
import SwiftSoup

final class UniversalBookResourceAdapter: BookResourceProvider {
    private let contentProvider: any BookContentProvider
    private let session: URLSession
    private let lock = NSLock()

    private var chapterPayloadCache: [Int: ChapterContentPayload] = [:]
    private let chapterSourceHrefs: [String?]

    let customScheme: String
    let chapters: [BookResourceChapterDescriptor]

    init(
        contentProvider: any BookContentProvider,
        chapterSourceHrefs: [String?] = [],
        customScheme: String = "reader-online",
        session: URLSession = .shared
    ) {
        self.contentProvider = contentProvider
        self.customScheme = customScheme
        self.session = session

        let total = contentProvider.totalChapters
        self.chapters = (0..<total).map { index in
            BookResourceChapterDescriptor(
                index: index,
                href: "chapter/\(index).xhtml",
                title: contentProvider.chapterTitle(at: index),
                mediaType: "application/xhtml+xml"
            )
        }

        if chapterSourceHrefs.count == total {
            self.chapterSourceHrefs = chapterSourceHrefs
        } else {
            self.chapterSourceHrefs = Array(repeating: nil, count: total)
        }
    }

    func cssResourceHrefs() -> [String] {
        []
    }

    func resourceURL(for href: String) -> URL {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        var components = URLComponents()
        components.scheme = customScheme
        components.host = "book"
        let normalizedPath = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        components.percentEncodedPath =
            normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? normalizedPath
        return components.url ?? URL(string: "\(customScheme)://book\(normalizedPath)")!
    }

    func chapterDataSize(at index: Int) async throws -> Int {
        let payload = try await payloadForChapter(index: index)
        let html = chapterHTMLFromPayload(payload, fallbackChapterIndex: index)
        return html.lengthOfBytes(using: .utf8)
    }

    func chapterIndex(for href: String) -> Int? {
        if let parsed = parseSyntheticChapterIndex(from: href), chapters.indices.contains(parsed) {
            return parsed
        }

        let normalizedTarget = normalizedURLKey(href)
        guard !normalizedTarget.isEmpty else { return nil }

        for (index, sourceHref) in chapterSourceHrefs.enumerated() {
            if normalizedURLKey(sourceHref) == normalizedTarget {
                return index
            }
        }

        let cachedPayloads = lock.withLock {
            chapterPayloadCache
        }

        for (index, payload) in cachedPayloads where normalizedURLKey(payload.sourceHref) == normalizedTarget {
            return index
        }

        return nil
    }

    func chapterHTML(at index: Int) async throws -> String {
        let payload = try await payloadForChapter(index: index)
        return chapterHTMLFromPayload(payload, fallbackChapterIndex: index)
    }

    func response(for requestURL: URL) async throws -> PublicationResourceResponse {
        if requestURL.scheme == customScheme {
            guard let index = parseSyntheticChapterIndex(from: requestURL.absoluteString), chapters.indices.contains(index) else {
                throw PublicationSessionError.resourceNotFound(requestURL.absoluteString)
            }
            let html = try await chapterHTML(at: index)
            guard let data = html.data(using: .utf8) else {
                throw PublicationSessionError.resourceReadFailed(requestURL.absoluteString)
            }
            return PublicationResourceResponse(
                data: data,
                mimeType: "application/xhtml+xml",
                textEncodingName: "utf-8"
            )
        }

        guard let scheme = requestURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw PublicationSessionError.resourceNotFound(requestURL.absoluteString)
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)

        let httpResponse = response as? HTTPURLResponse
        let mimeType = httpResponse?.mimeType ?? fallbackMimeType(for: requestURL)
        let isText = mimeType.contains("html")
            || mimeType.contains("xml")
            || mimeType.contains("css")
            || mimeType.contains("javascript")
            || mimeType.hasPrefix("text/")

        return PublicationResourceResponse(
            data: data,
            mimeType: mimeType,
            textEncodingName: isText ? (httpResponse?.textEncodingName ?? "utf-8") : nil
        )
    }

    private func payloadForChapter(index: Int) async throws -> ChapterContentPayload {
        let cached = lock.withLock {
            chapterPayloadCache[index]
        }
        if let cached = cached {
            return cached
        }

        let payload = try await contentProvider.contentForChapter(index: index)
        lock.withLock {
            chapterPayloadCache[index] = payload
        }
        return payload
    }

    private func chapterHTMLFromPayload(_ payload: ChapterContentPayload, fallbackChapterIndex: Int) -> String {
        if let renderHTML = payload.renderHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !renderHTML.isEmpty {
            let baseURL = payload.sourceHref ?? chapterSourceHrefs[safe: fallbackChapterIndex] ?? payload.sourceHref
            let reviewHTML = ReaderHTMLUtilities.rewriteReviewComments(renderHTML)
            let rewritten = rewriteResourceReferences(in: reviewHTML, baseURLString: baseURL)
            return rewritten
        }

        return ReaderHTMLUtilities.normalizedChapterHTML(
            title: payload.title,
            paragraphs: ReaderHTMLUtilities.paragraphs(fromPlainText: payload.content)
        )
    }

    private func rewriteResourceReferences(in html: String, baseURLString: String?) -> String {
        guard let baseURLString, !baseURLString.isEmpty else { return html }
        guard let document = try? SwiftSoup.parse(html, baseURLString) else { return html }

        let singleAttributes: [(selector: String, attr: String)] = [
            ("img[src]", "src"),
            ("source[src]", "src"),
            ("audio[src]", "src"),
            ("video[src]", "src"),
            ("track[src]", "src"),
            ("link[href]", "href"),
            ("script[src]", "src"),
            ("iframe[src]", "src"),
        ]

        for item in singleAttributes {
            let elements = (try? document.select(item.selector).array()) ?? []
            for element in elements {
                let raw = (try? element.attr(item.attr)) ?? ""
                guard !raw.isEmpty else { continue }
                guard let absolute = makeAbsoluteResourceURL(raw, baseURLString: baseURLString) else { continue }
                _ = try? element.attr(item.attr, absolute)
            }
        }

        let links = (try? document.select("a[href]").array()) ?? []
        for element in links {
            let raw = (try? element.attr("href")) ?? ""
            guard !raw.isEmpty, !raw.hasPrefix("#") else { continue }
            guard let absolute = makeAbsoluteResourceURL(raw, baseURLString: baseURLString) else { continue }
            _ = try? element.attr("href", absolute)
        }

        let srcsetElements = (try? document.select("img[srcset],source[srcset]").array()) ?? []
        for element in srcsetElements {
            let raw = (try? element.attr("srcset")) ?? ""
            guard !raw.isEmpty else { continue }
            let rewritten = raw
                .split(separator: ",")
                .map { part -> String in
                    let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return "" }
                    let segments = token.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard let first = segments.first else { return token }
                    let rawURL = String(first)
                    guard let absolute = makeAbsoluteResourceURL(rawURL, baseURLString: baseURLString) else {
                        return token
                    }
                    if segments.count > 1 {
                        return "\(absolute) \(segments[1])"
                    }
                    return absolute
                }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            if !rewritten.isEmpty {
                _ = try? element.attr("srcset", rewritten)
            }
        }

        return (try? document.outerHtml()) ?? html
    }

    private func makeAbsoluteResourceURL(_ raw: String, baseURLString: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#")
            || trimmed.lowercased().hasPrefix("data:")
            || trimmed.lowercased().hasPrefix("javascript:")
            || trimmed.lowercased().hasPrefix("mailto:")
            || trimmed.lowercased().hasPrefix("tel:") {
            return trimmed
        }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute.absoluteString
        }

        guard let baseURL = URL(string: baseURLString) else { return trimmed }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString ?? trimmed
    }

    private func parseSyntheticChapterIndex(from href: String) -> Int? {
        var raw = href.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: raw), url.scheme == customScheme {
            raw = url.path
            if raw.hasPrefix("/") {
                raw.removeFirst()
            }
        }

        if raw.hasPrefix("chapter/") {
            raw = String(raw.dropFirst("chapter/".count))
        }
        if raw.hasPrefix("/") {
            raw.removeFirst()
        }
        if raw.hasSuffix(".xhtml") {
            raw = String(raw.dropLast(".xhtml".count))
        }

        return Int(raw)
    }

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }

    private func fallbackMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
