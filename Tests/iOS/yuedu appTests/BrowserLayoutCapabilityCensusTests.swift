import Foundation
import ReadiumZIPFoundation
import SwiftSoup
import Testing
@testable import yuedu_app

private enum CensusFeature: String, Codable, CaseIterable {
    case ruby
    case verticalWriting = "vertical-writing"
    case table
    case positioned
    case mediaQueries = "media-queries"
    case modernFunctions = "calc-min-max-clamp"
    case flex
    case grid
    case unsupportedSVG = "unsupported-svg"
    case mathML = "mathml"
    case unknownDisplay = "unknown-display"
    case otherLayout = "other-layout"
    case scriptedInteractive = "scripted-interactive"
    case unsupportedFloatSubset = "unsupported-float-subset"
}

private enum CensusLayer: String, Codable {
    case layout
    case frontend
    case conditionalMedia = "conditional-media"
    case metadata
    case dom
}

private enum CensusOrigin: String, Codable, CaseIterable {
    case repoRegression = "repo-regression"
    case repoGenerated = "repo-generated"
    case officialEPUB3 = "official-epub3"
    case userProvidedReal = "user-provided-real"
}

private struct CensusPatternKey: Hashable {
    let feature: CensusFeature
    let layer: CensusLayer
    let property: String
    let value: String
    let selector: String
    let tag: String
    let classes: String
}

private final class CensusPatternAccumulator {
    var bookIDs: Set<String> = []
    var chapterIDs: Set<String> = []
    var elementHits = 0
}

private final class CensusReasonAccumulator {
    var bookIDs: Set<String> = []
    var chapterIDs: Set<String> = []
}

private struct CensusPatternSummary: Codable {
    let layer: String
    let property: String
    let value: String
    let selector: String
    let element: String
    let epubCount: Int
    let chapterCount: Int
    let elementHits: Int
}

private struct CensusLayerSummary: Codable {
    let layer: String
    let epubCount: Int
    let chapterCount: Int
    let elementHits: Int
}

private struct CensusFeatureSummary: Codable {
    let feature: String
    let epubCount: Int
    let chapterCount: Int
    let elementHits: Int
    let layers: [CensusLayerSummary]
    let patterns: [CensusPatternSummary]
}

private struct CensusScannerReasonSummary: Codable {
    let reason: String
    let epubCount: Int
    let chapterCount: Int
}

private struct CensusBookSummary: Codable {
    let id: String
    let origin: String
    let title: String
    let chapterCount: Int
    let scannedChapterCount: Int
    let scannerFallbackChapterCount: Int
}

private struct CensusOriginSummary: Codable {
    let origin: String
    let epubCount: Int
    let chapterCount: Int
    let scannedChapterCount: Int
}

private struct CensusArtifact: Codable {
    let schemaVersion: Int
    let corpusEPUBCount: Int
    let corpusChapterCount: Int
    let scannedChapterCount: Int
    let origins: [CensusOriginSummary]
    let books: [CensusBookSummary]
    let features: [CensusFeatureSummary]
    let scannerFallbacks: [CensusScannerReasonSummary]
    let ingestionFallbacks: [String]
    let failures: [String]
}

private final class CensusCollector {
    private var patterns: [CensusPatternKey: CensusPatternAccumulator] = [:]
    private var scannerReasons: [String: CensusReasonAccumulator] = [:]

    func record(
        feature: CensusFeature,
        layer: CensusLayer,
        property: String,
        value: String,
        selector: String,
        element: Element?,
        bookID: String,
        chapterID: String
    ) {
        let tag = element?.tagName().lowercased() ?? "document"
        let classes = ((try? element?.classNames().sorted()) ?? []).joined(separator: ".")
        let key = CensusPatternKey(
            feature: feature,
            layer: layer,
            property: Self.short(property, limit: 80),
            value: Self.short(value, limit: 160),
            selector: Self.short(selector, limit: 200),
            tag: tag,
            classes: classes
        )
        let accumulator = patterns[key] ?? CensusPatternAccumulator()
        accumulator.bookIDs.insert(bookID)
        accumulator.chapterIDs.insert(chapterID)
        accumulator.elementHits += 1
        patterns[key] = accumulator
    }

    func recordScannerReason(_ reason: String, bookID: String, chapterID: String) {
        let accumulator = scannerReasons[reason] ?? CensusReasonAccumulator()
        accumulator.bookIDs.insert(bookID)
        accumulator.chapterIDs.insert(chapterID)
        scannerReasons[reason] = accumulator
    }

    func featureSummaries() -> [CensusFeatureSummary] {
        CensusFeature.allCases.compactMap { feature in
            let matching = patterns.filter { $0.key.feature == feature }
            guard !matching.isEmpty else { return nil }

            let bookIDs = matching.values.reduce(into: Set<String>()) { $0.formUnion($1.bookIDs) }
            let chapterIDs = matching.values.reduce(into: Set<String>()) { $0.formUnion($1.chapterIDs) }
            let elementHits = matching.values.reduce(0) { $0 + $1.elementHits }

            let layers = CensusLayer.allCasesPresent(in: matching).map { layer in
                let entries = matching.filter { $0.key.layer == layer }
                return CensusLayerSummary(
                    layer: layer.rawValue,
                    epubCount: entries.values.reduce(into: Set<String>()) { $0.formUnion($1.bookIDs) }.count,
                    chapterCount: entries.values.reduce(into: Set<String>()) { $0.formUnion($1.chapterIDs) }.count,
                    elementHits: entries.values.reduce(0) { $0 + $1.elementHits }
                )
            }

            let topPatterns = matching.map { key, value in
                CensusPatternSummary(
                    layer: key.layer.rawValue,
                    property: key.property,
                    value: key.value,
                    selector: key.selector,
                    element: key.classes.isEmpty ? "<\(key.tag)>" : "<\(key.tag).\(key.classes)>",
                    epubCount: value.bookIDs.count,
                    chapterCount: value.chapterIDs.count,
                    elementHits: value.elementHits
                )
            }
            .sorted {
                if $0.chapterCount != $1.chapterCount { return $0.chapterCount > $1.chapterCount }
                if $0.epubCount != $1.epubCount { return $0.epubCount > $1.epubCount }
                if $0.elementHits != $1.elementHits { return $0.elementHits > $1.elementHits }
                return "\($0.property)|\($0.value)|\($0.selector)|\($0.element)"
                    < "\($1.property)|\($1.value)|\($1.selector)|\($1.element)"
            }
            .prefix(30)

            return CensusFeatureSummary(
                feature: feature.rawValue,
                epubCount: bookIDs.count,
                chapterCount: chapterIDs.count,
                elementHits: elementHits,
                layers: layers,
                patterns: Array(topPatterns)
            )
        }
        .sorted {
            if $0.epubCount != $1.epubCount { return $0.epubCount > $1.epubCount }
            if $0.chapterCount != $1.chapterCount { return $0.chapterCount > $1.chapterCount }
            return $0.feature < $1.feature
        }
    }

    func scannerReasonSummaries() -> [CensusScannerReasonSummary] {
        scannerReasons.map { reason, value in
            CensusScannerReasonSummary(
                reason: reason,
                epubCount: value.bookIDs.count,
                chapterCount: value.chapterIDs.count
            )
        }
        .sorted {
            if $0.epubCount != $1.epubCount { return $0.epubCount > $1.epubCount }
            if $0.chapterCount != $1.chapterCount { return $0.chapterCount > $1.chapterCount }
            return $0.reason < $1.reason
        }
    }

    private static func short(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

private extension CensusLayer {
    static func allCasesPresent(
        in matching: [CensusPatternKey: CensusPatternAccumulator]
    ) -> [CensusLayer] {
        Set(matching.keys.map(\.layer)).sorted { $0.rawValue < $1.rawValue }
    }
}

private struct CensusRawRule {
    let selector: String
    let declarations: String
    let mediaQuery: String?
    let globalOrder: Int
}

private enum CensusRawCSSParser {
    static func rules(in stylesheets: [String]) -> [CensusRawRule] {
        var result: [CensusRawRule] = []
        var order = 0
        for stylesheet in stylesheets {
            parseBlocks(
                stripComments(stylesheet),
                inheritedMedia: nil,
                into: &result,
                order: &order
            )
        }
        return result
    }

    private static func parseBlocks(
        _ css: String,
        inheritedMedia: String?,
        into result: inout [CensusRawRule],
        order: inout Int
    ) {
        let chars = Array(css)
        var cursor = 0
        while cursor < chars.count {
            while cursor < chars.count, chars[cursor].isWhitespace || chars[cursor] == ";" {
                cursor += 1
            }
            guard cursor < chars.count else { break }

            let preludeStart = cursor
            var quote: Character?
            while cursor < chars.count {
                let character = chars[cursor]
                if let active = quote {
                    if character == active, cursor == 0 || chars[cursor - 1] != "\\" { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "{" || character == ";" {
                    break
                }
                cursor += 1
            }
            guard cursor < chars.count else { break }
            if chars[cursor] == ";" {
                cursor += 1
                continue
            }

            let prelude = String(chars[preludeStart..<cursor])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = cursor + 1
            cursor = bodyStart
            var depth = 1
            quote = nil
            while cursor < chars.count, depth > 0 {
                let character = chars[cursor]
                if let active = quote {
                    if character == active, chars[cursor - 1] != "\\" { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                }
                cursor += 1
            }
            guard depth == 0 else { break }
            let bodyEnd = cursor - 1
            let body = String(chars[bodyStart..<bodyEnd])

            if prelude.lowercased().hasPrefix("@media") {
                let query = String(prelude.dropFirst(6))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                parseBlocks(body, inheritedMedia: query, into: &result, order: &order)
            } else if !prelude.hasPrefix("@") {
                for selector in splitSelectorList(prelude) where !selector.isEmpty {
                    result.append(CensusRawRule(
                        selector: selector,
                        declarations: body,
                        mediaQuery: inheritedMedia,
                        globalOrder: order
                    ))
                    order += 1
                }
            }
        }
    }

    private static func splitSelectorList(_ selectorList: String) -> [String] {
        let chars = Array(selectorList)
        var result: [String] = []
        var start = 0
        var squareDepth = 0
        var roundDepth = 0
        var quote: Character?
        for index in chars.indices {
            let character = chars[index]
            if let active = quote {
                if character == active, index == 0 || chars[index - 1] != "\\" { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                squareDepth += 1
            } else if character == "]" {
                squareDepth = max(0, squareDepth - 1)
            } else if character == "(" {
                roundDepth += 1
            } else if character == ")" {
                roundDepth = max(0, roundDepth - 1)
            } else if character == ",", squareDepth == 0, roundDepth == 0 {
                result.append(String(chars[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = index + 1
            }
        }
        result.append(String(chars[start..<chars.count]).trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private static func stripComments(_ css: String) -> String {
        css.replacingOccurrences(
            of: #"(?s)/\*.*?(?:\*/|\z)"#,
            with: "",
            options: .regularExpression
        )
    }
}

private struct CensusRuleCandidate {
    let rawSelector: String
    let parsedSelector: CSSSelector?
    let fallbackElementIDs: Set<ObjectIdentifier>
    let specificity: Int
    let globalOrder: Int
    let declarationBlock: CSSParser.DeclarationBlock
    let mediaQuery: String?

    var frontendParsed: Bool { parsedSelector != nil }

    func matches(_ element: Element) -> Bool {
        if let parsedSelector {
            return parsedSelector.matches(element: element, parent: element.parent())
        }
        return fallbackElementIDs.contains(ObjectIdentifier(element))
    }
}

private struct CensusResolvedDeclaration {
    let property: String
    let value: String
    let selector: String
    let frontendParsed: Bool
}

private enum BrowserLayoutCapabilityCensus {
    private static let officialSampleNames: Set<String> = [
        "georgia-pls-ssml.epub",
        "israelsailing.epub",
        "kusamakura-japanese-vertical-writing.epub",
        "mahabharata.epub",
    ]

    struct BookInput {
        let id: String
        let origin: CensusOrigin
        let url: URL
    }

    static func scanChapter(
        html: String,
        cssTexts: [String],
        bookID: String,
        chapterIndex: Int,
        opfVertical: Bool,
        fixedLayout: Bool,
        collector: CensusCollector
    ) throws {
        let document = try SwiftSoup.parse(html)
        let elements = try document.getAllElements().array()
        let chapterID = "\(bookID)#\(chapterIndex)"
        let stylesheets = orderedUnique(cssTexts + LegacyCSSFrontendSupport.inlineStyles(in: document))
        let candidates = makeCandidates(
            rawRules: CensusRawCSSParser.rules(in: stylesheets),
            document: document
        )

        scanDOM(
            document: document,
            bookID: bookID,
            chapterID: chapterID,
            collector: collector
        )

        if opfVertical {
            collector.record(
                feature: .verticalWriting, layer: .metadata,
                property: "rendition:writing-mode", value: "vertical-rl",
                selector: "<package metadata>", element: document.body(),
                bookID: bookID, chapterID: chapterID
            )
        }
        if fixedLayout {
            collector.record(
                feature: .otherLayout, layer: .metadata,
                property: "rendition:layout", value: "pre-paginated",
                selector: "<package metadata>", element: document.body(),
                bookID: bookID, chapterID: chapterID
            )
        }

        for element in elements {
            let matchedBase = candidates
                .filter { $0.mediaQuery == nil && $0.matches(element) }
                .sorted(by: cascadeOrder)
            let resolved = resolveDeclarations(matchedBase, inlineStyle: (try? element.attr("style")) ?? "")
            for declaration in resolved.values {
                let layer: CensusLayer = declaration.frontendParsed ? .layout : .frontend
                let classified = features(for: declaration.property, value: declaration.value)
                for feature in classified {
                    collector.record(
                        feature: feature, layer: layer,
                        property: declaration.property, value: declaration.value,
                        selector: declaration.selector, element: element,
                        bookID: bookID, chapterID: chapterID
                    )
                }
                if !declaration.frontendParsed, !classified.isEmpty {
                    collector.record(
                        feature: .otherLayout, layer: .frontend,
                        property: "frontend-unparseable-selector",
                        value: "\(declaration.property): \(declaration.value)",
                        selector: declaration.selector, element: element,
                        bookID: bookID, chapterID: chapterID
                    )
                }
            }

            let matchedMedia = candidates.filter { $0.mediaQuery != nil && $0.matches(element) }
            for rule in matchedMedia {
                let declarations = rule.declarationBlock.merged
                let layoutDeclarations = declarations.filter { !features(for: $0.key, value: $0.value).isEmpty }
                if layoutDeclarations.isEmpty {
                    collector.record(
                        feature: .mediaQueries, layer: .conditionalMedia,
                        property: "paint-only-or-non-layout", value: rule.mediaQuery ?? "",
                        selector: rule.rawSelector, element: element,
                        bookID: bookID, chapterID: chapterID
                    )
                } else {
                    for (property, value) in layoutDeclarations.sorted(by: { $0.key < $1.key }) {
                        collector.record(
                            feature: .mediaQueries, layer: .conditionalMedia,
                            property: property, value: "@media \(rule.mediaQuery ?? "") → \(value)",
                            selector: rule.rawSelector, element: element,
                            bookID: bookID, chapterID: chapterID
                        )
                        for feature in features(for: property, value: value) {
                            collector.record(
                                feature: feature, layer: .conditionalMedia,
                                property: property, value: value,
                                selector: "@media \(rule.mediaQuery ?? "") { \(rule.rawSelector) }",
                                element: element, bookID: bookID, chapterID: chapterID
                            )
                        }
                    }
                }
            }
        }

        if let body = document.body() {
            let productionRules = LegacyCSSFrontendSupport.parseRules(in: stylesheets)
            let tree = ComputedStyleTreeBuilder(
                rules: productionRules,
                config: BrowserLayoutConfig()
            ).buildTree(body: body)
            scanUnsupportedFloats(
                node: tree,
                floatedAncestor: false,
                bookID: bookID,
                chapterID: chapterID,
                collector: collector
            )
        }
    }

    static func makePhysicalInputs(repoRoot: URL, realDirectory: URL) throws -> [BookInput] {
        let repoSampleDirectory = repoRoot.appendingPathComponent("docs/epub-regression/samples")
        let repoURLs = try epubFiles(in: repoSampleDirectory)
        let realURLs = try epubFiles(in: realDirectory)

        var inputs = repoURLs.map {
            BookInput(
                id: "repo-regression/\($0.lastPathComponent)",
                origin: .repoRegression,
                url: $0
            )
        }
        inputs += realURLs.map {
            let origin: CensusOrigin = officialSampleNames.contains($0.lastPathComponent)
                ? .officialEPUB3
                : .userProvidedReal
            return BookInput(
                id: "\(origin.rawValue)/\($0.lastPathComponent)",
                origin: origin,
                url: $0
            )
        }
        return inputs.sorted { $0.id < $1.id }
    }

    @MainActor
    static func makeGeneratedInputs() async throws -> [BookInput] {
        let fixtures: [(String, EPUBTestFixtures.Sample)] = [
            ("linear-algebra", EPUBTestFixtures.linearAlgebra()),
            ("israelsailing", EPUBTestFixtures.israelSailing()),
            ("georgia", EPUBTestFixtures.georgia()),
            ("quiz-bindings", EPUBTestFixtures.quizBindings()),
            ("prose-smoke", EPUBTestFixtures.proseSmoke()),
        ]
        var inputs: [BookInput] = []
        for (name, fixture) in fixtures {
            inputs.append(BookInput(
                id: "repo-generated/\(name)",
                origin: .repoGenerated,
                url: try await EPUBTestFixtures.makeArchive(entries: fixture.entries)
            ))
        }
        return inputs
    }

    @MainActor
    static func run(inputs: [BookInput]) async -> CensusArtifact {
        let collector = CensusCollector()
        var books: [CensusBookSummary] = []
        var failures: [String] = []
        var ingestionFallbacks: [String] = []

        for input in inputs.sorted(by: { $0.id < $1.id }) {
            do {
                let session = try await PublicationSession.open(sourceURL: input.url)
                let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
                var scanned = 0
                var fallback = 0
                for chapterIndex in session.chapters.indices {
                    let chapterID = "\(input.id)#\(chapterIndex)"
                    do {
                        let html: String
                        let usedRawArchiveFallback: Bool
                        do {
                            html = try await adapter.chapterHTML(at: chapterIndex)
                            usedRawArchiveFallback = false
                        } catch {
                            // Official Kusamakura ships Unicode ZIP entry names. PublicationSession
                            // percent-encodes the spine href, but the Readium resource lookup expects
                            // the original decoded entry path, so every chapter currently fails before
                            // CSSFrontend is reached. The census must still inspect that official book;
                            // keep this test-only fallback restricted to percent-decoded archive entries.
                            // Delete it when PublicationSession can read the same href directly.
                            html = try await rawArchiveChapterHTML(
                                sourceURL: input.url,
                                encodedHref: session.chapters[chapterIndex].href
                            )
                            usedRawArchiveFallback = true
                            ingestionFallbacks.append(
                                "\(chapterID): PublicationSession resource lookup failed; read decoded ZIP entry and active CSS"
                            )
                        }
                        let cssTexts: [String]
                        if usedRawArchiveFallback {
                            // processedCSS cannot discover chapter-linked stylesheets when the same
                            // chapter resource is unreadable. Read only rel=stylesheet links from the
                            // fallback DOM; rel="alternate stylesheet" must not affect this census.
                            cssTexts = try await rawArchiveStylesheets(
                                sourceURL: input.url,
                                encodedChapterHref: session.chapters[chapterIndex].href,
                                html: html
                            )
                        } else {
                            cssTexts = await adapter.processedCSS(forChapter: chapterIndex)
                        }
                        let scanner = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: cssTexts)
                        if !scanner.supported { fallback += 1 }
                        for reason in scanner.unsupportedFeatures {
                            collector.recordScannerReason(
                                reason.description,
                                bookID: input.id,
                                chapterID: chapterID
                            )
                        }
                        try scanChapter(
                            html: html,
                            cssTexts: cssTexts,
                            bookID: input.id,
                            chapterIndex: chapterIndex,
                            opfVertical: session.epubWritingMode == .verticalRL,
                            fixedLayout: session.layoutMode == .prePaginated,
                            collector: collector
                        )
                        scanned += 1
                    } catch {
                        failures.append("\(chapterID): \(error)")
                    }
                }
                books.append(CensusBookSummary(
                    id: input.id,
                    origin: input.origin.rawValue,
                    title: session.bookTitle,
                    chapterCount: session.chapters.count,
                    scannedChapterCount: scanned,
                    scannerFallbackChapterCount: fallback
                ))
            } catch {
                failures.append("\(input.id): open failed: \(error)")
            }
        }

        let origins = CensusOrigin.allCases.map { origin in
            let subset = books.filter { $0.origin == origin.rawValue }
            return CensusOriginSummary(
                origin: origin.rawValue,
                epubCount: subset.count,
                chapterCount: subset.reduce(0) { $0 + $1.chapterCount },
                scannedChapterCount: subset.reduce(0) { $0 + $1.scannedChapterCount }
            )
        }
        .filter { $0.epubCount > 0 }

        return CensusArtifact(
            schemaVersion: 1,
            corpusEPUBCount: books.count,
            corpusChapterCount: books.reduce(0) { $0 + $1.chapterCount },
            scannedChapterCount: books.reduce(0) { $0 + $1.scannedChapterCount },
            origins: origins,
            books: books.sorted { $0.id < $1.id },
            features: collector.featureSummaries(),
            scannerFallbacks: collector.scannerReasonSummaries(),
            ingestionFallbacks: ingestionFallbacks.sorted(),
            failures: failures.sorted()
        )
    }

    fileprivate static func rawArchiveChapterHTML(
        sourceURL: URL,
        encodedHref: String
    ) async throws -> String {
        let decodedHref = encodedHref.removingPercentEncoding ?? encodedHref
        guard decodedHref != encodedHref else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try await rawArchiveText(sourceURL: sourceURL, entryPath: decodedHref)
    }

    fileprivate static func rawArchiveStylesheets(
        sourceURL: URL,
        encodedChapterHref: String,
        html: String
    ) async throws -> [String] {
        let decodedChapterHref = encodedChapterHref.removingPercentEncoding ?? encodedChapterHref
        let document = try SwiftSoup.parse(html)
        guard let head = document.head() else { return [] }
        var stylesheets: [String] = []

        for style in try head.select("style").array() {
            let css = try style.html()
            if !css.isEmpty { stylesheets.append(css) }
        }
        for link in try head.select("link[rel=stylesheet][href]").array() {
            let href = try link.attr("href")
            guard !href.isEmpty, URL(string: href)?.scheme == nil else { continue }
            let pathWithoutFragment = String(href.split(separator: "#", maxSplits: 1)[0])
            let pathWithoutQuery = String(pathWithoutFragment.split(separator: "?", maxSplits: 1)[0])
            let chapterDirectory = (decodedChapterHref as NSString).deletingLastPathComponent
            let relativePath = (chapterDirectory as NSString).appendingPathComponent(pathWithoutQuery)
            let normalizedPath = URL(fileURLWithPath: "/\(relativePath)")
                .standardizedFileURL.path
                .drop(while: { $0 == "/" })
            stylesheets.append(try await rawArchiveText(
                sourceURL: sourceURL,
                entryPath: String(normalizedPath)
            ))
        }
        return orderedUnique(stylesheets)
    }

    private static func rawArchiveText(
        sourceURL: URL,
        entryPath: String
    ) async throws -> String {
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
            if let html = String(data: data, encoding: encoding) { return html }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private static func epubFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "epub" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func makeCandidates(
        rawRules: [CensusRawRule],
        document: Document
    ) -> [CensusRuleCandidate] {
        rawRules.map { raw in
            let synthetic = "\(raw.selector) { \(raw.declarations) }"
            let parsed = CSSParser.parse(css: synthetic, orderOffset: 0).first
            let fallbackIDs: Set<ObjectIdentifier>
            if parsed == nil {
                fallbackIDs = Set(((try? document.select(raw.selector).array()) ?? []).map(ObjectIdentifier.init))
            } else {
                fallbackIDs = []
            }
            return CensusRuleCandidate(
                rawSelector: raw.selector,
                parsedSelector: parsed?.selector,
                fallbackElementIDs: fallbackIDs,
                specificity: parsed?.specificity ?? approximateSpecificity(raw.selector),
                globalOrder: raw.globalOrder,
                declarationBlock: CSSParser.parseDeclarationBlock(raw.declarations),
                mediaQuery: raw.mediaQuery
            )
        }
    }

    private static func approximateSpecificity(_ selector: String) -> Int {
        let ids = regexCount(#"#[A-Za-z0-9_-]+"#, in: selector)
        let classesAndAttributes = regexCount(#"\.[A-Za-z0-9_-]+|\[[^\]]+\]|:[A-Za-z0-9_-]+"#, in: selector)
        let tags = selector
            .split(whereSeparator: { $0.isWhitespace || $0 == ">" || $0 == "+" || $0 == "~" })
            .filter { token in
                guard let first = token.first else { return false }
                return first.isLetter || first == "*"
            }
            .filter { $0 != "*" }
            .count
        return ids * 100 + classesAndAttributes * 10 + tags
    }

    private static func regexCount(_ pattern: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }

    private static func cascadeOrder(_ lhs: CensusRuleCandidate, _ rhs: CensusRuleCandidate) -> Bool {
        if lhs.specificity != rhs.specificity { return lhs.specificity < rhs.specificity }
        return lhs.globalOrder < rhs.globalOrder
    }

    private static func resolveDeclarations(
        _ candidates: [CensusRuleCandidate],
        inlineStyle: String
    ) -> [String: CensusResolvedDeclaration] {
        var resolved: [String: CensusResolvedDeclaration] = [:]

        func apply(
            _ declarations: [String: String],
            order: [String],
            selector: String,
            frontendParsed: Bool
        ) {
            for property in order {
                guard let value = declarations[property] else { continue }
                resolved[property] = CensusResolvedDeclaration(
                    property: property,
                    value: value,
                    selector: selector,
                    frontendParsed: frontendParsed
                )
            }
        }

        for candidate in candidates {
            apply(
                candidate.declarationBlock.normal,
                order: candidate.declarationBlock.order,
                selector: candidate.rawSelector,
                frontendParsed: candidate.frontendParsed
            )
        }
        let inline = CSSParser.parseDeclarationBlock(inlineStyle)
        apply(inline.normal, order: inline.order, selector: "<inline style>", frontendParsed: true)
        for candidate in candidates {
            apply(
                candidate.declarationBlock.important,
                order: candidate.declarationBlock.order,
                selector: candidate.rawSelector,
                frontendParsed: candidate.frontendParsed
            )
        }
        apply(inline.important, order: inline.order, selector: "<inline style !important>", frontendParsed: true)
        return resolved
    }

    private static func features(for property: String, value rawValue: String) -> [CensusFeature] {
        let key = property.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var result: Set<CensusFeature> = []

        if key == "position", ["absolute", "fixed", "sticky"].contains(value) {
            result.insert(.positioned)
        }
        if key == "writing-mode" || key == "-webkit-writing-mode" || key == "-epub-writing-mode" {
            if value.contains("vertical") { result.insert(.verticalWriting) }
        }
        if key == "ruby-align" || key == "ruby-position" || key == "ruby-merge" {
            result.insert(.ruby)
        }
        if key == "display" {
            if value.contains("table") {
                result.insert(.table)
            } else if value == "flex" || value == "inline-flex" {
                result.insert(.flex)
            } else if value == "grid" || value == "inline-grid" {
                result.insert(.grid)
            } else if !["none", "block", "inline", "inline-block"].contains(value) {
                result.insert(.unknownDisplay)
            }
        }
        if flexProperties.contains(key), !isZeroOrInitial(value) {
            result.insert(.flex)
        }
        if gridProperties.contains(key), !isZeroOrInitial(value) {
            result.insert(.grid)
        }
        if modernFunctionProperties.contains(key), containsModernFunction(value) {
            result.insert(.modernFunctions)
        }
        if otherLayoutProperties.contains(key), isNonInitialOtherLayout(property: key, value: value) {
            result.insert(.otherLayout)
        }
        return result.sorted { $0.rawValue < $1.rawValue }
    }

    private static let flexProperties: Set<String> = [
        "flex", "flex-basis", "flex-direction", "flex-flow", "flex-grow", "flex-shrink",
        "flex-wrap", "align-content", "align-items", "align-self", "justify-content", "order",
    ]

    private static let gridProperties: Set<String> = [
        "grid", "grid-area", "grid-auto-columns", "grid-auto-flow", "grid-auto-rows",
        "grid-column", "grid-column-end", "grid-column-start", "grid-row", "grid-row-end",
        "grid-row-start", "grid-template", "grid-template-areas", "grid-template-columns",
        "grid-template-rows", "place-content", "place-items", "place-self", "gap",
        "column-gap", "row-gap",
    ]

    private static let modernFunctionProperties: Set<String> = [
        "width", "height", "min-width", "min-height", "max-width", "max-height",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
        "top", "right", "bottom", "left", "inset", "inset-block", "inset-inline",
        "font-size", "line-height", "text-indent", "border-width", "border-radius",
        "gap", "row-gap", "column-gap", "flex-basis", "grid-template-columns",
        "grid-template-rows", "column-width", "columns",
    ]

    private static let otherLayoutProperties: Set<String> = [
        "min-width", "min-height", "max-height", "box-sizing", "text-indent",
        "columns", "column-count", "column-width", "column-gap", "column-span", "column-fill",
        "overflow", "overflow-x", "overflow-y", "break-before", "break-after", "break-inside",
        "page-break-before", "page-break-after", "page-break-inside", "orphans", "widows",
        "shape-outside", "shape-margin", "object-fit", "object-position", "aspect-ratio",
        "list-style", "list-style-type", "list-style-position", "caption-side",
        "border-collapse", "border-spacing", "empty-cells", "direction", "unicode-bidi",
        "text-orientation", "text-combine-upright", "contain",
    ]

    private static func containsModernFunction(_ value: String) -> Bool {
        ["calc(", "min(", "max(", "clamp("].contains { value.contains($0) }
    }

    private static func isZeroOrInitial(_ value: String) -> Bool {
        ["0", "0px", "normal", "auto", "none", "initial", "unset", "inherit"].contains(value)
    }

    private static func isNonInitialOtherLayout(property: String, value: String) -> Bool {
        let defaults: [String: Set<String>] = [
            "min-width": ["auto", "0", "0px"],
            "min-height": ["auto", "0", "0px"],
            "max-height": ["none"],
            "box-sizing": ["content-box"],
            "text-indent": ["0", "0px", "0em"],
            "overflow": ["visible"], "overflow-x": ["visible"], "overflow-y": ["visible"],
            "break-before": ["auto"], "break-after": ["auto"], "break-inside": ["auto"],
            "page-break-before": ["auto"], "page-break-after": ["auto"], "page-break-inside": ["auto"],
            "object-fit": ["fill"], "object-position": ["50% 50%"],
            "list-style-position": ["outside"], "caption-side": ["top"],
            "border-collapse": ["separate"], "empty-cells": ["show"],
            "direction": ["ltr"], "unicode-bidi": ["normal"],
            "text-orientation": ["mixed"], "text-combine-upright": ["none"],
            "contain": ["none"],
        ]
        return !(defaults[property]?.contains(value) ?? false)
    }

    private static func scanDOM(
        document: Document,
        bookID: String,
        chapterID: String,
        collector: CensusCollector
    ) {
        func recordAll(_ selector: String, feature: CensusFeature, property: String) {
            for element in (try? document.select(selector).array()) ?? [] {
                collector.record(
                    feature: feature, layer: .dom,
                    property: property, value: element.tagName().lowercased(),
                    selector: "<DOM \(selector)>", element: element,
                    bookID: bookID, chapterID: chapterID
                )
            }
        }

        recordAll("ruby, rt, rp", feature: .ruby, property: "element")
        recordAll("table, thead, tbody, tfoot, tr, td, th, colgroup, col, caption", feature: .table, property: "element")
        recordAll("math", feature: .mathML, property: "element")
        recordAll("script, iframe, object, embed, canvas, audio, video", feature: .scriptedInteractive, property: "element")

        for svg in (try? document.select("svg").array()) ?? [] {
            if BoxTreeBuilder.svgWrappedImageSource(svg) == nil {
                collector.record(
                    feature: .unsupportedSVG, layer: .dom,
                    property: "element", value: "complex-inline-svg",
                    selector: "<DOM svg>", element: svg,
                    bookID: bookID, chapterID: chapterID
                )
            }
        }
    }

    private static func scanUnsupportedFloats(
        node: ComputedStyleNode,
        floatedAncestor: Bool,
        bookID: String,
        chapterID: String,
        collector: CensusCollector
    ) {
        let isFloated = node.style.isFloated
        if isFloated {
            let isReplaced = node.tag == "img"
                || (node.tag == "svg" && node.element.flatMap(BoxTreeBuilder.svgWrappedImageSource) != nil)
            if (!isReplaced && node.style.width == .auto) || floatedAncestor {
                collector.record(
                    feature: .unsupportedFloatSubset, layer: .layout,
                    property: "float", value: floatedAncestor ? "nested-float" : "width:auto",
                    selector: "<computed style>", element: node.element,
                    bookID: bookID, chapterID: chapterID
                )
            }
        }
        for child in node.children {
            guard case .element(let childNode) = child else { continue }
            scanUnsupportedFloats(
                node: childNode,
                floatedAncestor: floatedAncestor || isFloated,
                bookID: bookID,
                chapterID: chapterID,
                collector: collector
            )
        }
    }

    static func describe(_ selector: CSSSelector) -> String {
        selector.components.enumerated().map { index, component in
            var part = component.tag ?? "*"
            if let id = component.id { part += "#\(id)" }
            for className in component.classes.sorted() { part += ".\(className)" }
            for attribute in component.attributes {
                part += "[\(attribute.name)\(attributeOperator(attribute.op))\(attribute.value)]"
            }
            if component.firstChild { part += ":first-child" }
            if index == 0 { return part }
            return (component.combinator == .child ? "> " : " ") + part
        }
        .joined()
    }

    private static func attributeOperator(_ op: CSSSelector.AttributeSelector.Op) -> String {
        switch op {
        case .exists: return ""
        case .equals: return "="
        case .includes: return "~="
        case .dashMatch: return "|="
        case .prefix: return "^="
        case .suffix: return "$="
        case .substring: return "*="
        }
    }
}

@MainActor
struct BrowserLayoutCapabilityCensusUnitTests {
    nonisolated private static let kusamakuraPath = "/Users/zhangruilin/Desktop/Test document/EPUB Format/kusamakura-japanese-vertical-writing.epub"

    @Test func censusUsesFinalCascadeAndRealSelectorMatches() throws {
        let collector = CensusCollector()
        try BrowserLayoutCapabilityCensus.scanChapter(
            html: "<html><body><div class='hit'><ruby>字<rt>zi</rt></ruby></div></body></html>",
            cssTexts: [
                ".missing { display: flex; }",
                ".hit { position: absolute; } .hit { position: static; }",
            ],
            bookID: "synthetic", chapterIndex: 0,
            opfVertical: false, fixedLayout: false,
            collector: collector
        )
        let features = Dictionary(uniqueKeysWithValues: collector.featureSummaries().map { ($0.feature, $0) })
        #expect(features[CensusFeature.ruby.rawValue]?.chapterCount == 1)
        #expect(features[CensusFeature.flex.rawValue] == nil)
        #expect(features[CensusFeature.positioned.rawValue] == nil)
    }

    @Test func censusClassifiesConditionalAndFrontendPatterns() throws {
        let collector = CensusCollector()
        try BrowserLayoutCapabilityCensus.scanChapter(
            html: "<html><body><p class='x'>Text</p><table><tr><td>A</td></tr></table></body></html>",
            cssTexts: [
                "@media screen and (min-width: 300px) { .x { display: grid; } }",
                ".x + table { position: absolute; }",
                ".x { width: calc(100% - 2em); }",
            ],
            bookID: "synthetic", chapterIndex: 1,
            opfVertical: false, fixedLayout: false,
            collector: collector
        )
        let features = Dictionary(uniqueKeysWithValues: collector.featureSummaries().map { ($0.feature, $0) })
        #expect(features[CensusFeature.mediaQueries.rawValue]?.chapterCount == 1)
        #expect(features[CensusFeature.grid.rawValue]?.chapterCount == 1)
        #expect(features[CensusFeature.modernFunctions.rawValue]?.chapterCount == 1)
        #expect(features[CensusFeature.table.rawValue]?.chapterCount == 1)
        #expect(features[CensusFeature.positioned.rawValue]?.layers.contains { $0.layer == CensusLayer.frontend.rawValue } == true)
    }

    @Test func selectorDescriptionIsStable() throws {
        let rule = try #require(CSSParser.parse(css: "section.chapter > p.note:first-child { margin: 0 }").first)
        #expect(BrowserLayoutCapabilityCensus.describe(rule.selector) == "section.chapter> p.note:first-child")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: kusamakuraPath)))
    func decodedUnicodeArchiveEntryCanBeReadForCensus() async throws {
        let html = try await BrowserLayoutCapabilityCensus.rawArchiveChapterHTML(
            sourceURL: URL(fileURLWithPath: Self.kusamakuraPath),
            encodedHref: "OPS/xhtml/%E4%B8%80.xhtml"
        )
        #expect(html.contains("<title>一</title>"))
        #expect(html.contains("vertical.css"))

        let stylesheets = try await BrowserLayoutCapabilityCensus.rawArchiveStylesheets(
            sourceURL: URL(fileURLWithPath: Self.kusamakuraPath),
            encodedChapterHref: "OPS/xhtml/%E4%B8%80.xhtml",
            html: html
        )
        #expect(stylesheets.count == 1)
        #expect(stylesheets[0].contains("-epub-writing-mode: vertical-rl"))
        #expect(!stylesheets[0].contains("-epub-writing-mode: horizontal-tb"))
    }
}

@MainActor
struct BrowserLayoutCapabilityCensusTests {
    @Test(
        "generate Phase 4C EPUB capability census",
        .enabled(if:
            ProcessInfo.processInfo.environment["YUEDU_RUN_CAPABILITY_CENSUS"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/yuedu-run-capability-census")
        )
    )
    func generateCapabilityCensus() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let realDirectory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["YUEDU_REAL_EPUB_DIR"]
                ?? "/Users/zhangruilin/Desktop/Test document/EPUB Format"
        )
        let outputURL = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["YUEDU_CAPABILITY_CENSUS_OUTPUT"]
                ?? defaultOutputPath(repoRoot: repoRoot)
        )

        let physical = try BrowserLayoutCapabilityCensus.makePhysicalInputs(
            repoRoot: repoRoot,
            realDirectory: realDirectory
        )
        let generated = try await BrowserLayoutCapabilityCensus.makeGeneratedInputs()
        let allInputs = physical + generated
        let selectedInputs: [BrowserLayoutCapabilityCensus.BookInput]
        if censusBatchKey() == "kusamakura" {
            selectedInputs = allInputs.filter {
                $0.id == "official-epub3/kusamakura-japanese-vertical-writing.epub"
            }
        } else {
            selectedInputs = allInputs
        }
        let artifact = await BrowserLayoutCapabilityCensus.run(inputs: selectedInputs)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)

        #expect(artifact.corpusEPUBCount == selectedInputs.count)
        #expect(artifact.scannedChapterCount == artifact.corpusChapterCount)
        #expect(artifact.failures.isEmpty, "Census failures: \(artifact.failures.prefix(20))")
    }

    nonisolated private func censusBatchKey() -> String? {
        let marker = "/tmp/yuedu-run-capability-census"
        return (try? FileManager.default.contentsOfDirectory(atPath: marker))?
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .first
    }

    nonisolated private func defaultOutputPath(repoRoot: URL) -> String {
        if let batch = censusBatchKey() {
            return repoRoot
                .appendingPathComponent("docs/browser-layout/phase4c-census-parts/\(batch).json")
                .path
        }
        return repoRoot
            .appendingPathComponent("docs/browser-layout/phase4c-layout-capability-census.json")
            .path
    }
}
