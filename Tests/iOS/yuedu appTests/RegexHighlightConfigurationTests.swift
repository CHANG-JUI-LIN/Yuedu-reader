import Foundation
import Testing
@testable import yuedu_app

@Suite("Regex highlight configuration", .serialized)
struct RegexHighlightConfigurationTests {
    @Test("built-ins match the approved order patterns colors and enabled states")
    func builtIns() {
        let rules = RegexHighlightRule.builtIns

        #expect(rules.map(\.id) == [
            "builtin.curly-double", "builtin.curly-single", "builtin.corner",
            "builtin.double-corner", "builtin.prompt"
        ])
        #expect(rules.map(\.pattern) == [
            "“[^”\\n]*”", "‘[^’\\n]*’", "「[^」\\n]*」",
            "『[^』\\n]*』", "【[^】\\n]*】"
        ])
        #expect(rules.map(\.isEnabled) == [true, true, true, true, false])
        #expect(rules.map(\.lightStyle.text.colorHex) == [
            0xFF8A34, 0x3498DB, 0x49B66D, 0xAF5BCC, 0xE45151
        ])
    }

    @Test("migration keeps only the old global switch")
    func migration() {
        let enabled = RegexHighlightMigration.makeInitialConfiguration(oldGlobalEnabled: true)
        let disabled = RegexHighlightMigration.makeInitialConfiguration(oldGlobalEnabled: false)

        #expect(enabled.isEnabled)
        #expect(disabled.isEnabled == false)
        #expect(enabled.rules == RegexHighlightRule.builtIns)
        #expect(enabled.customRules.isEmpty)
        #expect(enabled.rules[0].lightStyle.text.colorHex != GlobalSettings.defaultReaderDialogueHighlightColorHex)
    }

    @Test("custom rules always evaluate after built-ins")
    func evaluationOrder() {
        let custom = RegexHighlightRule.custom(name: "custom", pattern: "x")
        let configuration = RegexHighlightConfiguration(
            isEnabled: true,
            rules: RegexHighlightRule.builtIns,
            customRules: [custom]
        )

        #expect(configuration.evaluationRules.last?.id == custom.id)
    }

    @Test("decoding a built-in restores its fixed identity and matching template")
    func builtInDecodeRestoresFixedFields() throws {
        var changed = try #require(RegexHighlightRule.builtIns.first)
        changed.name = "Tampered"
        changed.pattern = ".*"
        changed.isBuiltIn = false
        changed.isEnabled = false
        changed.lightStyle.text.colorHex = 0x123456

        let decoded = try JSONDecoder().decode(
            RegexHighlightRule.self,
            from: JSONEncoder().encode(changed)
        )

        #expect(decoded.id == "builtin.curly-double")
        #expect(decoded.name == "“對話”")
        #expect(decoded.pattern == "“[^”\\n]*”")
        #expect(decoded.isBuiltIn)
        #expect(decoded.isEnabled == false)
        #expect(decoded.lightStyle.text.colorHex == 0x123456)
    }

    @Test("sanitizing configuration restores every built-in once in fixed order")
    func configurationSanitization() {
        var changed = RegexHighlightRule.builtIns
        changed.removeFirst()
        changed.reverse()
        changed.append(changed[0])

        let configuration = RegexHighlightConfiguration(
            version: 99,
            isEnabled: true,
            rules: changed,
            customRules: []
        ).sanitized()

        #expect(configuration.version == RegexHighlightConfiguration.currentVersion)
        #expect(configuration.rules.map(\.id) == RegexHighlightRule.builtIns.map(\.id))
    }

    @Test("version one invisible default gradients migrate before reader rendering")
    func legacyGradientMigration() throws {
        var rule = RegexHighlightRule.custom(name: "Dialogue", pattern: "dialogue")
        rule.lightStyle.decoration.backgroundGradient = ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                .init(colorHex: 0xFFFFFF, location: 0),
                .init(colorHex: 0xD8E8FF, location: 1),
            ]
        )
        rule.darkStyle.decoration.backgroundGradient = ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                .init(colorHex: 0x1C1C1E, location: 0),
                .init(colorHex: 0x3A4658, location: 1),
            ]
        )
        let stored = RegexHighlightConfiguration(
            version: 1,
            isEnabled: true,
            rules: RegexHighlightRule.builtIns,
            customRules: [rule]
        )

        let migrated = stored.sanitized()
        let migratedRule = try #require(migrated.customRules.first)

        #expect(migrated.version == 2)
        #expect(migratedRule.lightStyle.decoration.backgroundGradient?.stops.first?.colorHex == 0xFFE1C7)
        #expect(migratedRule.darkStyle.decoration.backgroundGradient?.stops.first?.colorHex == 0x5A321C)
    }

    @Test("current configurations preserve an intentionally selected legacy color pair")
    func currentGradientIsNotMigrated() throws {
        var rule = RegexHighlightRule.custom(name: "Dialogue", pattern: "dialogue")
        let intentionalGradient = ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                .init(colorHex: 0xFFFFFF, location: 0),
                .init(colorHex: 0xD8E8FF, location: 1),
            ]
        )
        rule.lightStyle.decoration.backgroundGradient = intentionalGradient
        let stored = RegexHighlightConfiguration(
            version: RegexHighlightConfiguration.currentVersion,
            isEnabled: true,
            rules: RegexHighlightRule.builtIns,
            customRules: [rule]
        )

        let sanitizedRule = try #require(stored.sanitized().customRules.first)

        #expect(sanitizedRule.lightStyle.decoration.backgroundGradient == intentionalGradient)
    }
}
