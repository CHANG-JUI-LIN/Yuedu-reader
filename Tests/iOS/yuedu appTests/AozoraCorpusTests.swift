import Foundation
import Testing
@testable import yuedu_app

/// The parser over the whole Aozora Bunko text corpus. The corpus stays out of
/// the repo (some works are still under copyright and only redistributed by
/// Aozora Bunko with permission): point AOZORA_CORPUS at a checkout of
/// https://github.com/aozorahack/aozorabunko_text. It reaches the test runner
/// as TEST_RUNNER_AOZORA_CORPUS=<path>; without it the suite is skipped.
@Suite("Aozora corpus", .enabled(if: ProcessInfo.processInfo.environment["AOZORA_CORPUS"] != nil))
struct AozoraCorpusTests {
    @Test("every work parses, nothing of the notation is left in its text, and the counts match the census")
    func corpus() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AOZORA_CORPUS"]))
        let works = try Self.pickWorks(in: root.appendingPathComponent("cards"))
        try #require(!works.isEmpty)

        let results = Results(count: works.count)
        let clock = ContinuousClock()
        let started = clock.now
        DispatchQueue.concurrentPerform(iterations: works.count) { index in
            results.store(Self.examine(works[index]), at: index)
        }
        let elapsed = clock.now - started
        let all = results.all

        let decodeFailures = all.filter { $0.decodeError != nil }
        #expect(decodeFailures.isEmpty, "\(decodeFailures.prefix(5).map { "\($0.path): \($0.decodeError ?? "")" })")
        let parsed = all.filter { $0.decodeError == nil }

        // No markup left in what the reader sees. ［＃, 《》 and ／＼ are judged by
        // where the characters come from: the corpus quotes the notation with
        // gaiji (［ ］ are 1-1-46/47, 《 》 1-1-52/53), and a few files carry
        // stray brackets as typos (道傍》, 堀ほ》り). Those are text, shown as
        // written; markup is a ruby, annotation, gaiji or くの字点 token.
        for (name, count) in [
            ("annotation", parsed.reduce(0) { $0 + $1.leakedAnnotation }),
            ("ruby", parsed.reduce(0) { $0 + $1.leakedRuby }),
            ("くの字点", parsed.reduce(0) { $0 + $1.leakedKunojiten }),
            ("〔…〕 with an accent", parsed.reduce(0) { $0 + $1.leftoverAccents }),
        ] {
            let examples = parsed.compactMap { $0.examples[name] }.prefix(5)
            #expect(count == 0, "\(name): \(count) units copied into the displayed text, e.g. \(Array(examples))")
        }

        // Every gaiji with a code resolves; only description-only ones remain.
        let unmapped = parsed.reduce(0) { $0 + $1.unmappedGaiji }
        #expect(unmapped == 0)
        #expect(parsed.reduce(0) { $0 + $1.unresolvedInTree } == parsed.reduce(0) { $0 + $1.descriptionOnlyInTree })

        // Totals against the census, within 1%.
        let census = try Self.census()
        let gaiji = try #require(census["gaiji"] as? [String: Any])
        func censusCount(_ key: String) throws -> Int {
            try #require((gaiji[key] as? [String: Any])?["count"] as? Int)
        }
        let jis = parsed.reduce(0) { $0 + $1.gaijiJIS }
        let unicode = parsed.reduce(0) { $0 + $1.gaijiUnicode }
        let described = parsed.reduce(0) { $0 + $1.gaijiDescriptionOnly }
        #expect(Self.within1Percent(jis, try censusCount("jis_mapped")), "JIS gaiji \(jis)")
        #expect(Self.within1Percent(unicode, try censusCount("unicode")), "U+ gaiji \(unicode)")
        #expect(Self.within1Percent(described, try censusCount("description_only")), "description-only gaiji \(described)")
        #expect(Self.within1Percent(jis + unicode + described, try censusCount("total")), "all gaiji")

        let annotations = try #require(census["annotations"] as? [String: Any])
        let censusHeadingWorks = try #require((annotations["heading"] as? [String: Any])?["works"] as? Int)
        let toc = try #require(census["toc"] as? [String: Any])
        let censusTwoHeadings = try #require((toc["has_two_or_more_headings"] as? [String: Any])?["works"] as? Int)
        let headingWorks = parsed.filter { $0.headings > 0 }.count
        let twoHeadingWorks = parsed.filter { $0.headings >= 2 }.count
        #expect(Self.within1Percent(headingWorks, censusHeadingWorks), "works with a heading: \(headingWorks)")
        #expect(Self.within1Percent(twoHeadingWorks, censusTwoHeadings), "works with two or more headings: \(twoHeadingWorks)")

        // What the parser could not read, for the record.
        var unknown: [String: Int] = [:]
        for result in parsed {
            for (shape, count) in result.unknownShapes { unknown[shape, default: 0] += count }
        }
        // The largest work once more, on its own, for a time no other parse shares.
        let largest = try #require(parsed.max { $0.bytes < $1.bytes })
        let largestText = try TXTFileReader.readTextFile(url: URL(fileURLWithPath: largest.fullPath))
        let alone = ContinuousClock().measure { _ = AozoraDocumentParser.parse(largestText) }
        print("""
            ⟐ Aozora corpus: \(parsed.count) works in \(elapsed); \
            largest \(largest.path) (\(largest.bytes) bytes) parsed in \(alone) on its own, \
            \(largest.parseMilliseconds) ms among the concurrent parses
            ⟐ gaiji: JIS \(jis), U+ \(unicode), description only \(described); \
            headings: \(headingWorks) works, two or more \(twoHeadingWorks)
            ⟐ ［＃, 《》 and ／＼ shown as text (gaiji or the source's own brackets): \
            \(parsed.reduce(0) { $0 + $1.literalBrackets })
            ⟐ missing forward references \(parsed.reduce(0) { $0 + $1.missingForwardReferences }), \
            unclosed ranges \(parsed.reduce(0) { $0 + $1.unclosedRanges }), \
            unopened range ends \(parsed.reduce(0) { $0 + $1.unopenedRangeEnds }), \
            unknown annotations \(unknown.values.reduce(0, +)) in \(parsed.filter { !$0.unknownShapes.isEmpty }.count) works
            ⟐ top unknown: \(unknown.sorted { $0.value > $1.value }.prefix(25).map { "\($0.key)×\($0.value)" })
            """)
    }

    // MARK: One work

    private struct Result: Sendable {
        var path = ""
        var fullPath = ""
        var bytes = 0
        var decodeError: String?
        var parseMilliseconds = 0.0
        var leakedAnnotation = 0
        var leakedRuby = 0
        var leakedKunojiten = 0
        var leftoverAccents = 0
        /// ［＃, 《 or 》 and ／＼ anywhere in the displayed text, whatever their source.
        var literalBrackets = 0
        var examples: [String: String] = [:]
        var gaijiJIS = 0
        var gaijiUnicode = 0
        var gaijiDescriptionOnly = 0
        var unmappedGaiji = 0
        var unresolvedInTree = 0
        var descriptionOnlyInTree = 0
        var headings = 0
        var missingForwardReferences = 0
        var unclosedRanges = 0
        var unopenedRangeEnds = 0
        var unknownShapes: [String: Int] = [:]
    }

    private static func examine(_ url: URL) -> Result {
        var result = Result()
        result.path = url.pathComponents.suffix(3).joined(separator: "/")
        result.fullPath = url.path
        let text: String
        do {
            result.bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            text = try TXTFileReader.readTextFile(url: url)
        } catch {
            result.decodeError = error.localizedDescription
            return result
        }
        let clock = ContinuousClock()
        let start = clock.now
        let document = AozoraDocumentParser.parse(text)
        let duration = clock.now - start
        result.parseMilliseconds = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000

        let shown = document.displayedText
        func note(_ name: String, _ count: Int, _ example: @autoclosure () -> String) -> Int {
            if count > 0, result.examples[name] == nil { result.examples[name] = result.path + ": " + example() }
            return count
        }
        result.leftoverAccents = note("〔…〕 with an accent", accentBrackets(in: shown), snippet(shown, around: "〔"))
        result.literalBrackets = ["［＃", "《", "》", "／＼", "／″＼"].reduce(0) {
            $0 + shown.components(separatedBy: $1).count - 1
        }

        // Displayed units copied verbatim from markup in the source.
        let source = AozoraSource(text)
        var markup: [(range: Range<Int>, name: String)] = []
        let structure = document.structure
        for section in [structure.header, structure.body, structure.colophon] {
            for token in AozoraTokenizer.tokenize(source.units, in: source.range(ofLines: section)) {
                switch token.kind {
                case .ruby: markup.append((token.range, "ruby"))
                case .annotation, .gaiji: markup.append((token.range, "annotation"))
                case .kunojiten: markup.append((token.range, "くの字点"))
                case .text, .rubyBar, .accent, .newline: break
                }
            }
        }
        let displayed = Array(shown.utf16)
        var next = 0
        for run in document.sourceMap.runs where run.isIdentity {
            let copied = run.sourceStart..<(run.sourceStart + run.sourceLength)
            while next < markup.count, markup[next].range.upperBound <= copied.lowerBound { next += 1 }
            var probe = next
            while probe < markup.count, markup[probe].range.lowerBound < copied.upperBound {
                let overlap = markup[probe].range.clamped(to: copied)
                if !overlap.isEmpty {
                    let at = run.displayedStart + (overlap.lowerBound - run.sourceStart)
                    let around = String(decoding: displayed[max(0, at - 20)..<min(displayed.count, at + 30)], as: UTF16.self)
                    let count = note(markup[probe].name, overlap.count, around)
                    switch markup[probe].name {
                    case "ruby": result.leakedRuby += count
                    case "annotation": result.leakedAnnotation += count
                    default: result.leakedKunojiten += count
                    }
                }
                probe += 1
            }
        }

        // Gaiji the way the census counts them: every ※［＃…］ in the body,
        // including those inside ruby readings and other annotations.
        countGaiji(in: source, range: source.range(ofLines: document.structure.body), into: &result)
        for block in document.body {
            walk(block) { inline in
                switch inline {
                case .gaiji(let gaiji) where gaiji.resolved == nil:
                    result.unresolvedInTree += 1
                    if gaiji.code == nil { result.descriptionOnlyInTree += 1 }
                case .heading:
                    result.headings += 1
                default:
                    break
                }
            }
            if case .heading = block { result.headings += 1 }
        }
        for (kind, count) in document.diagnostics.counts {
            switch kind {
            case .unknownAnnotation(let shape): result.unknownShapes[shape, default: 0] += count
            case .missingForwardReference: result.missingForwardReferences += count
            case .unclosedRange: result.unclosedRanges += count
            case .unopenedRangeEnd: result.unopenedRangeEnds += count
            case .unmappedGaijiCode: result.unmappedGaiji += count
            case .unclosedNotationBlock, .unresolvedGaiji: break
            }
        }
        return result
    }

    private static func countGaiji(in source: AozoraSource, range: Range<Int>, into result: inout Result) {
        for token in AozoraTokenizer.tokenize(source.units, in: range) {
            switch token.kind {
            case .gaiji:
                let (gaiji, _) = AozoraDocumentParser.gaiji(source.string(token.content), tables: .shared)
                switch gaiji.code {
                case .jis?: if gaiji.resolved != nil { result.gaijiJIS += 1 }
                case .unicode?: result.gaijiUnicode += 1
                case nil: result.gaijiDescriptionOnly += 1
                }
                countGaiji(in: source, range: token.content, into: &result)
            case .ruby, .annotation, .accent:
                countGaiji(in: source, range: token.content, into: &result)
            case .text, .rubyBar, .kunojiten, .newline:
                break
            }
        }
    }

    /// 〔…〕 in the displayed text still holding a decomposition the table knows.
    private static func accentBrackets(in text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: "〔[^〔〕\n]*〕")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).filter { match in
            guard let bracket = Range(match.range, in: text) else { return false }
            let characters = Array(text[bracket])
            return characters.indices.contains { index in
                [3, 2].contains { length in
                    index + length <= characters.count
                        && AozoraTables.shared.accent(String(characters[index..<(index + length)])) != nil
                }
            }
        }.count
    }

    private static func snippet(_ text: String, around marker: String) -> String {
        guard let range = text.range(of: marker) else { return "" }
        let lower = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper]).replacingOccurrences(of: "\n", with: "⏎")
    }

    private static func walk(_ block: AozoraBlock, _ visit: (AozoraInline) -> Void) {
        switch block {
        case .paragraph(let inlines, _), .heading(_, _, let inlines, _): inlines.forEach { walk($0, visit) }
        case .image(_, _, _, let caption): caption.forEach { walk($0, visit) }
        case .pageBreak: break
        }
    }

    private static func walk(_ inline: AozoraInline, _ visit: (AozoraInline) -> Void) {
        visit(inline)
        switch inline {
        case .ruby(let children, _, _), .emphasis(_, _, let children), .sideline(_, _, let children),
             .bold(let children), .italic(let children), .size(_, let children), .tateChuYoko(let children),
             .script(_, let children), .warichu(let children), .heading(_, _, let children),
             .boxed(let children), .horizontal(let children), .caption(let children),
             .image(_, _, _, let children):
            children.forEach { walk($0, visit) }
        case .text, .gaiji, .kaeriten, .kuntenOkurigana, .lineBreak, .editorialNote, .unknownAnnotation:
            break
        }
    }

    // MARK: Corpus

    /// One file per work, as scripts/aozora_annotation_census.py picks them:
    /// the ruby edition over the plain one, then the larger file.
    private static func pickWorks(in cards: URL) throws -> [URL] {
        let pattern = try NSRegularExpression(pattern: #"^(\d+)_(ruby|txt)(?:_(\d+))?$"#)
        var chosen: [String: (rank: (Int, Int), url: URL)] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: cards, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "txt" {
            let directory = url.deletingLastPathComponent().lastPathComponent
            let match = pattern.firstMatch(in: directory, range: NSRange(directory.startIndex..., in: directory))
            let key = match.flatMap { Range($0.range(at: 1), in: directory) }.map { String(directory[$0]) } ?? url.path
            let isRuby = match.flatMap { Range($0.range(at: 2), in: directory) }.map { directory[$0] == "ruby" } ?? false
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let rank = (isRuby ? 1 : 0, size)
            if let existing = chosen[key], existing.rank >= rank { continue }
            chosen[key] = (rank, url)
        }
        return chosen.values.map(\.url).sorted { $0.path < $1.path }
    }

    private static func census() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../docs/aozora/annotation-census-2026-10-05.json").standardized
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func within1Percent(_ value: Int, _ expected: Int) -> Bool {
        abs(value - expected) * 100 <= expected
    }

    /// Results written from concurrent iterations, one slot each.
    private final class Results: @unchecked Sendable {
        private var storage: [Result]
        private let lock = NSLock()

        init(count: Int) { storage = Array(repeating: Result(), count: count) }

        func store(_ result: Result, at index: Int) {
            lock.withLock { storage[index] = result }
        }

        var all: [Result] { lock.withLock { storage } }
    }
}
