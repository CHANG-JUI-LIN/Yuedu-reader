import Foundation

enum AozoraCatalogError: Error, Equatable {
    case unsupportedSchema(Int), invalidCatalog, hashMismatch
}

struct AozoraCatalog: Codable, Sendable {
    var schemaVersion: Int
    var persons: [AozoraPerson]
    var works: [AozoraWork]

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1 else { throw AozoraCatalogError.unsupportedSchema(catalog.schemaVersion) }
        let people = Set(catalog.persons.map(\.id))
        guard people.count == catalog.persons.count,
              Set(catalog.works.map(\.id)).count == catalog.works.count,
              catalog.works.allSatisfy({ work in work.credits.allSatisfy { people.contains($0.person) } }) else {
            throw AozoraCatalogError.invalidCatalog
        }
        return catalog
    }
}

struct AozoraPerson: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var yomi: String
    var sortYomi: String
    var born: String
    var died: String
}

struct AozoraWork: Codable, Hashable, Identifiable, Sendable {
    struct Credit: Codable, Hashable, Sendable {
        var person: String
        var role: String
    }
    var id: String
    var title: String
    var yomi: String
    var sortYomi: String
    var subtitle: String
    var kanaStyle: String
    var ndc: String
    var published: String
    var updated: String
    var card: String
    var text: String
    var textUpdated: String
    var credits: [Credit]
    var source: String
    var sourcePublisher: String
}

struct AozoraIndexGroup: Identifiable, Sendable {
    let id: String
    let titleKey: String
    let ids: [String]
}

/// Built once off the main actor. Search uses the pre-normalized strings, never
/// repeats Unicode transforms over the entire catalog for each keystroke.
struct AozoraCatalogIndex: Sendable {
    let personsByID: [String: AozoraPerson]
    let worksByID: [String: AozoraWork]
    let newWorks: [AozoraWork]
    let authorGroups: [AozoraIndexGroup]
    let titleGroups: [AozoraIndexGroup]
    let classificationGroups: [AozoraIndexGroup]
    private let personWorks: [String: [AozoraWork]]
    private let searchRecords: [SearchRecord]
    private struct SearchRecord: Sendable {
        let work: AozoraWork
        let title: String
        let yomi: String
        let authors: String
    }

    init(catalog: AozoraCatalog) {
        personsByID = Dictionary(uniqueKeysWithValues: catalog.persons.map { ($0.id, $0) })
        worksByID = Dictionary(uniqueKeysWithValues: catalog.works.map { ($0.id, $0) })
        let sorted = catalog.works.sorted { ($0.sortYomi, $0.id) < ($1.sortYomi, $1.id) }
        newWorks = sorted.sorted { $0.published == $1.published ? ($0.sortYomi, $0.id) < ($1.sortYomi, $1.id) : $0.published > $1.published }
        authorGroups = Self.groups(catalog.persons.sorted { ($0.sortYomi, $0.id) < ($1.sortYomi, $1.id) }.map { ($0.id, Self.kanaGroup($0.sortYomi)) }, order: Self.kanaOrder)
        titleGroups = Self.groups(sorted.map { ($0.id, Self.kanaGroup($0.sortYomi)) }, order: Self.kanaOrder)
        classificationGroups = Self.groups(sorted.flatMap { work in
            Self.classifications(work.ndc).map { (work.id, $0) }
        }, order: ["913", "911", "914", "91x", "9xx", "other"])
        var byPerson: [String: [AozoraWork]] = [:]
        for work in sorted {
            for person in Set(work.credits.map(\.person)) { byPerson[person, default: []].append(work) }
        }
        personWorks = byPerson
        let people = personsByID
        searchRecords = sorted.map { work in
            let authors = work.credits.compactMap { people[$0.person] }
                .map { $0.name + " " + $0.yomi }.joined(separator: " ")
            return SearchRecord(work: work, title: Self.normalized(work.title), yomi: Self.normalized(work.yomi),
                                authors: Self.normalized(authors))
        }
    }

    func works(forPerson id: String) -> [AozoraWork] { personWorks[id] ?? [] }

    func search(_ query: String) -> [AozoraWork] {
        let query = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        return searchRecords.compactMap { record -> (Int, AozoraWork)? in
            if record.title.hasPrefix(query) || record.yomi.hasPrefix(query) { return (0, record.work) }
            if record.title.contains(query) || record.yomi.contains(query) { return (1, record.work) }
            if record.authors.contains(query) { return (2, record.work) }
            return nil
        }.sorted { ($0.0, $0.1.sortYomi, $0.1.id) < ($1.0, $1.1.sortYomi, $1.1.id) }.map(\.1)
    }

    private static let kanaOrder = ["あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ", "latin", "other"]

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
        return folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
    }

    static func kanaGroup(_ reading: String) -> String {
        guard let first = normalized(reading).first else { return "other" }
        let rows = ["あぁいぃうぅえぇおぉ", "かがきぎくぐけげこごゕゖ", "さざしじすずせぜそぞ", "ただちぢっつづてでとど",
                    "なにぬねの", "はばぱひびぴふぶぷへべぺほぼぽ", "まみむめも", "ゃやゅゆょよ", "らりるれろ", "わゎゐゑをん"]
        if let index = rows.firstIndex(where: { $0.contains(first) }) { return kanaOrder[index] }
        return first.isASCII && first.isLetter ? "latin" : "other"
    }

    private static func classifications(_ ndc: String) -> [String] {
        let codes = ndc.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count == 3 }
        let groups = codes.map { code -> String in
            if ["913", "911", "914"].contains(String(code)) { return String(code) }
            if code.hasPrefix("91") { return "91x" }
            if code.hasPrefix("9") { return "9xx" }
            return "other"
        }
        return groups.isEmpty ? ["other"] : Array(Set(groups))
    }

    private static func groups(_ entries: [(String, String)], order: [String]) -> [AozoraIndexGroup] {
        let titles = ["latin": "拉丁字母", "other": "其他", "913": "小説・物語", "911": "詩歌", "914": "評論・エッセイ", "91x": "其他日本文學", "9xx": "其他文學"]
        var grouped: [String: [String]] = [:]
        for (id, group) in entries { grouped[group, default: []].append(id) }
        return order.compactMap { key in
            guard let ids = grouped[key], !ids.isEmpty else { return nil }
            return AozoraIndexGroup(id: key, titleKey: titles[key] ?? key, ids: ids)
        }
    }
}
