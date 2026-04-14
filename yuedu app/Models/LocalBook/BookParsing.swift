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
            return "不支援的檔案格式"
        }
    }
}

enum BookParserRegistry {
    private static let parsers: [String: any BookParser] = [
        "txt": TXTBookParser(),
        "epub": EPUBBookParser(),
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
