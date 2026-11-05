import Foundation

/// The rules a new install starts with: the headings the parser hard-coded before rules
/// were editable (FB-139), one rule per heading shape, in the order it tried them. Their
/// order is the tie-break when two rules find equally many chapters.
enum TXTTocRuleDefaults {
    private static let numerals = "[零一二三四五六七八九十百千萬万\\d]+"
    /// 第X卷／篇／部 and 卷X before a 第X章／節／回: kept only when a chapter heading follows.
    private static let volume = "^\\s*(?:第\(numerals)[卷篇部]|卷\(numerals))[^\\n]*"

    private struct BuiltIn {
        let id: Int64
        let nameKey: String
        let chapterRule: String
        let volumeRule: String
        let example: String
        let titleStarts: [String]
    }

    // Ids below legado's own (its defaults run -1 … -100), so importing legado's set beside
    // these never replaces one of them.
    private static let builtIns: [BuiltIn] = [
        BuiltIn(id: -1001, nameKey: "分章規則：第X章", chapterRule: "^\\s*第\(numerals)章[^\\n]*",
                volumeRule: volume, example: "第一卷 起程\n第1章 開始\n正文。\n第2章 繼續\n正文。",
                titleStarts: ["第", "卷"]),
        BuiltIn(id: -1002, nameKey: "分章規則：第X節", chapterRule: "^\\s*第\(numerals)[節节][^\\n]*",
                volumeRule: volume, example: "第1節 開始\n正文。\n第2節 繼續\n正文。", titleStarts: ["第", "卷"]),
        BuiltIn(id: -1003, nameKey: "分章規則：第X卷", chapterRule: "^\\s*第\(numerals)卷[^\\n]*",
                volumeRule: "", example: "第一卷 起程\n正文。\n第二卷 歸來\n正文。", titleStarts: ["第"]),
        BuiltIn(id: -1004, nameKey: "分章規則：第X回", chapterRule: "^\\s*第\(numerals)回[^\\n]*",
                volumeRule: volume, example: "第一回 宴桃園豪傑三結義\n正文。\n第二回 張翼德怒鞭督郵\n正文。",
                titleStarts: ["第", "卷"]),
        BuiltIn(id: -1005, nameKey: "分章規則：第X篇", chapterRule: "^\\s*第\(numerals)篇[^\\n]*",
                volumeRule: "", example: "第一篇 人仙篇\n正文。\n第二篇 地仙篇\n正文。", titleStarts: ["第"]),
        BuiltIn(id: -1006, nameKey: "分章規則：第X部", chapterRule: "^\\s*第\(numerals)部[^\\n]*",
                volumeRule: "", example: "第一部 少年\n正文。\n第二部 青年\n正文。", titleStarts: ["第"]),
        BuiltIn(id: -1007, nameKey: "分章規則：卷X", chapterRule: "^\\s*卷\(numerals)[^\\n]*",
                volumeRule: "", example: "卷一 開端\n正文。\n卷二 轉折\n正文。", titleStarts: ["卷"]),
        BuiltIn(id: -1008, nameKey: "分章規則：Chapter N", chapterRule: "^\\s*(?:Chapter|CHAPTER)\\s*\\d+[^\\n]*",
                volumeRule: "", example: "Chapter 1 The Beginning\nText.\nChapter 2 The Road\nText.",
                titleStarts: ["C"]),
        BuiltIn(id: -1009, nameKey: "分章規則：Part N", chapterRule: "^\\s*(?:Part|PART)\\s*\\d+[^\\n]*",
                volumeRule: "", example: "Part 1\nText.\nPart 2\nText.", titleStarts: ["P"]),
    ]

    static var rules: [TXTTocRule] {
        builtIns.enumerated().map { order, rule in
            TXTTocRule(id: rule.id, name: rule.nameKey, chapterRule: rule.chapterRule,
                       volumeRule: rule.volumeRule, example: rule.example, serialNumber: order, enable: true)
        }
    }

    /// The name to show: a built-in rule's own name in the app's language, until renamed.
    static func displayName(of rule: TXTTocRule) -> String {
        guard let builtIn = builtIns.first(where: { $0.id == rule.id }), rule.name == builtIn.nameKey else {
            return rule.name
        }
        return localized(builtIn.nameKey)
    }

    /// The name to store for what the editor shows: a built-in rule's own localized name
    /// goes back to its key, so it keeps following the app's language.
    static func storedName(_ displayed: String, for id: Int64) -> String {
        guard let builtIn = builtIns.first(where: { $0.id == id }), displayed == localized(builtIn.nameKey) else {
            return displayed
        }
        return builtIn.nameKey
    }

    static func isBuiltIn(_ id: Int64) -> Bool { builtIns.contains { $0.id == id } }

    /// The first characters an unedited built-in rule's headings can have, for the parser's
    /// byte prefilter. nil once the rule's patterns are edited, or for any other rule.
    static func titleStarts(for rule: TXTTocRule) -> [String]? {
        guard let builtIn = builtIns.first(where: { $0.id == rule.id }),
              builtIn.chapterRule == rule.chapterRule, builtIn.volumeRule == rule.volumeRule else { return nil }
        return builtIn.titleStarts
    }
}
