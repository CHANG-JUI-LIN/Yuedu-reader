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

        init(id: String?, title: String?, description: String? = nil, cacheDuration: Int? = nil,
             params: [Param] = [], request: Request, list: ListRules) {
            self.id = id
            self.title = title
            self.description = description
            self.cacheDuration = cacheDuration
            self.params = params
            self.request = request
            self.list = list
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
    }
}

extension RuleModule.ListRules {
    /// The same mapping a 來源配置's search list uses.
    var fields: RuleListFields {
        RuleListFields(name: title, author: author ?? "", bookUrl: url ?? "", coverUrl: cover ?? "",
                       intro: intro ?? "", wordCount: "", lastChapter: "", kind: kind ?? "")
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
