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

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("replace_rules.json")
        load()
        if rules.isEmpty { installPresets() }
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
            .filter { $0.enabled && ($0.scope == "global" || $0.scope == sourceUrl) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func replaceRulesFromSync(_ syncedRules: [ReplaceRule]) {
        rules = syncedRules.sorted { $0.sortOrder < $1.sortOrder }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ReplaceRule].self, from: data) else {
            return
        }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Presets

    private func installPresets() {
        let presets: [(String, String, String, Bool)] = [
            // (name, pattern, replacement, isRegex)
            ("移除 HTML 標籤",       "<[^>]+>",                          "",      true),
            ("廣告文字過濾（首行）",  "^\\s*本章節.*?(?=\\n)",              "",      true),
            ("廣告文字過濾（尾行）",  "(?<=\\n).*?閱讀\\s*$",              "",      true),
            ("水印去除",             "(?i)(www\\.|http)[^\\s，。！？]+",   "",      true),
            ("合并多餘空行",          "\\n{3,}",                           "\n\n",  true),
            ("清除全形空格開頭",      "^[\\u3000\\s]+",                    "",      true),
            ("清除行末空白",          "[\\t ]+$",                          "",      true),
        ]
        for (i, preset) in presets.enumerated() {
            rules.append(ReplaceRule(
                name: preset.0,
                pattern: preset.1,
                replacement: preset.2,
                isRegex: preset.3,
                sortOrder: i
            ))
        }
        save()
    }
}
