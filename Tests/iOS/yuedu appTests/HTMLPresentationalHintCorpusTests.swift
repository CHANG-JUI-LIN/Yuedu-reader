import Foundation
import ReadiumZIPFoundation
import SwiftSoup
import Testing
@testable import yuedu_app

@MainActor
struct HTMLPresentationalHintCorpusTests {
    private struct BookInput {
        let id: String
        let url: URL
        let isGenerated: Bool
    }

    private struct Key: Hashable {
        let tag: String
        let attribute: String
    }

    private struct ValueAccumulator {
        var bookIDs: Set<String> = []
        var chapterIDs: Set<String> = []
        var elementCount = 0
    }

    private struct Accumulator {
        var bookIDs: Set<String> = []
        var chapterIDs: Set<String> = []
        var elementCount = 0
        var values: [String: ValueAccumulator] = [:]
    }

    private struct ValuePattern: Codable {
        let value: String
        let epubCount: Int
        let chapterCount: Int
        let elementCount: Int
    }

    private struct AttributeSummary: Codable {
        let attribute: String
        let tag: String
        let epubCount: Int
        let chapterCount: Int
        let elementCount: Int
        let valuePatterns: [ValuePattern]
    }

    private struct BookSummary: Codable {
        let id: String
        let chapterCount: Int
        let scannedChapterCount: Int
    }

    private struct Artifact: Codable {
        let schemaVersion: Int
        let corpusEPUBCount: Int
        let corpusChapterCount: Int
        let scannedChapterCount: Int
        let books: [BookSummary]
        let attributes: [AttributeSummary]
        let ingestionFallbacks: [String]
        let failures: [String]
    }

    /// Broad enough to discover the legacy/XHTML hints the corpus actually ships,
    /// but this is a census list, not an implementation promise. Phase 4F0 only
    /// implements rows justified by the resulting coverage and current style model.
    private static let candidateAttributes: [String: Set<String>] = [
        "img": ["width", "height", "align", "border", "hspace", "vspace"],
        "table": [
            "width", "height", "align", "valign", "border", "cellpadding",
            "cellspacing", "bgcolor", "background", "bordercolor", "frame", "rules",
        ],
        "thead": ["height", "align", "valign", "bgcolor", "background"],
        "tbody": ["height", "align", "valign", "bgcolor", "background"],
        "tfoot": ["height", "align", "valign", "bgcolor", "background"],
        "tr": ["height", "align", "valign", "bgcolor", "background"],
        "td": [
            "width", "height", "align", "valign", "border", "cellpadding",
            "cellspacing", "bgcolor", "background", "nowrap",
        ],
        "th": [
            "width", "height", "align", "valign", "border", "cellpadding",
            "cellspacing", "bgcolor", "background", "nowrap",
        ],
        "body": ["background", "bgcolor", "text", "link", "vlink", "alink"],
        "div": ["align"],
        "p": ["align"],
        "h1": ["align"], "h2": ["align"], "h3": ["align"],
        "h4": ["align"], "h5": ["align"], "h6": ["align"],
        "hr": ["align", "color", "noshade", "size", "width"],
        "font": ["color", "face", "size"],
        "br": ["clear"],
        "pre": ["wrap", "width"],
        "ol": ["type", "start", "reversed", "compact"],
        "ul": ["type", "compact"],
        "li": ["type", "value"],
        "object": ["width", "height", "align", "border", "hspace", "vspace"],
        "embed": ["width", "height", "align", "hspace", "vspace"],
        "iframe": [
            "width", "height", "align", "frameborder", "marginwidth",
            "marginheight", "scrolling",
        ],
        "canvas": ["width", "height"],
        "video": ["width", "height"],
        "input": ["width", "height", "align", "border", "hspace", "vspace", "size"],
        "marquee": ["width", "height", "align", "bgcolor", "hspace", "vspace"],
    ]

    /// Required zero rows make the requested audit explicit instead of silently
    /// omitting an attribute merely because the corpus never uses it.
    private static let mandatoryKeys: Set<Key> = {
        var keys: Set<Key> = [
            Key(tag: "img", attribute: "width"),
            Key(tag: "img", attribute: "height"),
            Key(tag: "img", attribute: "align"),
            Key(tag: "body", attribute: "background"),
            Key(tag: "body", attribute: "bgcolor"),
            Key(tag: "body", attribute: "text"),
        ]
        for tag in ["table", "td", "th"] {
            for attribute in [
                "width", "height", "align", "valign", "border",
                "cellpadding", "cellspacing", "bgcolor",
            ] {
                keys.insert(Key(tag: tag, attribute: attribute))
            }
        }
        return keys
    }()

    @Test(
        "generate Phase 4F0 HTML presentational-hint census",
        .enabled(if:
            ProcessInfo.processInfo.environment["YUEDU_RUN_PRESENTATIONAL_HINT_CENSUS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-run-presentational-hint-census")
        )
    )
    func generateCensus() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let realDirectory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["YUEDU_REAL_EPUB_DIR"]
                ?? "/Users/zhangruilin/Desktop/Test document/EPUB Format"
        )
        let inputs = try await makeInputs(repoRoot: repoRoot, realDirectory: realDirectory)
        defer {
            for input in inputs where input.isGenerated {
                try? FileManager.default.removeItem(at: input.url.deletingLastPathComponent())
            }
        }

        let artifact = await scan(inputs: inputs)
        let outputURL = repoRoot
            .appendingPathComponent("docs/browser-layout/phase4f0-html-presentational-hints-census.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: outputURL, options: .atomic)

        #expect(artifact.corpusEPUBCount == 23)
        #expect(artifact.corpusChapterCount == 7_350)
        #expect(artifact.scannedChapterCount == artifact.corpusChapterCount)
        #expect(artifact.failures.isEmpty, "Census failures: \(artifact.failures.prefix(20))")
    }

    private func scan(inputs: [BookInput]) async -> Artifact {
        var accumulators: [Key: Accumulator] = [:]
        var books: [BookSummary] = []
        var failures: [String] = []
        var ingestionFallbacks: [String] = []

        for input in inputs {
            do {
                let session = try await PublicationSession.open(sourceURL: input.url)
                let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
                var scanned = 0
                for chapterIndex in session.chapters.indices {
                    let chapterID = "\(input.id)#\(chapterIndex)"
                    do {
                        let html: String
                        do {
                            html = try await adapter.chapterHTML(at: chapterIndex)
                        } catch {
                            let encodedHref = session.chapters[chapterIndex].href
                            let decodedHref = encodedHref.removingPercentEncoding ?? encodedHref
                            guard decodedHref != encodedHref else { throw error }
                            html = try await rawArchiveText(
                                sourceURL: input.url,
                                entryPath: decodedHref
                            )
                            ingestionFallbacks.append(
                                "\(chapterID): read percent-decoded ZIP entry"
                            )
                        }
                        let document = try SwiftSoup.parse(html)
                        try scanDocument(
                            document,
                            bookID: input.id,
                            chapterID: chapterID,
                            accumulators: &accumulators
                        )
                        scanned += 1
                    } catch {
                        failures.append("\(chapterID): \(error)")
                    }
                }
                books.append(BookSummary(
                    id: input.id,
                    chapterCount: session.chapters.count,
                    scannedChapterCount: scanned
                ))
            } catch {
                failures.append("\(input.id): open failed: \(error)")
            }
        }

        let keys = Set(accumulators.keys).union(Self.mandatoryKeys)
        let attributes = keys.map { key -> AttributeSummary in
            let accumulator = accumulators[key] ?? Accumulator()
            let values = accumulator.values.map { raw, value in
                ValuePattern(
                    value: raw,
                    epubCount: value.bookIDs.count,
                    chapterCount: value.chapterIDs.count,
                    elementCount: value.elementCount
                )
            }
            .sorted {
                if $0.elementCount != $1.elementCount { return $0.elementCount > $1.elementCount }
                return $0.value < $1.value
            }
            return AttributeSummary(
                attribute: key.attribute,
                tag: key.tag,
                epubCount: accumulator.bookIDs.count,
                chapterCount: accumulator.chapterIDs.count,
                elementCount: accumulator.elementCount,
                valuePatterns: values
            )
        }
        .sorted {
            if $0.elementCount != $1.elementCount { return $0.elementCount > $1.elementCount }
            if $0.tag != $1.tag { return $0.tag < $1.tag }
            return $0.attribute < $1.attribute
        }

        return Artifact(
            schemaVersion: 1,
            corpusEPUBCount: books.count,
            corpusChapterCount: books.reduce(0) { $0 + $1.chapterCount },
            scannedChapterCount: books.reduce(0) { $0 + $1.scannedChapterCount },
            books: books.sorted { $0.id < $1.id },
            attributes: attributes,
            ingestionFallbacks: ingestionFallbacks.sorted(),
            failures: failures.sorted()
        )
    }

    private func scanDocument(
        _ document: Document,
        bookID: String,
        chapterID: String,
        accumulators: inout [Key: Accumulator]
    ) throws {
        for element in try document.getAllElements().array() {
            let tag = element.tagName().lowercased()
            guard let candidates = Self.candidateAttributes[tag] else { continue }
            for attribute in candidates where element.hasAttr(attribute) {
                let raw = try element.attr(attribute)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = String(raw.prefix(160))
                let key = Key(tag: tag, attribute: attribute)
                var accumulator = accumulators[key] ?? Accumulator()
                accumulator.bookIDs.insert(bookID)
                accumulator.chapterIDs.insert(chapterID)
                accumulator.elementCount += 1

                var value = accumulator.values[normalized] ?? ValueAccumulator()
                value.bookIDs.insert(bookID)
                value.chapterIDs.insert(chapterID)
                value.elementCount += 1
                accumulator.values[normalized] = value
                accumulators[key] = accumulator
            }
        }
    }

    private func makeInputs(repoRoot: URL, realDirectory: URL) async throws -> [BookInput] {
        var inputs: [BookInput] = []
        for url in try epubFiles(in: repoRoot.appendingPathComponent("docs/epub-regression/samples")) {
            inputs.append(BookInput(
                id: "repo-regression/\(url.lastPathComponent)",
                url: url,
                isGenerated: false
            ))
        }
        for url in try epubFiles(in: realDirectory) {
            inputs.append(BookInput(
                id: "real/\(url.lastPathComponent)",
                url: url,
                isGenerated: false
            ))
        }

        let generated: [(String, EPUBTestFixtures.Sample)] = [
            ("linear-algebra", EPUBTestFixtures.linearAlgebra()),
            ("israelsailing", EPUBTestFixtures.israelSailing()),
            ("georgia", EPUBTestFixtures.georgia()),
            ("quiz-bindings", EPUBTestFixtures.quizBindings()),
            ("prose-smoke", EPUBTestFixtures.proseSmoke()),
        ]
        for (name, sample) in generated {
            inputs.append(BookInput(
                id: "repo-generated/\(name)",
                url: try await EPUBTestFixtures.makeArchive(entries: sample.entries),
                isGenerated: true
            ))
        }
        return inputs.sorted { $0.id < $1.id }
    }

    private func epubFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "epub" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func rawArchiveText(sourceURL: URL, entryPath: String) async throws -> String {
        let archive = try await Archive(url: sourceURL, accessMode: .read)
        guard let entry = try await archive.get(entryPath) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try await archive.extract(entry, to: temporaryURL, skipCRC32: true)
        let data = try Data(contentsOf: temporaryURL)
        for encoding in [
            String.Encoding.utf8, .unicode, .utf16, .utf16LittleEndian,
            .utf16BigEndian, .isoLatin1,
        ] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
