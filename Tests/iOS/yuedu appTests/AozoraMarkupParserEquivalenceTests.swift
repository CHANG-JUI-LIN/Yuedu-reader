import Foundation
import Testing
@testable import yuedu_app

/// Aozora plan, Task 18: the TXT reader reads its markup through the Aozora module's tokenizer
/// now, and its displayed text must not move, since stored positions index it and there is no
/// migration. The reader as it was before (app commit c7104190) is frozen here, and the new one
/// must give the same nodes, text and removed ranges for every input.
@Suite("Aozora TXT markup equivalence", .serialized)
struct AozoraMarkupParserEquivalenceTests {
    @Test("random markup soup reads as it did")
    func fuzz() {
        // A fixed seed, so a failure repeats. The alphabet is every unit the readers look at,
        // with Han of both planes, a variation selector, both kana and line ends of each kind,
        // and what joins a character to its neighbour (combining marks, variation selectors,
        // ZWJ, a spacing mark, a prepended sign): the old reader matched notes as NSString does
        // and ruby by Swift's characters, so a delimiter with one of these beside it is text.
        let alphabet: [String] = ["漢", "字", "𠮷", "々", "葛\u{E0100}", "か", "ナ", "ｶ", "a", " ", "｜", "《", "》",
                                  "［", "＃", "］", "［＃", "］", "\n", "\r", "\r\n", "\u{2028}", "\u{85}",
                                  "※", "〔", "〕", "／", "＼", "″",
                                  "\u{3099}", "\u{FE0F}", "\u{200D}", "\u{E0100}", "\u{0301}", "\u{0600}", "\u{0903}",
                                  "\u{FF9E}", "\u{200C}", "\u{1F3FB}"]
        var random = SplitMix(seed: 0x5EED_2026_1104)
        var checked = 0
        for _ in 0..<200_000 {
            let length = Int(random.next() % 40)
            let source = (0..<length).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }.joined()
            guard let difference = Self.difference(source) else { checked += 1; continue }
            Issue.record("\(difference) in «\(source.debugDescription)»")
            return
        }
        #expect(checked == 200_000)
    }

    @Test("the TXT fixtures read as they did")
    func fixtures() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/TXTEncodings")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        try #require(!files.isEmpty)
        for file in files {
            let text = try TXTFileReader.readTextFile(url: file)
            #expect(Self.difference(text) == nil, "\(file.lastPathComponent)")
        }
    }

    /// Every work in the corpus (AOZORA_CORPUS, as `AozoraCorpusTests`), read whole. The
    /// largest 200, read one at a time, also time both readers.
    @Test("every corpus work reads as it did", .enabled(if: ProcessInfo.processInfo.environment["AOZORA_CORPUS"] != nil))
    func corpus() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AOZORA_CORPUS"]))
        let works = try AozoraCorpusTests.pickWorks(in: root.appendingPathComponent("cards"))
        try #require(!works.isEmpty)
        let differences = AozoraCorpusTests.Slots<String>(count: works.count)
        DispatchQueue.concurrentPerform(iterations: works.count) { index in
            do {
                let text = try TXTFileReader.readTextFile(url: works[index])
                if let difference = Self.difference(text) { differences.store("\(works[index].lastPathComponent): \(difference)", at: index) }
            } catch {
                differences.store("\(works[index].lastPathComponent) does not decode: \(error)", at: index)
            }
        }
        let found = differences.all
        #expect(found.isEmpty, "\(found.count) works differ: \(found.prefix(5))")

        let sizes = works.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let largest = sizes.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
        let texts = try largest.map(TXTFileReader.readTextFile(url:))
        let clock = ContinuousClock()
        let reference = clock.measure { for text in texts { _ = ReferenceTXTMarkupParser.parse(text) } }
        let current = clock.measure { for text in texts { _ = AozoraMarkupParser.parse(text) } }
        print("⟐ TXT markup: \(found.count) of \(works.count) works differ; the largest 200 (\(texts.reduce(0) { $0 + $1.utf16.count }) units) in \(reference) before, \(current) now")
    }

    // MARK: Helpers

    /// Where the two readers part, or nil.
    static func difference(_ source: String) -> String? {
        let old = ReferenceTXTMarkupParser.parse(source)
        let new = AozoraMarkupParser.parse(source)
        if old.plainText != new.plainText { return "text «\(old.plainText)» became «\(new.plainText)»" }
        let (oldNodes, newNodes) = (old.nodes.map(describe), new.nodes.map(describe))
        if oldNodes != newNodes { return "nodes \(oldNodes) became \(newNodes)" }
        if old.noteRanges != new.noteRanges { return "notes \(old.noteRanges) became \(new.noteRanges)" }
        if old.rubyRanges != new.rubyRanges { return "ruby markup \(old.rubyRanges) became \(new.rubyRanges)" }
        return nil
    }

    private static func describe(_ node: RenderableNode) -> String {
        switch node {
        case .text(let text): "text(\(text))"
        case .ruby(let base, let reading, _): "ruby(\(base.map(describe)), \(reading))"
        default: "other"
        }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// `AozoraMarkupParser.parse` as it was at app commit c7104190, before it read its markup
/// through `AozoraTokenizer` (Aozora plan, Task 18). Kept only to hold the new reader to it.
private enum ReferenceTXTMarkupParser {
    struct Parsed {
        let nodes: [RenderableNode]
        let plainText: String
        let noteRanges: [NSRange]
        let rubyRanges: [NSRange]
    }

    static func parse(_ source: String) -> Parsed {
        guard source.contains("《") || source.contains("［＃") else {
            return Parsed(nodes: source.isEmpty ? [] : [.text(source)], plainText: source,
                          noteRanges: [], rubyRanges: [])
        }
        let (cleaned, noteRanges) = stripNotes(source)
        let characters = Array(cleaned)
        var offsets = [0]
        for character in characters { offsets.append(offsets.last! + String(character).utf16.count) }
        var nodes: [RenderableNode] = [], buffer: [Character] = [], deletions: [NSRange] = []
        var plainText = "", index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = String(buffer)
            nodes.append(.text(text)); plainText += text; buffer.removeAll(keepingCapacity: true)
        }
        func closingRuby(after opening: Int) -> Int? {
            var cursor = opening + 1
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "》" { return cursor > opening + 1 ? cursor : nil }
                if character.isNewline || character == "《" { return nil }
                cursor += 1
            }
            return nil
        }
        func appendRuby(base: String, opening: Int, closing: Int) {
            let reading = String(characters[(opening + 1)..<closing])
            nodes.append(.ruby(base: [.text(base)], text: reading))
            plainText += base
            deletions.append(NSRange(location: offsets[opening], length: offsets[closing + 1] - offsets[opening]))
        }

        while index < characters.count {
            let character = characters[index]
            if character == "｜" {
                var opening = index + 1
                while opening < characters.count, characters[opening] != "《",
                      characters[opening] != "｜", !characters[opening].isNewline { opening += 1 }
                if opening > index + 1, opening < characters.count, characters[opening] == "《",
                   let closing = closingRuby(after: opening) {
                    flush()
                    deletions.append(NSRange(location: offsets[index], length: 1))
                    appendRuby(base: String(characters[(index + 1)..<opening]), opening: opening, closing: closing)
                    index = closing + 1
                    continue
                }
            } else if character == "《", let closing = closingRuby(after: index) {
                let reading = String(characters[(index + 1)..<closing])
                // Bare 《》 are also Chinese book-title punctuation. Kana is the
                // positive signal for implicit Japanese ruby; ｜ is unambiguous.
                if reading.unicodeScalars.contains(where: isKana) {
                    let count = buffer.reversed().prefix(while: isHan).count
                    if count > 0 {
                        let base = String(buffer.suffix(count))
                        buffer.removeLast(count); flush()
                        appendRuby(base: base, opening: index, closing: closing)
                        index = closing + 1
                        continue
                    }
                }
            }
            buffer.append(character)
            index += 1
        }
        flush()
        return Parsed(nodes: nodes, plainText: plainText, noteRanges: noteRanges, rubyRanges: deletions)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA,
             0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return true
        default:
            return false
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        let han: Bool
        switch first.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x323AF, 0x3005...0x3007, 0x303B: han = true
        default: han = false
        }
        return han && character.unicodeScalars.dropFirst().allSatisfy {
            (0xFE00...0xFE0F).contains($0.value) || (0xE0100...0xE01EF).contains($0.value)
        }
    }

    private static func stripNotes(_ source: String) -> (String, [NSRange]) {
        let ns = source as NSString
        var cursor = 0, text = "", ranges: [NSRange] = []
        while cursor < ns.length {
            let opening = ns.range(of: "［＃", range: NSRange(location: cursor, length: ns.length - cursor))
            guard opening.location != NSNotFound else { break }
            let contentStart = NSMaxRange(opening)
            let closing = ns.range(of: "］", range: NSRange(location: contentStart, length: ns.length - contentStart))
            guard closing.location != NSNotFound else { break }
            text += ns.substring(with: NSRange(location: cursor, length: opening.location - cursor))
            ranges.append(NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location))
            cursor = NSMaxRange(closing)
        }
        text += ns.substring(from: cursor)
        return (text, ranges)
    }
}
