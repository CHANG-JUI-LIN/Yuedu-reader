import Foundation

// Phase 6c: a module is a declarative file that lists books from one site (design §14.2). Only
// the top level follows ForwardWidgets; where Forward has a JS function, each entry carries a
// `request` and a `list` of rule-engine rules instead. The file as written is what the store
// keeps, so keys a newer app adds survive this one untouched.

struct RuleModule: Codable, Hashable, Sendable {
    /// File-safe (`[A-Za-z0-9._-]`): it names the module's folder.
    var id: String
    var title: String
    var description: String?
    var author: String?
    var site: String?
    /// Numeric dot form (`1.0.0`); 檢查更新 accepts a higher one.
    var version: String
    /// The lowest app version that reads this file.
    var requiredVersion: String?
    /// The only hosts its requests may go to.
    var hosts: [String]
    /// Legado's `concurrentRate` syntax (`SourceRateLimit`).
    var rateLimit: String?
    var modules: [Entry]
    var search: Entry?
    /// A book by its ISBN (`{{isbn}}`): the record is the copy's own, so it may also give a
    /// cover (from `hosts` only), a publisher and a series. Fill only (format 3.0).
    var lookup: Entry?
    /// The credit the site asks for, shown on the module's page (format 3.0).
    var attribution: Attribution?
    /// Its own words in other languages, by language tag (`en`, `zh-Hans`): the title, the
    /// description and each entry's, shown in the app's language when one matches (format 3.0).
    var localizations: [String: Localization]?

    struct Localization: Codable, Hashable, Sendable {
        var title: String?
        var description: String?
        /// By entry id.
        var entries: [String: EntryText]?
    }

    struct EntryText: Codable, Hashable, Sendable {
        var title: String?
        var description: String?
    }

    /// A line naming the site, as its terms word it: 楽天's "Supported by Rakuten Developers".
    struct Attribution: Codable, Hashable, Sendable {
        var text: String
        /// Where the credit links; http(s).
        var url: String?
    }

    /// One list: a home section, or the module's search.
    struct Entry: Codable, Hashable, Sendable {
        /// Absent on the search entry.
        var id: String?
        var title: String?
        var description: String?
        /// Seconds a fetched page answers again without a request.
        var cacheDuration: Int?
        var params: [Param]
        var request: Request
        var list: ListRules
        /// `text` (absent) or `comic`: what its items are, unless an item's `contentKind` rule
        /// says `comic` (format 3.0).
        var contentKind: String?
        /// Tags the `tags` rule reads that are not genres on this site (`漫画`, `单行本`), left
        /// out wherever its tags are used (format 3.0).
        var excludeTags: [String]?
        /// On `lookup`: the ISBN-13 prefixes the site has (openBD: `9784`). Any other book's ISBN
        /// never leaves the device (format 3.0).
        var isbnPrefixes: [String]?

        init(id: String?, title: String?, description: String? = nil, cacheDuration: Int? = nil,
             params: [Param] = [], request: Request, list: ListRules, contentKind: String? = nil,
             excludeTags: [String]? = nil, isbnPrefixes: [String]? = nil) {
            self.id = id
            self.title = title
            self.description = description
            self.cacheDuration = cacheDuration
            self.params = params
            self.request = request
            self.list = list
            self.contentKind = contentKind
            self.excludeTags = excludeTags
            self.isbnPrefixes = isbnPrefixes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            cacheDuration = try container.decodeIfPresent(Int.self, forKey: .cacheDuration)
            params = try container.decodeIfPresent([Param].self, forKey: .params) ?? []
            request = try container.decode(Request.self, forKey: .request)
            list = try container.decode(ListRules.self, forKey: .list)
            contentKind = try container.decodeIfPresent(String.self, forKey: .contentKind)
            excludeTags = try container.decodeIfPresent([String].self, forKey: .excludeTags)
            isbnPrefixes = try container.decodeIfPresent([String].self, forKey: .isbnPrefixes)
        }
    }

    /// Forward's parameter, by its names and types.
    struct Param: Codable, Hashable, Sendable {
        var name: String
        var title: String?
        /// A `ParamType` raw value; anything else is rejected by name rather than by decoding.
        var type: String
        var description: String?
        /// The default. A number in the file reads as its text.
        var value: String?
        var enumOptions: [Option]?

        var kind: ParamType? { ParamType(rawValue: type) }

        init(name: String, title: String? = nil, type: String, description: String? = nil, value: String? = nil,
             enumOptions: [Option]? = nil) {
            self.name = name
            self.title = title
            self.type = type
            self.description = description
            self.value = value
            self.enumOptions = enumOptions
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            type = try container.decode(String.self, forKey: .type)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            if let text = try? container.decodeIfPresent(String.self, forKey: .value) {
                value = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .value) {
                value = String(number)
            } else {
                value = try container.decodeIfPresent(Double.self, forKey: .value).map { String($0) }
            }
            enumOptions = try container.decodeIfPresent([Option].self, forKey: .enumOptions)
        }
    }

    enum ParamType: String, CaseIterable, Sendable {
        /// Typed by the reader in the section editor.
        case input
        /// A number.
        case count
        /// Fixed.
        case constant
        /// Picked from `enumOptions`.
        case enumeration
        /// Filled by paging.
        case page, offset
    }

    struct Option: Codable, Hashable, Sendable {
        var title: String
        var value: String
    }

    struct Request: Codable, Hashable, Sendable {
        /// `{{name}}` stands for a parameter (or `page`, `offset`, `keyword` on search).
        var url: String
        /// GET when absent.
        var method: String?
        var body: String?
        var headers: [String: String]?
        var charset: String?
        /// How a value goes into `body`: `form` (absent), percent-encoded, or `json`, escaped as
        /// a JSON string's contents, for a body such as `{"keyword":"{{keyword}}"}` (format 3.0).
        var bodyEncoding: String?
    }

    /// `Request.bodyEncoding`'s values.
    enum BodyEncoding: String, CaseIterable, Sendable {
        case form, json
    }

    /// The rule engine's own syntax: CSS, XPath, JSONPath, Regex, with `||` `&&` `%%` `##`.
    struct ListRules: Codable, Hashable, Sendable {
        var items: String
        var title: String
        var author: String?
        var cover: String?
        var intro: String?
        var url: String?
        var kind: String?
        var language: String?
        /// Other names of the work, several values: its titles in other languages (format 3.0).
        var aliases: String? = nil
        /// Its genres and themes, several values (format 3.0).
        var tags: String? = nil
        var publisher: String? = nil
        /// An ISBN-10 or -13; one that fails its check digit is dropped (format 3.0).
        var isbn: String? = nil
        var series: String? = nil
        /// `comic` makes the item a comic; any other value leaves the entry's kind (format 3.0).
        var contentKind: String? = nil
    }
}

extension RuleModule {
    /// The module in `language` (the app's, `Bundle.main.preferredLocalizations`): the words of
    /// the localization of the same language and script, where it has them. Without one it is
    /// as written: `zh-Hans` never stands in for `zh-Hant`, nor `en` for anything.
    func localized(for language: String) -> RuleModule {
        guard let localizations, let text = Self.localization(in: localizations, for: language) else { return self }
        var module = self
        if let title = text.title?.nonBlank { module.title = title }
        if let description = text.description?.nonBlank { module.description = description }
        for (index, entry) in module.modules.enumerated() {
            guard let id = entry.id, let words = text.entries?[id] else { continue }
            if let title = words.title?.nonBlank { module.modules[index].title = title }
            if let description = words.description?.nonBlank { module.modules[index].description = description }
        }
        return module
    }

    private static func localization(in localizations: [String: Localization], for language: String) -> Localization? {
        if let exact = localizations[language] { return exact }
        let wanted = Locale.Language(identifier: language).maximalIdentifier
        let wantedLanguage = Locale.Language(identifier: wanted)
        return localizations.sorted { $0.key < $1.key }.first { key, _ in
            let candidate = Locale.Language(identifier: Locale.Language(identifier: key).maximalIdentifier)
            return candidate.languageCode == wantedLanguage.languageCode && candidate.script == wantedLanguage.script
        }?.value
    }
}

private extension String {
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// The first app version that reads each field added since Phase 6. A module that uses one
/// must say so in `requiredVersion`, or an older app would import it and run it wrongly
/// (a JSON body sent percent-encoded searches for `%E8…`).
enum RuleModuleFormat {
    static let version3 = "3.0"
}

extension RuleModule.ListRules {
    /// The same mapping a 來源配置's search list uses.
    var fields: RuleListFields {
        RuleListFields(name: title, author: author ?? "", bookUrl: url ?? "", coverUrl: cover ?? "",
                       intro: intro ?? "", wordCount: "", lastChapter: "", kind: kind ?? "", language: language ?? "",
                       aliases: aliases ?? "", tags: tags ?? "", publisher: publisher ?? "", isbn: isbn ?? "",
                       series: series ?? "", contentKind: contentKind ?? "")
    }
}

/// A numeric dot version (`3.0`, `1.2.10`); missing components count as zero.
struct RuleModuleVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    /// The running app's `CFBundleShortVersionString`.
    static var app: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
