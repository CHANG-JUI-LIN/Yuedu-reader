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
    let chapters: [String]
}

extension ParsedBookDocument {
    /// Concatenates chapter titles + body for plain-text persistence.
    var storageText: String {
        chapters
            .map {
                $0
                    .removingIllegalStorageCharacters()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .removingIllegalStorageCharacters()
    }
}

protocol BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument
}

enum BookParserRegistryError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported file format"
        }
    }
}

enum BookParserRegistry {
    private static let parsers: [String: any BookParser] = [
        "txt": TXTBookParser(),
        "epub": EPUBBookParser(),
        "json": JSONBookParser(),
        "md": MarkdownBookParser(),
        "markdown": MarkdownBookParser()
    ]

    static func parser(for fileURL: URL) async -> (any BookParser)? {
        let ext = fileURL.pathExtension.lowercased()
        if let byExt = parsers[ext] {
            return byExt
        }
        return await parserByMagicNumber(for: fileURL)
    }

    static func parse(url: URL) async throws -> ParsedBookDocument {
        let startUptime = ProcessInfo.processInfo.systemUptime
        func parseTrace(_ message: String) {
            let line = "[ImportTrace][BookParserRegistry] \(message)"
            print(line)
            NSLog("%@", line)
        }
        guard let parser = await parser(for: url) else {
            parseTrace("unsupported file=\(url.lastPathComponent)")
            throw BookParserRegistryError.unsupportedFormat
        }
        parseTrace("begin file=\(url.lastPathComponent) parser=\(String(describing: type(of: parser)))")
        let parsed = try await parser.parse(url: url)
        parseTrace(
            "done file=\(url.lastPathComponent) parser=\(String(describing: type(of: parser))) chapters=\(parsed.chapters.count) elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startUptime) * 1000))"
        )
        return parsed
    }

    private static func parserByMagicNumber(for fileURL: URL) async -> (any BookParser)? {
        guard let sample = await loadMagicSample(from: fileURL) else {
            return nil
        }
        if sample.count >= 2, sample[0] == 0x50, sample[1] == 0x4B {
            return parsers["epub"]
        }
        if looksLikeJSON(sample) {
            return parsers["json"]
        }
        if isLikelyText(sample) {
            return parsers["txt"]
        }
        return nil
    }

    private static func loadMagicSample(from fileURL: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return nil
            }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4096)
        }.value
    }

    private static func isLikelyText(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        if data.contains(0) { return false }

        let printableCount = data.reduce(0) { partial, byte in
            if byte == 9 || byte == 10 || byte == 13 { return partial + 1 }
            if (32...126).contains(byte) { return partial + 1 }
            if byte >= 0x80 { return partial + 1 }
            return partial
        }
        return Double(printableCount) / Double(data.count) > 0.85
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let byte = data.first(where: { ![9, 10, 13, 32].contains($0) }) else {
            return false
        }
        return byte == 0x7B || byte == 0x5B
    }
}

struct JSONBookParser: BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = Self.firstStringDeep(
            in: root,
            keys: ["title", "bookTitle", "bookName", "name"]
        ) ?? fallbackTitle
        let author = Self.firstStringDeep(
            in: root,
            keys: ["author", "writer", "creator"]
        ) ?? "Unknown Author"

        let chapters = Self.extractChapters(from: root)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !chapters.isEmpty {
            return ParsedBookDocument(title: title, author: author, chapters: chapters)
        }

        let fallbackContent = Self.firstStringDeep(
            in: root,
            keys: ["content", "text", "body", "summary", "intro"]
        ) ?? Self.stringify(root)

        return ParsedBookDocument(
            title: title,
            author: author,
            chapters: [fallbackContent].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    private static func extractChapters(from value: Any) -> [String] {
        if let array = value as? [Any], looksLikeChapterArray(array) {
            return array.compactMap(chapterText(from:))
        }

        guard let dictionary = value as? [String: Any] else { return [] }
        let preferredKeys = [
            "chapters", "chapterList", "chapter_list", "toc", "list", "items", "data"
        ]
        for key in preferredKeys {
            guard let candidate = Self.value(for: key, in: dictionary) else { continue }
            if let array = candidate as? [Any], looksLikeChapterArray(array) {
                return array.compactMap(chapterText(from:))
            }
            let nested = extractChapters(from: candidate)
            if !nested.isEmpty { return nested }
        }

        for candidate in dictionary.values {
            let nested = extractChapters(from: candidate)
            if !nested.isEmpty { return nested }
        }
        return []
    }

    private static func looksLikeChapterArray(_ array: [Any]) -> Bool {
        guard !array.isEmpty else { return false }
        return array.contains { item in
            if item is String { return true }
            guard let dictionary = item as? [String: Any] else { return false }
            return firstString(
                in: dictionary,
                keys: ["title", "name", "chapterTitle", "chapterName", "content", "text", "body"]
            ) != nil || Self.value(for: "paragraphs", in: dictionary) != nil
        }
    }

    private static func chapterText(from value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        let title = firstString(
            in: dictionary,
            keys: ["title", "name", "chapterTitle", "chapterName"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = firstContentString(in: dictionary)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if title.isEmpty { return body.isEmpty ? nil : body }
        if body.isEmpty { return title }
        return title + "\n" + body
    }

    private static func firstContentString(in dictionary: [String: Any]) -> String {
        let keys = ["content", "text", "body", "paragraph", "paragraphs", "value"]
        for key in keys {
            guard let candidate = Self.value(for: key, in: dictionary) else { continue }
            if let string = candidate as? String {
                return string
            }
            if let strings = candidate as? [String] {
                return strings.joined(separator: "\n")
            }
            if let array = candidate as? [Any] {
                let joined = array.map(stringify).filter { !$0.isEmpty }.joined(separator: "\n")
                if !joined.isEmpty { return joined }
            }
        }
        return ""
    }

    private static func firstStringDeep(in value: Any, keys: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            if let direct = firstString(in: dictionary, keys: keys) {
                return direct
            }
            for nested in dictionary.values {
                if let found = firstStringDeep(in: nested, keys: keys) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = firstStringDeep(in: nested, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let candidate = Self.value(for: key, in: dictionary) else { continue }
            if let string = candidate as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = candidate as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func value(for key: String, in dictionary: [String: Any]) -> Any? {
        if let direct = dictionary[key] { return direct }
        let lower = key.lowercased()
        return dictionary.first { $0.key.lowercased() == lower }?.value
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case _ as NSNull:
            return ""
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
                  let string = String(data: data, encoding: .utf8) else {
                return ""
            }
            return string
        }
    }
}

private extension String {
    func removingIllegalStorageCharacters() -> String {
        let filteredScalars = unicodeScalars.filter { scalar in
            if scalar.value == 9 || scalar.value == 10 || scalar.value == 13 {
                return true
            }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }
}
