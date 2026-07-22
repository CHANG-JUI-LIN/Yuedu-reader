import Foundation

// MARK: - Fixed page model
//
// A fixed-page chapter can come from image URLs, extracted archive files, or a
// renderer-backed source such as fixed-layout EPUB.

enum FixedPageRenderSource: Equatable {
    case image
    case fixedLayoutEPUB(sourceFilename: String, chapterIndex: Int)
}

struct FixedPage: Identifiable, Equatable {
    let id: Int               // page index within the chapter
    let imageURL: String      // remote URL
    let headers: [String: String]
    var localURL: URL?        // non-nil when downloaded for offline reading
    var renderSource: FixedPageRenderSource = .image
}

enum MangaChapterParser {

    /// A parsed page: the clean image URL plus any per-image request headers carried by the
    /// Legado `<url>,{ "headers": {...} }` source syntax (some CDNs 403 without their referer).
    struct ParsedImage: Equatable {
        let url: String
        let headers: [String: String]
    }

    /// Ordered clean image URLs from a fetched chapter's `content`.
    static func imageURLs(from content: String) -> [String] {
        parsedImages(from: content).map(\.url)
    }

    /// Parse a chapter's `content` into ordered pages. Handles a JSON array of strings,
    /// `<img>` tags (aggregation sources return HTML, often with unescaped quotes around a
    /// `url,{headers}` src), or newline-separated tokens. The pipeline has already resolved
    /// relative/protocol-relative URLs to absolute.
    static func parsedImages(from content: String) -> [ParsedImage] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            let images = array.compactMap { parseImageToken($0) }
            if !images.isEmpty { return images }
        }

        let tagImages = imgTagImages(in: trimmed)
        if !tagImages.isEmpty { return tagImages }

        return trimmed
            .components(separatedBy: .newlines)
            .compactMap { parseImageToken($0) }
    }

    /// Heuristic that decides whether a fetched chapter is actually a manga page
    /// list rather than prose. Used to auto-route books from aggregation sources
    /// (which report `bookSourceType == 0` yet serve manga) to the image reader.
    ///
    /// Positive when the source explicitly flagged `imageStyle == "FULL"`, or the
    /// content resolves to several images and carries essentially no body text.
    static func looksLikeMangaContent(_ content: String, imageStyle: String? = nil) -> Bool {
        if imageStyle?.uppercased() == "FULL" { return true }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let urls = imageURLs(from: content)
        guard urls.count >= 3 else { return false }

        // A JSON array of image URLs is unambiguous.
        if trimmed.hasPrefix("[") { return true }

        // Otherwise require the chapter to be *predominantly* images: strip the
        // image references and confirm little prose remains.
        var residual = trimmed.replacingOccurrences(
            of: #"(?is)<img\b[^>]*>"#, with: "", options: .regularExpression)
        residual = residual
            .components(separatedBy: .newlines)
            .filter { !isImageURL($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .joined(separator: "\n")
        residual = residual.replacingOccurrences(
            of: #"<[^>]+>"#, with: "", options: .regularExpression)
        residual = urls.reduce(residual) { $0.replacingOccurrences(of: $1, with: "") }
        residual = residual.trimmingCharacters(in: .whitespacesAndNewlines)
        return residual.count <= 16
    }

    /// Pull pages out of `<img>` tags. The src is captured up to the tag's closing `>` so the
    /// Legado `url,{headers}` form (which embeds unescaped quotes) survives; `parseImageToken`
    /// then splits the URL from its options.
    private static func imgTagImages(in html: String) -> [ParsedImage] {
        guard html.range(of: "<img", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                pattern: #"<img\b[^>]*>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let ns = html as NSString
        var images: [ParsedImage] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        where match.numberOfRanges >= 1 {
            if let image = image(inTag: ns.substring(with: match.range(at: 0))) {
                images.append(image)
            }
        }
        return images
    }

    private static func image(inTag tag: String) -> ParsedImage? {
        for attribute in ["data-src", "data-original", "src"] {
            guard let raw = attributeValue(named: attribute, in: tag),
                  let image = parseImageToken(raw)
            else { continue }
            return image
        }
        return nil
    }

    private static func attributeValue(named name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: tag,
                range: NSRange(tag.startIndex..<tag.endIndex, in: tag)
              ),
              let start = Range(match.range, in: tag)?.upperBound
        else { return nil }

        var cursor = start
        while cursor < tag.endIndex, tag[cursor].isWhitespace {
            cursor = tag.index(after: cursor)
        }
        guard cursor < tag.endIndex else { return nil }

        let quote = tag[cursor]
        if quote == "\"" || quote == "'" {
            let valueStart = tag.index(after: cursor)
            var end = valueStart
            while end < tag.endIndex {
                if tag[end] == quote,
                   isAttributeValueTerminator(after: tag.index(after: end), in: tag) {
                    return String(tag[valueStart..<end])
                }
                end = tag.index(after: end)
            }
            return String(tag[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var end = cursor
        while end < tag.endIndex, !tag[end].isWhitespace, tag[end] != ">" {
            end = tag.index(after: end)
        }
        return String(tag[cursor..<end])
    }

    private static func isAttributeValueTerminator(after index: String.Index, in tag: String) -> Bool {
        var cursor = index
        while cursor < tag.endIndex, tag[cursor].isWhitespace {
            cursor = tag.index(after: cursor)
        }
        guard cursor < tag.endIndex else { return true }
        if tag[cursor] == ">" { return true }
        if tag[cursor] == "/" {
            let next = tag.index(after: cursor)
            return next < tag.endIndex && tag[next] == ">"
        }
        guard isAttributeNameCharacter(tag[cursor]) else { return false }

        var nameEnd = cursor
        while nameEnd < tag.endIndex, isAttributeNameCharacter(tag[nameEnd]) {
            nameEnd = tag.index(after: nameEnd)
        }
        var equals = nameEnd
        while equals < tag.endIndex, tag[equals].isWhitespace {
            equals = tag.index(after: equals)
        }
        return equals < tag.endIndex && tag[equals] == "="
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":" || character == "."
    }

    /// Turn one raw token (`<url>` or `<url>,{ "headers": {...} }`, possibly with leaked trailing
    /// attributes from a multi-attribute tag) into a clean URL + per-image headers.
    private static func parseImageToken(_ raw: String) -> ParsedImage? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        var headers: [String: String] = [:]
        if let optionsRange = token.range(of: ",{") {
            headers = parseHeaders(fromOptions: String(token[token.index(after: optionsRange.lowerBound)...]))
            token = String(token[..<optionsRange.lowerBound])
        } else if let quote = token.firstIndex(of: "\"") {
            // Over-captured a clean multi-attribute tag (e.g. src="url" alt="x"); keep the url.
            token = String(token[..<quote])
        }

        let url = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = url.hasPrefix("//") ? "https:" + url : url
        guard isImageURL(normalized) else { return nil }
        return ParsedImage(url: normalized, headers: headers)
    }

    /// Extract `headers` from a Legado options object string like `{"headers":{...}}`,
    /// tolerating trailing junk after the closing brace.
    private static func parseHeaders(fromOptions options: String) -> [String: String] {
        func headers(in jsonString: String) -> [String: String]? {
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = obj["headers"] as? [String: Any] else { return nil }
            return raw.compactMapValues { $0 as? String }
        }
        if let h = headers(in: options) { return h }
        if let lastBrace = options.lastIndex(of: "}"),
           let h = headers(in: String(options[...lastBrace])) { return h }
        return [:]
    }

    /// Build pages, attaching request headers (per-image headers override the source defaults).
    /// Offline files are trusted only when a complete manifest matches the current image list.
    static func pages(from content: String, headers: [String: String], localDir: URL? = nil) -> [FixedPage] {
        let images = parsedImages(from: content)

        var localByIndex: [Int: URL] = [:]
        if let localDir,
           let manifest = OfflineChapterStore.validatedMangaManifest(in: localDir),
           manifest.pages.count == images.count,
           manifest.pages.map(\.sourceURL) == images.map(\.url) {
            for (index, page) in manifest.pages.enumerated() {
                localByIndex[index] = localDir.appendingPathComponent(page.filename)
            }
        }

        if let localDir,
           FileManager.default.fileExists(atPath: localDir.path),
           localByIndex.isEmpty {
            AppLogger.cache("Manga offline manifest missing, incomplete, or stale")
        }

        return images.enumerated().map { index, image in
            let merged = headers.merging(image.headers) { _, perImage in perImage }
            return FixedPage(
                id: index,
                imageURL: image.url,
                headers: merged,
                localURL: localByIndex[index]
            )
        }
    }

    private static func isImageURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    // MARK: Offline storage layout (shared by downloader + reader)

    /// Persistent (non-purgeable) root for downloaded manga images.
    static var rootDirectory: URL {
        OfflineStorageRoots.live.mangaRoot
    }

    static func chapterDirectory(bookId: UUID, chapterIndex: Int) -> URL {
        rootDirectory
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
            .appendingPathComponent(String(chapterIndex), isDirectory: true)
    }

    /// Whether a chapter has downloaded image files on disk.
    static func isChapterDownloaded(bookId: UUID, chapterIndex: Int) -> Bool {
        OfflineChapterStore.validatedMangaManifest(
            bookId: bookId,
            chapterIndex: chapterIndex
        ) != nil
    }
}
