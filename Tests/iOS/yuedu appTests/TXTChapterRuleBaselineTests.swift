import Foundation
import Testing
@testable import yuedu_app

/// Chapters the parser produced before chapter rules became editable (FB-139), frozen as a
/// baseline. The app's own built-in rules re-express the patterns it hard-coded, so on their
/// own they must split every book the same.
@Suite(.serialized)
struct TXTChapterRuleBaselineTests {
    struct Entry: Codable, Equatable {
        let title: String
        let lower: Int
        let upper: Int
    }

    static let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static let baselineURL = fixtureDirectory.appendingPathComponent("txt-chapter-rule-baseline.json")

    /// Real files plus synthetic books covering each built-in heading shape.
    static func corpus() throws -> [(name: String, file: TXTMappedTextFile)] {
        var result: [(String, TXTMappedTextFile)] = []
        let sample = fixtureDirectory.appendingPathComponent("txt-chapter-sample.txt")
        result.append(("txt-chapter-sample", try TXTFileReader.readMappedTextFile(url: sample)))
        for name in ["aozora-cp932", "aozora-euc-jp", "simplified-gbk", "simplified-gb18030",
                     "traditional-big5", "korean-euc-kr", "aozora-neko-jijo"] {
            let url = fixtureDirectory.appendingPathComponent("TXTEncodings/\(name).txt")
            result.append((name, try TXTFileReader.readMappedTextFile(url: url)))
        }
        let body = String(repeating: "　這是一段普通的正文內容，用來把標題隔開超過一千個字元。\n", count: 40)
        let synthetic: [(String, String)] = [
            ("chapters", (1...6).map { "第\($0)章 標題\($0)\n" + body }.joined()),
            ("han-chapters", ["一", "二", "三", "四"].map { "第\($0)章 漢字\n" + body }.joined()),
            ("volumes", "第一卷 起\n第1章 甲\n" + body + "第2章 乙\n" + body + "第二卷 承\n第3章 丙\n" + body),
            ("sections", (1...4).map { "第\($0)節 小節\n" + body }.joined()),
            ("hui", (1...4).map { "第\($0)回 章回\n" + body }.joined()),
            ("parts", (1...3).map { "第\($0)篇 篇章\n" + body }.joined()),
            ("bu", (1...3).map { "第\($0)部 部分\n" + body }.joined()),
            ("juan-x", (1...3).map { "卷\($0) 卷名\n" + body }.joined()),
            ("english", (1...4).map { "Chapter \($0) Title\n" + body }.joined()),
            ("english-upper", (1...3).map { "CHAPTER \($0)\n" + body }.joined()),
            ("english-part", (1...3).map { "Part \($0)\n" + body }.joined()),
            ("special", "序章 開端\n" + body + "第1章 正文\n" + body + "第2章 續\n" + body + "番外 後日\n" + body + "後記\n" + body),
            ("embedded-parts", "第1章 開始\n正文介紹一本功法。\n第一篇：人仙篇！\n第二篇：地仙篇。\n" + body + "第2章 繼續\n" + body),
            ("preface", "書名\n作者：某人\n簡介文字。\n" + body + "第1章 開始\n" + body + "第2章 繼續\n" + body),
            ("no-headings", String(repeating: body, count: 20)),
            ("overlong", "第1章 很長\n" + String(repeating: body, count: 80) + "第2章 短\n" + body),
        ]
        for (name, text) in synthetic {
            result.append((name, TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)))
            let utf16 = TXTMappedTextFile(data: try #require(text.data(using: .utf16LittleEndian)), encoding: .utf16LittleEndian)
            result.append((name + "-utf16le", utf16))
        }
        return result
    }

    /// The app's own built-in rules, without legado's defaults (ids -1 … -100).
    static let appRules = TXTTocRuleSet(rules: TXTTocRuleDefaults.rules.filter { $0.id <= -1_001 })

    static func entries(_ file: TXTMappedTextFile, rules: TXTTocRuleSet = appRules) -> [Entry] {
        TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Baseline", rules: rules).map {
            Entry(title: $0.title, lower: $0.byteRange.lowerBound, upper: $0.byteRange.upperBound)
        }
    }

    /// The large GB18030 book `TXTFileReaderTests` budgets, timed five times so a run reports a
    /// median (`TXT_RULE_PERF` lines) for before/after comparisons.
    @Test func largeBookIndexTiming() throws {
        var text = ""
        for chapter in 1...200 {
            text += "第\(chapter)章 測試章節\r\n"
            for _ in 0..<1_000 { text += "　普通正文內容，用來模擬大型小說的段落。\r\n" }
        }
        let file = TXTMappedTextFile(data: try #require(text.data(using: TXTFileReader.gb18030Encoding)),
                                     encoding: TXTFileReader.gb18030Encoding)
        for (label, rules) in [("app", Self.appRules), ("defaults", TXTTocRuleSet(rules: TXTTocRuleDefaults.rules))] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                let indexes = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "大型測試", rules: rules)
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                #expect(indexes.count == 200)
            }
            print("TXT_RULE_PERF \(label) median=\(samples.sorted()[2]) ms samples=\(samples)")
        }
        // A book only a legado rule splits (数字 可选分隔符 标题名称): nothing to prefilter.
        var numbered = ""
        for chapter in 1...200 {
            numbered += "\(chapter)、測試章節\r\n"
            for _ in 0..<1_000 { numbered += "　普通正文內容，用來模擬大型小說的段落。\r\n" }
        }
        let numberedFile = TXTMappedTextFile(data: try #require(numbered.data(using: TXTFileReader.gb18030Encoding)),
                                             encoding: TXTFileReader.gb18030Encoding)
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let indexes = TXTChapterParser.parseMappedChapterIndexes(numberedFile, bookTitle: "大型測試",
                                                                     rules: TXTTocRuleSet(rules: TXTTocRuleDefaults.rules))
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            #expect(indexes.count == 200)
        }
        print("TXT_RULE_PERF legado-rule-wins median=\(samples.sorted()[2]) ms samples=\(samples)")
    }

    @Test func builtInRulesKeepEveryBaselineBook() throws {
        var actual: [String: [Entry]] = [:]
        for (name, file) in try Self.corpus() { actual[name] = Self.entries(file) }
        guard FileManager.default.fileExists(atPath: Self.baselineURL.path) else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(actual).write(to: Self.baselineURL)
            Issue.record("Baseline written to \(Self.baselineURL.path); commit it and rerun")
            return
        }
        let expected = try JSONDecoder().decode([String: [Entry]].self, from: Data(contentsOf: Self.baselineURL))
        #expect(Set(actual.keys) == Set(expected.keys))
        for (name, entries) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(actual[name] == entries, "\(name) chapters changed")
        }
    }
}
