import Foundation

/// The rules a new install starts with (FB-139). First the headings the parser hard-coded
/// before rules were editable, one rule per heading shape, in the order it tried them; then
/// legado's own defaults (`assets/defaultData/txtTocRule.json`), verbatim and enabled as
/// legado ships them (maintainer, 2026-11-05). The order is the tie-break when two rules
/// find equally many chapters, so a tie keeps the split the app always made.
enum TXTTocRuleDefaults {
    private static let numerals = "[零一二三四五六七八九十百千萬万\\d]+"
    /// 第X卷／篇／部 and 卷X before a 第X章／節／回: kept only when a chapter heading follows.
    private static let volume = "^\\s*(?:第\(numerals)[卷篇部]|卷\(numerals))[^\\n]*"

    private struct BuiltIn {
        let id: Int64
        let nameKey: String
        var enabledByDefault = true
        let chapterRule: String
        let volumeRule: String
        let example: String
        /// First characters of every heading, for the parser's byte prefilter; nil when a
        /// heading can start with anything.
        var titleStarts: [String]? = nil
    }

    // The app's own rules sit below legado's ids (its defaults run -1 … -100); legado's keep
    // their ids, so importing legado's JSON updates them in place instead of duplicating.
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

        // legado's defaults, minus three it ships that cannot work here: 双标题(前向／后向)
        // (-20, -21) match across two lines and this parser reads one line at a time, and
        // 默认分章规则 (-100) has no pattern (legado's marker for its size-split fallback).
        BuiltIn(id: -1, nameKey: "分章規則：目錄（去空白）", enabledByDefault: true,
                chapterRule: #"(?<=[　\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$"#,
                volumeRule: #"第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:卷|集(?![合和]))"#, example: #"第一章 假装第一章前面有空白但我不要"#),
        BuiltIn(id: -2, nameKey: "分章規則：目錄", enabledByDefault: true,
                chapterRule: #"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))).{0,30}$"#,
                volumeRule: #"第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:卷|集(?![合和]))"#, example: #"第一章 标准的粤语就是这样"#),
        BuiltIn(id: -3, nameKey: "分章規則：目錄（含簡介）", enabledByDefault: false,
                chapterRule: #"(?<=[　\s])(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|回(?![合来事去])|场(?![和合比电是])|篇(?!张))).{0,30}$"#,
                volumeRule: #"第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:卷|集(?![合和]))"#, example: #"简介 老夫诸葛村夫"#),
        BuiltIn(id: -4, nameKey: "分章規則：目錄（古典、輕小說備用）", enabledByDefault: false,
                chapterRule: #"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|回(?![合来事去])|场(?![和合比电是])|话|篇(?!张))).{0,30}$"#,
                volumeRule: #"第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:卷|集(?![合和]))"#, example: #"第一章 比上面只多了回和话"#),
        BuiltIn(id: -5, nameKey: "分章規則：數字（純數字標題）", enabledByDefault: false,
                chapterRule: #"(?<=[　\s])\d+\.?[ 　\t]{0,4}$"#,
                volumeRule: #""#, example: #"12"#),
        BuiltIn(id: -6, nameKey: "分章規則：大寫數字（純數字標題）", enabledByDefault: false,
                chapterRule: #"(?<=[　\s])[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,12}[ 　\t]{0,4}$"#,
                volumeRule: #""#, example: #"一百七十"#),
        BuiltIn(id: -7, nameKey: "分章規則：混合數字（純數字標題）", enabledByDefault: false,
                chapterRule: #"(?<=[　\s])[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟\d]{1,12}[ 　\t]{0,4}$"#,
                volumeRule: #""#, example: #"12\#n一百七十"#),
        BuiltIn(id: -8, nameKey: "分章規則：數字 可選分隔符 標題", enabledByDefault: true,
                chapterRule: #"^[ 　\t]{0,4}\d{1,5}[:：,.， 、_—\-]?.{1,30}$"#,
                volumeRule: #""#, example: #"1、这个就是标题\#n02美好的明天"#),
        BuiltIn(id: -9, nameKey: "分章規則：大寫數字 分隔符 標題", enabledByDefault: true,
                chapterRule: #"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?)[ 、_—\-].{1,30}$"#,
                volumeRule: #""#, example: #"一、只有前面的数字有差别\#n二十四章 我瞎编的标题"#),
        BuiltIn(id: -10, nameKey: "分章規則：混合數字 分隔符 標題", enabledByDefault: false,
                chapterRule: #"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?[ 、_—\-]|\d{1,5}章?[:：,.， 、_—\-]).{0,30}$"#,
                volumeRule: #""#, example: #"1、人参公鸡\#n二百二十章 boy next door"#),
        BuiltIn(id: -11, nameKey: "分章規則：正文 標題／序號", enabledByDefault: true,
                chapterRule: #"^[ 　\t]{0,4}正文[ 　]{1,4}.{0,20}$"#,
                volumeRule: #""#, example: #"正文 我奶常山赵子龙"#),
        BuiltIn(id: -12, nameKey: "分章規則：Chapter/Section/Part/Episode 序號 標題", enabledByDefault: true,
                chapterRule: #"^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO][.、]|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)\s{0,4}\d{1,4}.{0,30}$"#,
                volumeRule: #""#, example: #"Chapter 1 MyGrandmaIsNB"#),
        BuiltIn(id: -13, nameKey: "分章規則：Chapter（不含簡介）", enabledByDefault: false,
                chapterRule: #"^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][Oo]\.|[Ee]pisode)\s{0,4}\d{1,4}.{0,30}$"#,
                volumeRule: #""#, example: #"Chapter 1 MyGrandmaIsNB"#),
        BuiltIn(id: -14, nameKey: "分章規則：特殊符號 序號 標題", enabledByDefault: true,
                chapterRule: #"(?<=[\s　])[【〔〖「『〈［\[](?:第|[Cc]hapter)[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[章节].{0,20}$"#,
                volumeRule: #""#, example: #"【第一章 后面的符号可以没有"#),
        BuiltIn(id: -15, nameKey: "分章規則：特殊符號 標題（成對）", enabledByDefault: false,
                chapterRule: #"(?<=[\s　]{0,4})(?:[\[〈「『〖〔《（【\(].{1,30}[\)】）》〕〗』」〉\]]?|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$"#,
                volumeRule: #""#, example: #"『加个直角引号更专业』\#n(11)我奶常山赵子聋"#),
        BuiltIn(id: -16, nameKey: "分章規則：特殊符號 標題（單個）", enabledByDefault: true,
                chapterRule: #"(?<=[\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$"#,
                volumeRule: #""#, example: #"☆、晋江作者最喜欢的格式"#),
        BuiltIn(id: -17, nameKey: "分章規則：章／卷 序號 標題", enabledByDefault: true,
                chapterRule: #"^[ \t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$"#,
                volumeRule: #""#, example: #"卷五 开源盛世"#),
        BuiltIn(id: -18, nameKey: "分章規則：頂格標題", enabledByDefault: false,
                chapterRule: #"^\S.{1,20}$"#,
                volumeRule: #""#, example: #"20字以内顶格写的都是标题"#),
        BuiltIn(id: -19, nameKey: "分章規則：中文頂格標題", enabledByDefault: false,
                chapterRule: #"^[一-龟]{1,20}$"#,
                volumeRule: #""#, example: #"20字以内顶格写的中文视为标题"#),
        BuiltIn(id: -22, nameKey: "分章規則：書名 括號 序號", enabledByDefault: true,
                chapterRule: #"^[一-龥]{1,20}[ 　\t]{0,4}[(（][\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\t]{0,4}$"#,
                volumeRule: #""#, example: #"标题后面数字有括号(12)"#),
        BuiltIn(id: -23, nameKey: "分章規則：書名 序號", enabledByDefault: true,
                chapterRule: #"^[一-龥]{1,20}[ 　\t]{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 　\t]{0,4}$"#,
                volumeRule: #""#, example: #"标题后面数字没有括号124"#),
        BuiltIn(id: -24, nameKey: "分章規則：特定字元 標題 特定符號", enabledByDefault: false,
                chapterRule: #"(?<=\={3,6}).{1,40}?(?=\=)"#,
                volumeRule: #""#, example: #"===起这种标题干什么==="#),
        BuiltIn(id: -25, nameKey: "分章規則：字數分割 分節閱讀", enabledByDefault: true,
                chapterRule: #"(?<=[ 　\t]{0,4})(?:.{0,15}分[页节章段]阅读[-_ ]|第\s{0,4}[\d零一二两三四五六七八九十百千万]{1,6}\s{0,4}[页节]).{0,30}$"#,
                volumeRule: #""#, example: #"分节|分页|分段阅读\#n第一页"#),
        BuiltIn(id: -26, nameKey: "分章規則：通用規則", enabledByDefault: false,
                chapterRule: #"(?im)^.{0,6}(?:[引楔]子|正文(?!完|结)|[引序前]言|[序终]章|扉页|[上中下][部篇卷]|卷首语|后记|尾声|番外|={2,4}|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|页[、 　]|集(?![合和])|部(?![分是门落])|篇(?!张))).{0,40}$|^.{0,6}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟a-z]{1,8}[、. 　].{0,20}$"#,
                volumeRule: #""#, example: #"激进规则,适配更多非常用格式"#),
    ]

    static var rules: [TXTTocRule] {
        builtIns.enumerated().map { order, rule in
            TXTTocRule(id: rule.id, name: rule.nameKey, chapterRule: rule.chapterRule,
                       volumeRule: rule.volumeRule, example: rule.example, serialNumber: order,
                       enable: rule.enabledByDefault)
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
