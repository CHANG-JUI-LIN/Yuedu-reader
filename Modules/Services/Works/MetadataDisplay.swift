import Foundation

// 中繼資料語言偏好推薦 on what a source says of an item (maintainer, 2026-10-25): with Chinese
// chosen, titles, authors and blurbs read in its script, and a blurb with nothing in Chinese
// says so in place of the Japanese it has. Bangumi's summaries, the default home's rankings, are
// 简体, 繁體 or Japanese, often a Chinese paragraph beside a Japanese one.
// - For display only: the route, the searches for a source and the match keys keep what the
//   source sent, since a book source searched in the other script finds nothing.
// - Other languages are shown as sent: nothing tells an English blurb from a French one, and
//   leaving it out would leave a reader with none.
// - A shelf copy's own metadata is the reader's, and is not changed.

struct MetadataDisplay: Equatable, Sendable {
    /// The `MetadataLanguage` tag in effect (`ReadingLanguagePreferences.language`).
    let language: String

    /// The app's 中繼資料語言偏好推薦.
    @MainActor static var current: MetadataDisplay {
        MetadataDisplay(language: AggregationSettingsStore.shared.readingLanguages.language)
    }

    /// What a blurb shows: its text, or that there is none in the reader's language.
    enum Blurb: Equatable {
        case text(String)
        case unavailable(String)

        var string: String {
            switch self {
            case .text(let text), .unavailable(let text): text
            }
        }

        var isUnavailable: Bool {
            if case .unavailable = self { true } else { false }
        }
    }

    private var conversion: TextConversion? {
        switch language {
        case "zh-Hant": .toTraditional
        case "zh-Hans": .toSimplified
        default: nil
        }
    }

    /// A title or a name in the reader's script. One with kana is Japanese, and is left as it is:
    /// its kanji are not Chinese characters to convert (体 is 体 in Japanese).
    func text(_ text: String) -> String {
        guard let conversion, !JapaneseSentences.hasKana(text) else { return text }
        return text.converted(to: conversion)
    }

    /// A blurb in the reader's script, its Japanese sentences left out; nil for none. Nothing left
    /// says 沒有繁體中文簡介 (or 簡體).
    func blurb(_ blurb: String?) -> Blurb? {
        guard let blurb, !blurb.isEmpty else { return nil }
        guard let conversion else { return .text(blurb) }
        guard let chinese = JapaneseSentences.removing(from: blurb) else {
            return .unavailable(localized(conversion == .toTraditional ? "沒有繁體中文簡介" : "沒有簡體中文簡介"))
        }
        return .text(chinese.converted(to: conversion))
    }
}

/// A blurb's Japanese, by sentence. A sentence is Japanese when a tenth of its letters are
/// hiragana (Japanese prose runs a third to a half) or half are kana (アルベラン王国将軍, ページ
/// オーバー), while Chinese that quotes a Japanese title (原名フルメタル・パニック, 取り扱います)
/// stays under both. One too short to tell (a title, a credit such as 第29回日本SF大賞受賞, a line
/// in Latin letters, a rule of dashes) goes with the nearest one that can be told, the one before
/// it first. Measured on Bangumi's 120 top-ranked novel and manga summaries (MetadataDisplayTests).
enum JapaneseSentences {
    /// Chinese characters a sentence without enough kana needs to be told Chinese.
    static let tellableHan = 12

    static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    /// `text` without its Japanese sentences, trimmed; nil when nothing is left. `text` itself when
    /// it has no hiragana.
    static func removing(from text: String) -> String? {
        guard text.unicodeScalars.contains(where: isHiragana) else { return text }
        let pieces = sentences(text).map { (text: $0, kind: kind(of: $0)) }
        var kinds = pieces.map(\.kind)
        // In order, so the one before is already told.
        for index in kinds.indices where kinds[index] == nil {
            let before = index > 0 ? kinds[index - 1] : nil
            let after = pieces[(index + 1)...].lazy.compactMap(\.kind).first
            kinds[index] = before ?? after ?? false
        }
        var kept = zip(pieces, kinds).filter { $0.1 == false }.map(\.0.text)
        // A rule or a blank line between the Chinese and the Japanese is not the blurb's.
        while let first = kept.first, letters(in: first) == 0 { kept.removeFirst() }
        while let last = kept.last, letters(in: last) == 0 { kept.removeLast() }
        let result = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// True for Japanese, false for not, nil for too short to tell.
    private static func kind(of sentence: Substring) -> Bool? {
        var letters = 0, hiragana = 0, katakana = 0, han = 0
        for scalar in sentence.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if isHiragana(scalar) { hiragana += 1 }
            else if (0x30A0...0x30FF).contains(scalar.value) { katakana += 1 }
            else if scalar.value >= 0x2E80 { han += 1 }
        }
        if letters > 0, hiragana * 10 >= letters || (hiragana + katakana) * 2 >= letters { return true }
        return han >= tellableHan ? false : nil
    }

    private static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value)
    }

    private static func letters(in text: Substring) -> Int {
        text.unicodeScalars.filter(\.properties.isAlphabetic).count
    }

    /// Sentence ends, after which the closing quotes and brackets and the spaces stay with it.
    private static let ends: Set<Character> = ["。", "！", "？", "!", "?", "…"]
    private static let closers: Set<Character> = ["」", "』", "”", "’", "）", ")", "》", "】", "\""]

    /// `text` cut after each sentence's end and each line break; joined, the pieces are `text`.
    static func sentences(_ text: String) -> [Substring] {
        var pieces: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard ends.contains(character) || character.isNewline else { continue }
            while index < text.endIndex, ends.contains(text[index]) || closers.contains(text[index]) || text[index].isWhitespace {
                index = text.index(after: index)
            }
            pieces.append(text[start..<index])
            start = index
        }
        if start < text.endIndex { pieces.append(text[start...]) }
        return pieces
    }
}
