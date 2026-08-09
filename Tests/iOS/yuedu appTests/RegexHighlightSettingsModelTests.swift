import Foundation
import Testing
@testable import yuedu_app

@Suite("Regex highlight settings draft")
@MainActor
struct RegexHighlightSettingsModelTests {
    @Test("summary counts enabled built in and custom rules")
    func summary() {
        let model = RegexHighlightSettingsModel(configuration: fixture()) { _ in }

        #expect(model.summary.builtInCount == 5)
        #expect(model.summary.customCount == 1)
        #expect(model.summary.enabledCount == 5)
    }

    @Test("built-ins cannot delete or reorder")
    func builtInProtection() {
        let original = fixture()
        let model = RegexHighlightSettingsModel(configuration: original) { _ in }

        model.delete(ruleID: "builtin.curly-double")
        model.moveCustom(fromOffsets: IndexSet(integer: 0), toOffset: 0)

        #expect(model.configuration.rules == original.rules)
    }

    @Test("copying built in creates an enabled custom rule after built ins")
    func copyBuiltIn() throws {
        let model = RegexHighlightSettingsModel(configuration: fixture()) { _ in }
        model.copyAsCustom(ruleID: "builtin.curly-double")
        let copy = try #require(model.configuration.customRules.last)

        #expect(copy.isBuiltIn == false)
        #expect(copy.isEnabled)
        #expect(copy.pattern == "“[^”\\n]*”")
        #expect(model.configuration.evaluationRules.last?.id == copy.id)
    }

    @Test("accepted mutations persist exactly once")
    func persistsOnce() {
        var saved: [RegexHighlightConfiguration] = []
        let model = RegexHighlightSettingsModel(configuration: fixture()) { saved.append($0) }

        model.setGlobalEnabled(false)
        model.setGlobalEnabled(false)

        #expect(saved.count == 1)
        #expect(saved[0].isEnabled == false)
    }

    @Test("new editor draft does not mutate settings until accepted")
    func isolatedNewRuleDraft() {
        var saved: [RegexHighlightConfiguration] = []
        let model = RegexHighlightSettingsModel(configuration: fixture()) { saved.append($0) }
        let before = model.configuration

        let draft = model.makeCustomDraft()
        #expect(model.configuration == before)
        #expect(saved.isEmpty)

        model.update(draft)
        #expect(model.configuration.customRules.last?.id == draft.id)
        #expect(saved.count == 1)
    }

    private func fixture() -> RegexHighlightConfiguration {
        RegexHighlightConfiguration(
            isEnabled: true,
            rules: RegexHighlightRule.builtIns,
            customRules: [RegexHighlightRule.custom(name: "Custom", pattern: "x")]
        )
    }
}
