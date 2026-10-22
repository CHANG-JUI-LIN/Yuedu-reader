import Foundation

// 中繼資料語言偏好推薦 (maintainer, 2026-10-21), in 聚合設定: one language, from a menu whose first
// item, 跟隨 App 語言, is the choice until the reader picks another. Its books come first and the
// others follow (優先推薦, fixed). It replaced 偏好閱讀語言, several languages in order, and 推薦範圍
// (Unified library 5d-3d, Phase 5 plan, decision 21). The interface language says what the
// buttons read in; this says whose books come first, so a Traditional Chinese interface can
// still put Japanese originals first.

/// The language in effect, and the home's books in its order.
struct ReadingLanguagePreferences: Equatable, Sendable {
    /// A `MetadataLanguage` tag (`zh-Hant`, `zh-Hans`, `en`, `ja`): Chinese keeps its script, for
    /// what is written in one.
    let language: String

    /// The base code a book's language is matched by (`zh`): the one language's.
    var languages: [String] { [ReadingLanguage.base(of: language)] }

    /// Where a book of `language` goes: the language's first; a book of unknown language (most
    /// book sources and OPDS feeds say none) after it; a known other language last.
    enum Rank: Comparable {
        case preferred(Int)
        case unknown
        case other
    }

    func rank(of language: String?) -> Rank {
        guard let language, !language.isEmpty else { return .unknown }
        return languages.firstIndex(of: ReadingLanguage.base(of: language)).map(Rank.preferred) ?? .other
    }

    /// A section's books by `rank`, each rank keeping the source's order among its books;
    /// none is left out. Places (an index's groups, a feed's) go first: a row draws them apart
    /// from the books, as chips, in their own order. A list (專題集合) goes by its best-placed
    /// book's language.
    func arrange(_ entries: [CollectionEntry]) -> [CollectionEntry] {
        let ranked = entries.enumerated().map { offset, entry -> (Rank, Int, CollectionEntry) in
            let rank: Rank
            switch entry {
            case .item(let record, let summary, _): rank = self.rank(of: summary.language ?? record.language)
            case .collection(let list): rank = list.languages.map { self.rank(of: $0) }.min() ?? .unknown
            case .location, .article: rank = .preferred(-1)
            }
            return (rank, offset, entry)
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }
}

/// 偏好閱讀語言 and 推薦範圍 as saved until 2026-10-21. Still read, for the choice the reader made
/// there (`MetadataLanguage.choice(migrating:interfaceLanguage:)`), and kept as stored.
struct LegacyReadingLanguages: Codable, Equatable, Sendable {
    /// Base codes, most wanted first.
    var languages: [String]
    /// `prefer`, `only` or `any`; 優先推薦 alone is left.
    var scope: String
}

/// 中繼資料語言偏好推薦's menu.
enum MetadataLanguage {
    /// 跟隨 App 語言: the menu's first item, and the choice until the reader picks another.
    static let followApp = "app"

    /// The languages after it: Chinese in each script (趨勢's lists are written in one), then the
    /// ones Yuedu's libraries hold most (Gutenberg's largest, 青空文庫's Japanese).
    static let offered = ["zh-Hant", "zh-Hans", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "nl", "la"]

    static let choices = [followApp] + offered

    /// The tag a choice stands for, with the app in `interfaceLanguage` (`zh-Hant`, `en`).
    static func tag(of choice: String, interfaceLanguage: String?) -> String {
        choice == followApp ? tag(interfaceLanguage: interfaceLanguage) : choice
    }

    /// The app's language as a tag: Chinese with its script, any other by its base code.
    static func tag(interfaceLanguage: String?) -> String {
        let code = interfaceLanguage ?? "en"
        guard ReadingLanguage.base(of: code) == "zh" else { return ReadingLanguage.base(of: code) }
        return Locale.Language(identifier: code).maximalIdentifier.contains("Hans") ? "zh-Hans" : "zh-Hant"
    }

    /// The choice 偏好閱讀語言 made: its first language, unless that was the app's, which is
    /// following the app. Its codes had no script: Chinese becomes Traditional, the app's own
    /// language (zh-Hant is its source). Nil when nothing was saved.
    static func choice(migrating legacy: LegacyReadingLanguages?, interfaceLanguage: String?) -> String? {
        guard let first = legacy?.languages.first.map(ReadingLanguage.base(of:)) else { return nil }
        if first == ReadingLanguage.base(of: tag(interfaceLanguage: interfaceLanguage)) { return followApp }
        return first == "zh" ? "zh-Hant" : first
    }

    /// The menu's text for a choice.
    static func name(of choice: String) -> String {
        choice == followApp ? localized("跟隨 App 語言") : ReadingLanguage.name(of: choice)
    }
}

enum ReadingLanguage {
    /// `zh-Hant-TW` → `zh`.
    static func base(of code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return base.lowercased()
    }

    /// The language's own name (中文, English, 日本語, Français; 繁體中文 for `zh-Hant`), as a
    /// language list shows it to someone who reads it; no string table needed.
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = (code.contains("-") ? locale.localizedString(forIdentifier: code)
            : locale.localizedString(forLanguageCode: code)) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
