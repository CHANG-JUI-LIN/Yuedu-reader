import Foundation
import Combine

/// Singleton store for user-configurable replace rules.
///
/// Rules are persisted to `Library/replace_rules.json`.  On first launch a set
/// of useful preset rules is installed.  The store is observable so SwiftUI
/// views update automatically when rules change.
final class ReplaceRuleStore: ObservableObject {

    static let shared = ReplaceRuleStore()

    @Published private(set) var rules: [ReplaceRule] = []

    private let fileURL: URL

    /// Marks that the built-in presets have been installed on this install. Without it,
    /// deleting every rule made the next launch treat the store as brand new and put the
    /// presets back, so the rules could not be removed. Cleared with the app, so a real
    /// reinstall still seeds them.
    private static let presetsInstalledKey = "yd_replace_presets_installed"

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("replace_rules.json")
        load()
        if rules.isEmpty, !UserDefaults.standard.bool(forKey: Self.presetsInstalledKey) {
            installPresets()
        }
    }

    // MARK: - CRUD

    func add(_ rule: ReplaceRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: ReplaceRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func delete(id: String) {
        rules.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var copy = rules
        let indices = source.sorted().reversed()
        var removed: [ReplaceRule] = []
        for i in indices {
            removed.insert(copy.remove(at: i), at: 0)
        }
        let adjustedDest = destination - source.filter { $0 < destination }.count
        copy.insert(contentsOf: removed, at: adjustedDest)
        rules = copy
        for (i, _) in rules.enumerated() { rules[i].sortOrder = i }
        save()
    }

    // MARK: - Query

    /// Rules that apply to the given book-source URL, sorted by `sortOrder`.
    func rules(for sourceUrl: String) -> [ReplaceRule] {
        rules
            .filter { $0.enabled && Self.scope($0.scope, matches: sourceUrl) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private static func scope(_ scope: String, matches sourceUrl: String) -> Bool {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "global", trimmed != "*" else { return true }
        if trimmed == sourceUrl { return true }

        let separators = CharacterSet(charactersIn: ",，;；\n")
        return trimmed
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(sourceUrl)
    }

    func replaceRulesFromSync(_ syncedRules: [ReplaceRule]) {
        // Deduplicate here too: until every device has run the stable-id build, a merge
        // can still hand back the old duplicated set from the cloud.
        rules = Self.deduplicated(syncedRules.sorted { $0.sortOrder < $1.sortOrder })
        save()
    }

    @discardableResult
    func importFromLegadoJSON(_ json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else {
            throw ReplaceRuleImportError.invalidData
        }
        return try importFromLegadoData(data)
    }

    @discardableResult
    func importFromLegadoData(_ data: Data) throws -> Int {
        let importedRules = try ReplaceRuleImportParser.parse(data: data)
        guard !importedRules.isEmpty else {
            throw ReplaceRuleImportError.noRules
        }

        var nextOrder = (rules.map(\.sortOrder).max() ?? -1) + 1
        var importedCount = 0
        for importedRule in importedRules {
            var rule = importedRule
            if let existingIndex = rules.firstIndex(where: {
                $0.pattern == rule.pattern
                    && $0.replacement == rule.replacement
                    && $0.scope == rule.scope
            }) {
                rule.id = rules[existingIndex].id
                rule.sortOrder = rules[existingIndex].sortOrder
                rules[existingIndex] = rule
            } else {
                rule.id = UUID().uuidString
                rule.sortOrder = nextOrder
                nextOrder += 1
                rules.append(rule)
            }
            importedCount += 1
        }
        save()
        return importedCount
    }

    /// Re-reads the on-disk store into memory. Used after an iCloud restore
    /// overwrites `replace_rules.json` so the live UI reflects it without a relaunch.
    func reloadFromDisk() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ReplaceRule].self, from: data) else {
            return
        }
        rules = Self.deduplicated(decoded)
        // Persist immediately when copies were dropped, so the next sync sees the
        // shrunken set and tombstones the ids that went away.
        if rules.count != decoded.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Presets

    /// Preset ids are fixed strings, never fresh UUIDs.
    ///
    /// iCloud merges rules by id. When every install minted new UUIDs for the same five
    /// presets, a reinstall (or a second device) produced five ids the cloud had never
    /// seen, so the merge kept both sets and the list grew by five every time. A stable
    /// id makes those the same record everywhere, and the merge collapses them.
    private func installPresets() {
        let presets: [(id: String, name: String, pattern: String, replacement: String)] = [
            ("preset.ad-filter.leading", "廣告文字過濾（首行）", "^\\s*本章節.*?(?=\\n)", ""),
            ("preset.ad-filter.trailing", "廣告文字過濾（尾行）", "(?<=\\n).*?閱讀\\s*$", ""),
            ("preset.collapse-blank-lines", "合并多餘空行", "\\n{3,}", "\n\n"),
            ("preset.trim-leading-space", "清除全形空格開頭", "^[\\u3000\\s]+", ""),
            ("preset.trim-trailing-space", "清除行末空白", "[\\t ]+$", ""),
        ]
        for (i, preset) in presets.enumerated() {
            rules.append(ReplaceRule(
                id: preset.id,
                name: preset.name,
                pattern: preset.pattern,
                replacement: preset.replacement,
                isRegex: true,
                sortOrder: i
            ))
        }
        UserDefaults.standard.set(true, forKey: Self.presetsInstalledKey)
        save()
    }

    /// Collapses rules that would do exactly the same substitution.
    ///
    /// Cleans up what the UUID-per-install bug above already duplicated on people's
    /// devices: running the identical pattern twice can never change the output, so the
    /// copies are pure noise. Keeping the lowest id makes two devices independently pick
    /// the same survivor, and the ids that disappear are tombstoned by the normal sync
    /// path so the copies do not come back from the cloud.
    ///
    /// Can be deleted once no install carries duplicates from before the stable-id fix.
    /// Not `private` so `ReplaceRuleDeduplicationTests` can cover it without reaching
    /// through the singleton's private init.
    static func deduplicated(_ input: [ReplaceRule]) -> [ReplaceRule] {
        var survivorIndexByKey: [String: Int] = [:]
        var output: [ReplaceRule] = []
        for rule in input {
            let key = "\(rule.pattern)\u{1F}\(rule.replacement)\u{1F}\(rule.scope)\u{1F}\(rule.isRegex)"
            guard let existing = survivorIndexByKey[key] else {
                survivorIndexByKey[key] = output.count
                output.append(rule)
                continue
            }
            if rule.id < output[existing].id {
                output[existing] = rule
            }
        }
        return output
    }
}

enum ReplaceRuleImportError: LocalizedError {
    case invalidData
    case parseError
    case noRules

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return localized("無法讀取文件")
        case .parseError:
            return localized("替換規則 JSON 解析失敗")
        case .noRules:
            return localized("未找到可匯入的替換規則")
        }
    }
}

enum ReplaceRuleImportParser {
    static func parse(data: Data) throws -> [ReplaceRule] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReplaceRuleImportError.parseError
        }

        guard let rawRules = ruleObjects(from: object) else {
            throw ReplaceRuleImportError.noRules
        }

        let rules = rawRules.compactMap { makeRule(from: $0) }
        guard !rules.isEmpty else {
            throw ReplaceRuleImportError.noRules
        }
        return rules
    }

    private static func ruleObjects(from object: Any) -> [[String: Any]]? {
        if let array = object as? [[String: Any]] {
            return array
        }

        guard let dictionary = object as? [String: Any] else {
            return nil
        }

        if looksLikeRule(dictionary) {
            return [dictionary]
        }

        for key in ["replaceRules", "replaceRule", "replaceRuleList", "rules"] {
            guard let nested = dictionary[key],
                  let objects = ruleObjects(from: nested) else { continue }
            return objects
        }

        if let nested = dictionary["data"] {
            return ruleObjects(from: nested)
        }

        return nil
    }

    private static func looksLikeRule(_ dictionary: [String: Any]) -> Bool {
        dictionary["pattern"] != nil
            || dictionary["regex"] != nil
            || dictionary["replaceRegex"] != nil
    }

    private static func makeRule(from dictionary: [String: Any]) -> ReplaceRule? {
        guard boolValue(dictionary["scopeContent"], defaultValue: true) else {
            return nil
        }

        let pattern = firstString(in: dictionary, keys: ["pattern", "regex", "replaceRegex"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }

        let group = stringValue(dictionary["group"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = stringValue(dictionary["name"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName: String
        if group.isEmpty {
            displayName = rawName
        } else if rawName.isEmpty {
            displayName = group
        } else {
            displayName = "\(rawName) (\(group))"
        }

        let replacement = firstString(in: dictionary, keys: ["replacement", "replace"])
        let rawScope = stringValue(dictionary["scope"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = rawScope.isEmpty ? "global" : rawScope
        let sortOrder = intValue(
            dictionary["sortOrder"] ?? dictionary["order"],
            defaultValue: 0
        )

        return ReplaceRule(
            id: UUID().uuidString,
            name: displayName,
            pattern: pattern,
            replacement: replacement,
            isRegex: boolValue(dictionary["isRegex"], defaultValue: true),
            enabled: boolValue(
                dictionary["isEnabled"] ?? dictionary["enabled"],
                defaultValue: true
            ),
            scope: scope,
            sortOrder: sortOrder
        )
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            let value = stringValue(dictionary[key])
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private static func boolValue(_ value: Any?, defaultValue: Bool) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
            return defaultValue
        default:
            return defaultValue
        }
    }

    private static func intValue(_ value: Any?, defaultValue: Int) -> Int {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        default:
            return defaultValue
        }
    }
}
