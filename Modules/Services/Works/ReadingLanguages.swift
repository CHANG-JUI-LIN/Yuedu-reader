import Foundation

// Unified library 5d-3d: 偏好閱讀語言 (Phase 5 plan, decision 21), Emby's language preference
// mapped onto books. The interface language says what the buttons read in; these say which
// books the reader can read, so a Traditional Chinese interface can still prefer English and
// Japanese originals. Several languages, in order; the first is the most wanted.

/// The reader's languages and how strictly the home keeps to them.
struct ReadingLanguagePreferences: Codable, Equatable, Sendable {
    /// 推薦範圍.
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 優先推薦偏好語言: the preferred languages first, the others after them.
        case prefer
        /// 只推薦偏好語言: books known to be in another language are left out.
        case only
        /// 不限制語言: the sources' own order.
        case any

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .prefer: "優先推薦偏好語言"
            case .only: "只推薦偏好語言"
            case .any: "不限制語言"
            }
        }
    }

    /// Base language codes (`zh`, `en`, `ja`), most wanted first.
    var languages: [String]
    var scope: Scope

    /// Before the reader chooses: the interface language alone, preferred (decision 21), so a
    /// new install orders Gutenberg's categories as the interface language did before.
    static func initial(interfaceLanguage: String?) -> Self {
        Self(languages: [ReadingLanguage.base(of: interfaceLanguage ?? "en")], scope: .prefer)
    }

    /// Where a book of `language` goes: a preferred language by its place in the list; a book
    /// of unknown language (most book sources and OPDS feeds say none) after every preferred
    /// one, kept even under 只推薦 (decision 21); a known other language last.
    enum Rank: Comparable {
        case preferred(Int)
        case unknown
        case other
    }

    func rank(of language: String?) -> Rank {
        guard let language, !language.isEmpty else { return .unknown }
        return languages.firstIndex(of: ReadingLanguage.base(of: language)).map(Rank.preferred) ?? .other
    }

    /// A section's books in the preferred languages' order, each language keeping the
    /// source's order among its books; under 只推薦, without the books known to be in another
    /// language. Places (an index's groups, a feed's) go first: a row draws them apart from the
    /// books, as chips, in their own order.
    func arrange(_ entries: [CollectionEntry]) -> [CollectionEntry] {
        guard scope != .any, !languages.isEmpty else { return entries }
        let ranked = entries.enumerated().compactMap { offset, entry -> (Rank, Int, CollectionEntry)? in
            guard case .item(let record, let summary, _) = entry else { return (.preferred(-1), offset, entry) }
            let rank = rank(of: summary.language ?? record.language)
            if scope == .only, rank == .other { return nil }
            return (rank, offset, entry)
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }
}

enum ReadingLanguage {
    /// The languages 偏好閱讀語言 offers: the ones Yuedu's libraries hold most (Gutenberg's
    /// largest, 青空文庫's Japanese, book sources' Chinese).
    static let offered = ["zh", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "nl", "la"]

    /// `zh-Hant-TW` → `zh`.
    static func base(of code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return base.lowercased()
    }

    /// The language's own name (中文, English, 日本語, Français), as a language list shows it
    /// to someone who reads it; no string table needed.
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
