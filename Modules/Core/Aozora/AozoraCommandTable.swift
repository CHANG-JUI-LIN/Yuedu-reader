import Foundation

/// The annotation vocabulary. Starts from aozora2html `yml/command_table.yml`
/// (CC0) and adds the categories the 2023-03 census counts
/// (`CATEGORIES` in scripts/aozora_annotation_census.py).
enum AozoraCommandTable {
    /// A style that wraps text, named by a forward reference
    /// (［＃「…」に傍点］) or by a range (［＃傍点］…［＃傍点終わり］).
    enum Style: Equatable {
        case emphasis(AozoraEmphasisStyle, AozoraSide)
        case sideline(AozoraSidelineStyle, AozoraSide)
        case bold
        case italic
        case size(Int)
        case tateChuYoko
        case script(AozoraScriptKind)
        case warichu
        case heading(AozoraHeadingLevel, AozoraHeadingKind)
        case boxed
        case horizontal
        case caption
    }

    /// command_table.yml, plus ×傍点 (150 uses in the corpus) for ばつ傍点.
    static let decorations: [String: Style] = {
        var table: [String: Style] = [:]
        for shape in AozoraEmphasisStyle.allCases { table[shape.rawValue] = .emphasis(shape, .right) }
        for shape in AozoraSidelineStyle.allCases { table[shape.rawValue] = .sideline(shape, .right) }
        for kind in AozoraScriptKind.allCases { table[kind.rawValue] = .script(kind) }
        table["×傍点"] = .emphasis(.saltire, .right)
        table["太字"] = .bold
        table["斜体"] = .italic
        return table
    }()

    /// A named style: 傍点, 左に傍点, 二重傍線, 太字, 中見出し, 同行小見出し,
    /// ２段階小さな文字, 縦中横 …
    static func style(_ name: String) -> Style? {
        if let heading = heading(name) { return .heading(heading.level, heading.kind) }
        if let steps = sizeSteps(name) { return .size(steps) }
        switch name {
        case "縦中横": return .tateChuYoko
        case "横組み": return .horizontal
        case "罫囲み": return .boxed
        case "キャプション": return .caption
        case "割り注", "割書": return .warichu
        default: break
        }
        // 右に／左に／上に／下に: aozora2html moves 傍点 to the left side for 左
        // and 下, and 傍線 for 左 and 上.
        var direction: Character?
        var base = Substring(name)
        if let first = name.first, "右左上下".contains(first), name.dropFirst().hasPrefix("に") {
            direction = first
            base = name.dropFirst(2)
        }
        switch decorations[String(base)] {
        case .emphasis(let shape, _)?:
            return .emphasis(shape, direction == "左" || direction == "下" ? .left : .right)
        case .sideline(let shape, _)?:
            return .sideline(shape, direction == "左" || direction == "上" ? .left : .right)
        case let style?:
            return direction == nil ? style : nil
        case nil:
            return nil
        }
    }

    /// 大／中／小見出し, optionally 同行 or 窓.
    static func heading(_ name: String) -> (level: AozoraHeadingLevel, kind: AozoraHeadingKind)? {
        var rest = Substring(name)
        var kind = AozoraHeadingKind.normal
        if rest.hasPrefix("同行") {
            kind = .sameLine
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix("窓") {
            kind = .window
            rest = rest.dropFirst()
        }
        guard rest.count == 4, rest.hasSuffix("見出し"), let level = headingLevel(rest.first) else { return nil }
        return (level, kind)
    }

    /// The level named anywhere in a command (ここから中見出し, 「…」は大見出し).
    static func headingLevel(in command: String) -> AozoraHeadingLevel? {
        for (mark, level) in [("大見出し", AozoraHeadingLevel.large), ("中見出し", .medium), ("小見出し", .small)]
        where command.contains(mark) {
            return level
        }
        return nil
    }

    static func headingKind(in command: String) -> AozoraHeadingKind {
        if command.contains("同行") { return .sameLine }
        if command.contains("窓") { return .window }
        return .normal
    }

    private static func headingLevel(_ mark: Character?) -> AozoraHeadingLevel? {
        switch mark {
        case "大": return .large
        case "中": return .medium
        case "小": return .small
        default: return nil
        }
    }

    private static let sizePattern = try! NSRegularExpression(pattern: "(.*)段階(大き|小さ)な文字")

    /// N段階大きな文字 → +N, N段階小さな文字 → −N (aozora2html PAT_CHARSIZE).
    static func sizeSteps(_ command: String) -> Int? {
        let text = japaneseNumber(command)
        guard let match = sizePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let countRange = Range(match.range(at: 1), in: text),
              let directionRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let count = Int(text[countRange].filter(\.isNumber)) ?? 1
        return text[directionRange] == "大き" ? count : -count
    }

    static func pageBreak(_ command: String) -> AozoraPageBreakKind? {
        switch command {
        case "改ページ", "改頁": return .page
        case "改丁": return .leaf
        case "改段": return .column
        case "改見開き": return .spread
        default: return nil
        }
    }

    /// 返り点 (aozora2html PAT_KAERITEN).
    static func isKaeriten(_ command: String) -> Bool {
        !command.isEmpty && command.allSatisfy { "一二三四五六七八九十レ上中下甲乙丙丁天地人".contains($0) }
    }

    /// 訓点送り仮名, written （ヲ）.
    static func isOkurigana(_ command: String) -> Bool {
        command.count > 2 && command.hasPrefix("（") && command.hasSuffix("）")
    }

    /// Proofreading notes and structure markers: the census `editorial` and
    /// `structure` rules. A reader never sees them.
    static func isEditorial(_ command: String) -> Bool {
        if command.hasPrefix("本文") || command.hasPrefix("ここから本文") { return true }
        let markers = ["底本", "ママ", "入力者", "校訂", "編集", "原文", "誤植", "脱字", "衍字", "誤訳", "誤記",
                       "余分", "本当は", "ルビの「", "の誤り", "か？", "では「", "ルビは「"]
        return markers.contains { command.contains($0) }
    }

    private static let digitValues: [Character: Character] = {
        var values: [Character: Character] = [:]
        for (value, character) in "０１２３４５６７８９".enumerated() { values[character] = Character(String(value)) }
        for (value, character) in "〇一二三四五六七八九".enumerated() { values[character] = Character(String(value)) }
        return values
    }()

    /// aozora2html `Utils.convert_japanese_number`: full-width and kanji
    /// digits to ASCII, with 十 as a place value (二十三 → 23, 十五 → 15, 三十 → 30).
    static func japaneseNumber(_ text: String) -> String {
        let characters = text.map { digitValues[$0] ?? $0 }
        func isDigit(_ index: Int) -> Bool {
            characters.indices.contains(index) && ("0"..."9").contains(characters[index])
        }
        var result = ""
        for (index, character) in characters.enumerated() {
            guard character == "十" else {
                result.append(character)
                continue
            }
            switch (isDigit(index - 1), isDigit(index + 1)) {
            case (true, true): break
            case (true, false): result.append("0")
            case (false, true): result.append("1")
            case (false, false): result.append("10")
            }
        }
        return result
    }

    /// The number before `suffix` (字下げ, 字上げ, 字詰め), after
    /// `japaneseNumber`; nil when the suffix is missing, 1 when no digits
    /// precede it.
    static func count(before suffix: String, in command: String) -> Int? {
        let text = japaneseNumber(command)
        guard let suffixRange = text.range(of: suffix) else { return nil }
        let digits = text[..<suffixRange.lowerBound].reversed().prefix(while: \.isNumber)
        return Int(String(digits.reversed())) ?? 1
    }
}
