import Foundation

/// Which chapter of a site's is the chapter being read (本章說; design
/// `Technotes/ChapterCommentsModule-2026-11-15-design.md` §4.1). The reader's copy and the site's
/// are two editions: a volume heading, a 番外 or an author's note moves every chapter after it,
/// so a chapter is never matched by where it stands. It is matched by what it is called, and a
/// chapter that cannot be told apart is not matched: comments under the wrong chapter are worse
/// than none.
enum ChapterTitleMatch {
    /// A chapter title as it is compared: its number, when it writes one, and the rest folded
    /// as a work's title is (`WorkMatchKey`).
    struct Key: Hashable, Sendable {
        var number: Int?
        var name: String
    }

    /// 「第十二章 風起」, 「第12章：風起」, "Chapter 12 風起" and 「012 風起」 are number 12, name 風起.
    static func key(_ title: String) -> Key {
        let text = title.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  let number = number(ns.substring(with: match.range(at: 1))) else { continue }
            let rest = ns.substring(from: match.range.location + match.range.length)
            return Key(number: number, name: WorkMatchKey.title(rest))
        }
        return Key(number: nil, name: WorkMatchKey.title(text))
    }

    // `[0-9]`, never `\d`: that one takes Han numerals too, which the first pattern reads itself.
    // Literal patterns: a typo fails the first test that reads a title.
    private static let patterns: [NSRegularExpression] = [
        #"^第\s*([0-9零〇一二三四五六七八九十百千万萬两兩]+)\s*[章节節回话話集]"#,
        #"^(?:chapter|ch\.?|episode|ep\.?)\s*([0-9]+)"#,
        #"^([0-9]+)(?=[\s.、:：\-—]|$)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    /// Arabic digits, or a Han numeral up to the 萬s (一千二百三十四, 十二, 二〇三).
    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
                                        "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
        // Positional (二〇三): no unit in it.
        if !text.contains(where: { units[$0] != nil || $0 == "万" || $0 == "萬" }) {
            var value = 0
            for character in text {
                guard let digit = digits[character] else { return nil }
                value = value * 10 + digit
            }
            return text.isEmpty ? nil : value
        }
        var total = 0, section = 0, digit: Int?
        for character in text {
            if let value = digits[character] {
                digit = value
            } else if let unit = units[character] {
                // 十二 is 一十二.
                section += (digit ?? 1) * unit
                digit = nil
            } else if character == "万" || character == "萬" {
                total += (section + (digit ?? 0)) * 10_000
                section = 0
                digit = nil
            } else {
                return nil
            }
        }
        return total + section + (digit ?? 0)
    }

    /// The site's chapters, ready to be asked about one title after another.
    struct Index: Sendable {
        private let keys: [Key]
        private let byName: [String: [Int]]
        private let byNumber: [Int: [Int]]

        init(titles: [String]) {
            let keys = titles.map(ChapterTitleMatch.key)
            self.keys = keys
            byName = Dictionary(grouping: keys.indices.filter { !keys[$0].name.isEmpty }, by: { keys[$0].name })
            byNumber = Dictionary(grouping: keys.indices.filter { keys[$0].number != nil }, by: { keys[$0].number! })
        }

        /// The position in the site's list of the chapter `title` is, nil when none is or more
        /// than one could be.
        ///
        /// 1. One chapter of the site's has its name: that one. Several do (every volume's 序章):
        ///    the one with its number too, if that leaves one.
        /// 2. No chapter has its name (the editions title it differently, or it has only a
        ///    number): the one with its number, when the site has one chapter of that number and
        ///    `localNumbers` — the numbers of the reader's own chapters — has it once as well. A
        ///    book whose numbering starts again in each volume has no such chapter.
        ///
        /// `byNameOnly` leaves step 2 out: for telling whether the site's book is the reader's at
        /// all, where a number proves nothing (every book has a chapter three).
        func position(of title: String, localNumbers: [Int: Int], byNameOnly: Bool = false) -> Int? {
            let key = ChapterTitleMatch.key(title)
            if !key.name.isEmpty, let named = byName[key.name] {
                if named.count == 1 { return named[0] }
                let numbered = named.filter { keys[$0].number == key.number }
                return key.number != nil && numbered.count == 1 ? numbered[0] : nil
            }
            guard !byNameOnly, let number = key.number, localNumbers[number] == 1, let numbered = byNumber[number],
                  numbered.count == 1 else {
                return nil
            }
            return numbered[0]
        }
    }

    /// How many chapters of the reader's copy have each number.
    static func numberCounts(_ titles: [String]) -> [Int: Int] {
        titles.reduce(into: [:]) { counts, title in
            if let number = key(title).number { counts[number, default: 0] += 1 }
        }
    }

    /// The fewest chapters that must be found on the site before their share counts: three
    /// chapters called 序, 正文 and 後記 are in every book.
    static let minimumMatches = 5
    /// The share of the reader's chapters found on the site that makes it the same book, for a
    /// book that names no author (maintainer, 2026-11-15: 用章節表驗證、八成).
    static let sameBookShare = 0.8

    /// Whether the site's chapters are this book's: `sameBookShare` of the reader's chapters are
    /// among them by name, and `minimumMatches` at least. What stands in for an author a TXT does
    /// not name. By name only: two books of one title both have chapters one to six.
    static func isSameBook(localTitles: [String], remoteTitles: [String]) -> Bool {
        guard !localTitles.isEmpty else { return false }
        let index = Index(titles: remoteTitles)
        let counts = numberCounts(localTitles)
        let matched = localTitles.filter { index.position(of: $0, localNumbers: counts, byNameOnly: true) != nil }.count
        return matched >= minimumMatches && Double(matched) >= Double(localTitles.count) * sameBookShare
    }
}
