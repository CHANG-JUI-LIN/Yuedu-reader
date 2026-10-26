import Foundation

/// Unified library 1c: the one normalization the work index compares titles and authors by
/// (design §7.1). It is used only for comparing; display text is never normalized.
enum WorkMatchKey {
    /// NFKC (full width to half width), lowercase, Traditional → Simplified, katakana →
    /// hiragana, then without whitespace, punctuation and symbols (Unicode Z\*, P\*, S\*,
    /// controls). Digits and the text inside brackets stay: 三體 ≠ 三體II, 斗罗大陆 ≠ 斗罗大陆3
    /// (`SearchAggregator.isLikelySameBook` has the same reason). Nothing else is stripped
    /// until real data has been measured.
    static func title(_ raw: String) -> String {
        fold(raw)
    }

    static func author(_ raw: String) -> String {
        fold(raw)
    }

    /// Both sides name at least one author, and some author of one is compatible with some
    /// author of the other: equal, or one contains the other and has at least 2 characters
    /// (the rule `SearchBook.isLikelySameBook` uses). B-level merging needs this;
    /// an empty side is never compatible (design §7.2), unlike today's search merge.
    static func authorsCompatible(_ lhs: [String], _ rhs: [String]) -> Bool {
        authorKeysCompatible(lhs.map(author), rhs.map(author))
    }

    /// `authorsCompatible` over keys already folded.
    static func authorKeysCompatible(_ lhs: [String], _ rhs: [String]) -> Bool {
        let right = rhs.filter { !$0.isEmpty }
        return lhs.contains { a in !a.isEmpty && right.contains { b in compatible(a, b) } }
    }

    /// `authors` without the placeholders the importers write for a book that names none
    /// (「未知作者」, the EPUB importer's 「未知」, the parsers' "Unknown Author") and without
    /// blank ones: what a match may compare. A TXT with no 「作者：」 line is stored as
    /// 「未知作者」, an EPUB whose package names none as 「未知」; neither is an author.
    static func knownAuthors(_ authors: [String]) -> [String] {
        authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !authorPlaceholders.contains($0) && $0 != localized("未知作者") }
    }

    private static let authorPlaceholders: Set<String> = ["未知作者", "未知", "Unknown Author"]

    /// Books matched by title alone, for a work that names no author: the author they agree on
    /// and which of them name that author. Maintainer, 2026-10-17: when every book names one
    /// author, it is that one; when they differ, the author most of them name wins if at least
    /// two places (`witness`) name it and they are two thirds of the books or more — an
    /// aggregator's one stray book of the same title no longer blocks the work. Nil otherwise:
    /// no author is guessed.
    static func agreedAuthor(_ books: [(witness: String, authors: [String])]) -> (name: String, agreeing: [Int])? {
        let keys = books.map { $0.authors.map(author).filter { !$0.isEmpty } }
        var best: [Int] = []
        for candidate in keys.indices where !keys[candidate].isEmpty {
            let agreeing = keys.indices.filter { authorKeysCompatible(keys[candidate], keys[$0]) }
            if agreeing.count > best.count { best = agreeing }
        }
        guard !best.isEmpty else { return nil }
        if best.count < keys.count {
            guard Set(best.map { books[$0].witness }).count >= 2, best.count * 3 >= keys.count * 2 else { return nil }
        }
        // The name as most of them write it (刘慈欣 over 劉慈欣 when more write it so), and of
        // those written as often the shortest: 「飞天鱼」 over 「飞天鱼 著」.
        let names = best.compactMap { books[$0].authors.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        guard let name = names.min(by: { lhs, rhs in
            let l = counts[lhs, default: 0], r = counts[rhs, default: 0]
            return l != r ? l > r : lhs.count < rhs.count
        }) else { return nil }
        return (name, best)
    }

    static func compatible(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 2, b.contains(a) { return true }
        if b.count >= 2, a.contains(b) { return true }
        return false
    }

    private static func fold(_ raw: String) -> String {
        let compatible = raw.precomposedStringWithCompatibilityMapping.lowercased()
        let simplified = compatible.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? compatible
        let kana = simplified.applyingTransform(.hiraganaToKatakana, reverse: true) ?? simplified
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: kana.unicodeScalars.filter { !isDropped($0) })
        return String(scalars)
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}

/// A language as a work index compares and groups it: the language and, when the tag says
/// so, its script.
///
/// Only what the tag itself says is used. `Locale.Language` fills in likely subtags — it
/// reads `zh` and `zho` as Hans and `und` as Latn — which would put every untagged Chinese
/// copy into a Simplified edition, so the subtags are parsed here. A script comes from an
/// explicit script subtag, or from a region that was written (`zh-TW` → Hant); otherwise
/// it is unknown.
struct LanguageTag: Hashable, Codable, Sendable, Comparable {
    /// ISO 639-1 where one exists (`zho` and `chi` become `zh`), otherwise the code as given.
    var language: String
    var script: String?

    init(language: String, script: String? = nil) {
        self.language = language
        self.script = script
    }

    /// Nil for an empty tag, `und`, or one whose first subtag is not a language code.
    init?(_ raw: String?) {
        guard let raw else { return nil }
        let subtags = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
        guard var code = subtags.first?.lowercased(),
              (2...3).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isLetter }),
              code != "und" else { return nil }
        code = Self.terminologyCode[code] ?? code
        if code.count == 3, let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) {
            code = alpha2
        }
        var script: String?
        var region: String?
        for subtag in subtags.dropFirst() {
            if subtag.count == 4, subtag.allSatisfy({ $0.isASCII && $0.isLetter }) {
                script = subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
            } else if region == nil,
                      (subtag.count == 2 && subtag.allSatisfy({ $0.isASCII && $0.isLetter }))
                        || (subtag.count == 3 && subtag.allSatisfy({ $0.isASCII && $0.isNumber })) {
                region = subtag.uppercased()
            }
        }
        if script == nil, let region {
            script = Locale.Language(identifier: "\(code)-\(region)").script?.identifier
        }
        self.init(language: code, script: script)
    }

    /// `zh-Hant`, or `zh` when the script is unknown.
    var identifier: String { script.map { "\(language)-\($0)" } ?? language }

    static func < (lhs: LanguageTag, rhs: LanguageTag) -> Bool {
        (lhs.language, lhs.script ?? "") < (rhs.language, rhs.script ?? "")
    }

    /// ISO 639-2/B codes that differ from their /T codes, which `Locale` knows.
    private static let terminologyCode: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
        "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
        "tib": "bod", "wel": "cym",
    ]
}
