import Combine
import SwiftUI

struct RegexHighlightSummary: Equatable, Sendable {
    var enabledCount: Int
    var builtInCount: Int
    var customCount: Int
}

@MainActor
final class RegexHighlightSettingsModel: ObservableObject {
    @Published private(set) var configuration: RegexHighlightConfiguration

    private let onChange: (RegexHighlightConfiguration) -> Void

    var summary: RegexHighlightSummary {
        RegexHighlightSummary(
            enabledCount: configuration.evaluationRules.filter(\.isEnabled).count,
            builtInCount: configuration.rules.count,
            customCount: configuration.customRules.count
        )
    }

    init(
        configuration: RegexHighlightConfiguration,
        onChange: @escaping (RegexHighlightConfiguration) -> Void
    ) {
        self.configuration = configuration.sanitized()
        self.onChange = onChange
    }

    func setGlobalEnabled(_ value: Bool) {
        mutate { $0.isEnabled = value }
    }

    func setRuleEnabled(_ value: Bool, id: String) {
        mutate { configuration in
            if let index = configuration.rules.firstIndex(where: { $0.id == id }) {
                configuration.rules[index].isEnabled = value
            } else if let index = configuration.customRules.firstIndex(where: { $0.id == id }) {
                configuration.customRules[index].isEnabled = value
            }
        }
    }

    /// Back to the shipped rule set. Keeps the global switch where the user left
    /// it — 重設所有規則 is about the rules, and silently switching highlighting
    /// back on would be a second, unasked-for change.
    func resetToDefaults() {
        mutate { configuration in
            configuration.rules = RegexHighlightRule.builtIns
            configuration.customRules = []
        }
    }

    /// Returns an isolated draft. The configuration is not mutated until the
    /// rule editor completes its atomic save.
    func makeCustomDraft() -> RegexHighlightRule {
        RegexHighlightRule.custom(name: localized("新規則"), pattern: "")
    }

    func copyAsCustom(ruleID: String) {
        guard let source = configuration.evaluationRules.first(where: { $0.id == ruleID }) else {
            return
        }
        mutate { $0.customRules.append(source.copyAsCustom()) }
    }

    func update(_ rule: RegexHighlightRule) {
        mutate { configuration in
            if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
                configuration.rules[index] = rule
            } else if let index = configuration.customRules.firstIndex(where: { $0.id == rule.id }) {
                configuration.customRules[index] = rule
            } else if !rule.isBuiltIn {
                configuration.customRules.append(rule)
            }
        }
    }

    func delete(ruleID: String) {
        guard configuration.customRules.contains(where: { $0.id == ruleID }) else { return }
        mutate { $0.customRules.removeAll { $0.id == ruleID } }
    }

    func moveCustom(fromOffsets: IndexSet, toOffset: Int) {
        guard !fromOffsets.isEmpty else { return }
        mutate { $0.customRules.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    private func mutate(_ update: (inout RegexHighlightConfiguration) -> Void) {
        var next = configuration
        update(&next)
        next = next.sanitized()
        guard next != configuration else { return }
        configuration = next
        onChange(next)
    }
}
