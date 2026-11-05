import Combine
import Foundation
import os

/// The TXT chapter rules (設定 › 閱讀 › TXT 分章規則), persisted to
/// `Application Support/txt_toc_rules.json`. Main-actor owned for the settings screen; the
/// parser reads `currentRuleSet()`, a lock-guarded compiled snapshot every change refreshes,
/// from whichever thread indexes a book.
@MainActor
final class TXTTocRuleStore: @MainActor ObservableObject {
    static let shared = TXTTocRuleStore()

    @Published private(set) var rules: [TXTTocRule]

    private nonisolated static var fileURL: URL {
        StorageLocations.support.appendingPathComponent("txt_toc_rules.json")
    }

    private nonisolated static let snapshot = OSAllocatedUnfairLock(initialState: loadState())

    private struct State: Sendable {
        let rules: [TXTTocRule]
        let ruleSet: TXTTocRuleSet
    }

    private init() {
        rules = Self.snapshot.withLock { $0.rules }
    }

    /// The enabled rules, compiled, with the fingerprint an index built from them is cached
    /// under. Read once per index build, so an index and its cache key always agree.
    nonisolated static func currentRuleSet() -> TXTTocRuleSet {
        snapshot.withLock { $0.ruleSet }
    }

    // MARK: - Editing

    func add(_ rule: TXTTocRule) {
        var rule = rule
        if rules.contains(where: { $0.id == rule.id }) { rule.id = nextID() }
        replaceAll(rules + [rule])
    }

    func update(_ rule: TXTTocRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return add(rule) }
        var next = rules
        next[index] = rule
        replaceAll(next)
    }

    func setEnabled(_ enabled: Bool, id: Int64) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var next = rules
        next[index].enable = enabled
        replaceAll(next)
    }

    func delete(ids: Set<Int64>) {
        replaceAll(rules.filter { !ids.contains($0.id) })
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var next = rules
        let moving = source.map { next[$0] }
        for offset in source.reversed() { next.remove(at: offset) }
        next.insert(contentsOf: moving, at: destination - source.count { $0 < destination })
        replaceAll(next)
    }

    /// Imports a legado `txtRule` export: one rule object or an array of them. A rule with an
    /// id already here replaces it, as legado's import does; the rest are appended in file
    /// order. Throws when nothing in the data is a usable rule.
    @discardableResult
    func importLegadoData(_ data: Data) throws -> Int {
        let imported = try Self.decodeLegado(data)
        var next = rules
        for rule in imported {
            if let index = next.firstIndex(where: { $0.id == rule.id }) {
                next[index] = rule
            } else {
                next.append(rule)
            }
        }
        replaceAll(next)
        return imported.count
    }

    nonisolated static func decodeLegado(_ data: Data) throws -> [TXTTocRule] {
        let decoder = JSONDecoder()
        let decoded: [TXTTocRule]
        if let list = try? decoder.decode([TXTTocRule].self, from: data) {
            decoded = list
        } else {
            decoded = [try decoder.decode(TXTTocRule.self, from: data)]
        }
        let usable = decoded.filter { !$0.chapterRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { throw TXTTocRuleError.emptyChapterRule }
        // legado orders by serialNumber; equal numbers keep file order.
        return usable.enumerated().sorted {
            ($0.element.serialNumber, $0.offset) < ($1.element.serialNumber, $1.offset)
        }.map(\.element)
    }

    func nextID() -> Int64 {
        max(TXTTocRule.newID(), (rules.map(\.id).max() ?? 0) + 1)
    }

    private func replaceAll(_ next: [TXTTocRule]) {
        // serialNumber mirrors list order, so an export reorders the same way in legado.
        let ordered = next.enumerated().map { order, rule -> TXTTocRule in
            var copy = rule
            copy.serialNumber = order
            return copy
        }
        rules = ordered
        let state = State(rules: ordered, ruleSet: TXTTocRuleSet(rules: ordered))
        Self.snapshot.withLock { $0 = state }
        Self.write(ordered)
    }

    // MARK: - Persistence

    private nonisolated static func loadState() -> State {
        let rules = readRules() ?? TXTTocRuleDefaults.rules
        return State(rules: rules, ruleSet: TXTTocRuleSet(rules: rules))
    }

    /// nil when nothing was ever saved: the built-in rules apply. An unreadable file is
    /// logged and also falls back to them, without overwriting it, so it can be recovered.
    private nonisolated static func readRules() -> [TXTTocRule]? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode([TXTTocRule].self, from: Data(contentsOf: url))
        } catch {
            AppLogger.error("TXT chapter rules unreadable; using built-in rules", error: error)
            return nil
        }
    }

    private nonisolated static func write(_ rules: [TXTTocRule]) {
        do {
            try JSONEncoder().encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.error("TXT chapter rules write failed", error: error)
        }
    }
}
