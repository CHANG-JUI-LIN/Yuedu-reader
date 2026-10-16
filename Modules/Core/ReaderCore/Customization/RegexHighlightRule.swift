import Foundation

struct RegexHighlightConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var isEnabled: Bool
    var rules: [RegexHighlightRule]
    var customRules: [RegexHighlightRule]

    init(
        version: Int = RegexHighlightConfiguration.currentVersion,
        isEnabled: Bool,
        rules: [RegexHighlightRule],
        customRules: [RegexHighlightRule]
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.rules = rules
        self.customRules = customRules
    }

    var evaluationRules: [RegexHighlightRule] {
        rules + customRules
    }

    static let disabled = RegexHighlightConfiguration(
        isEnabled: false,
        rules: RegexHighlightRule.builtIns,
        customRules: []
    )

    func sanitized() -> RegexHighlightConfiguration {
        let shouldMigrateLegacyGradientDefaults = version < 2
        let sourceRules = shouldMigrateLegacyGradientDefaults
            ? rules.map { $0.migratingLegacyGradientDefaults() }
            : rules
        let sourceCustomRules = shouldMigrateLegacyGradientDefaults
            ? customRules.map { $0.migratingLegacyGradientDefaults() }
            : customRules
        let storedBuiltIns = Dictionary(
            sourceRules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let builtIns = RegexHighlightRule.builtIns.map { canonical in
            guard let stored = storedBuiltIns[canonical.id] else { return canonical }
            return canonical.replacingMutableBuiltInValues(with: stored)
        }

        var occupiedIDs = Set(builtIns.map(\.id))
        let custom = sourceCustomRules.map { rule -> RegexHighlightRule in
            var sanitized = rule.sanitizedAsCustom()
            while occupiedIDs.contains(sanitized.id) {
                sanitized.id = UUID().uuidString
            }
            occupiedIDs.insert(sanitized.id)
            return sanitized
        }

        return RegexHighlightConfiguration(
            version: Self.currentVersion,
            isEnabled: isEnabled,
            rules: builtIns,
            customRules: custom
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case rules
        case customRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        rules = try container.decodeIfPresent([RegexHighlightRule].self, forKey: .rules)
            ?? RegexHighlightRule.builtIns
        customRules = try container.decodeIfPresent([RegexHighlightRule].self, forKey: .customRules) ?? []
    }
}

enum RegexHighlightGradientDefaults {
    static func visible(for appearance: ReaderStyleAppearance) -> ReaderStyleGradient {
        ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                ReaderStyleGradientStop(
                    colorHex: appearance == .light ? 0xFFE1C7 : 0x5A321C,
                    location: 0
                ),
                ReaderStyleGradientStop(
                    colorHex: appearance == .light ? 0xD8E8FF : 0x3A4658,
                    location: 1
                ),
            ]
        )
    }

    fileprivate static func legacyInvisible(
        for appearance: ReaderStyleAppearance
    ) -> ReaderStyleGradient {
        ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                ReaderStyleGradientStop(
                    colorHex: appearance == .light ? 0xFFFFFF : 0x1C1C1E,
                    location: 0
                ),
                ReaderStyleGradientStop(
                    colorHex: appearance == .light ? 0xD8E8FF : 0x3A4658,
                    location: 1
                ),
            ]
        )
    }
}

struct RegexHighlightRule: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var pattern: String
    var isEnabled: Bool
    var isBuiltIn: Bool
    var options: RegexHighlightOptions
    var lightStyle: ReaderStyleRuleStyle
    var darkStyle: ReaderStyleRuleStyle

    init(
        id: String,
        name: String,
        pattern: String,
        isEnabled: Bool,
        isBuiltIn: Bool,
        options: RegexHighlightOptions,
        lightStyle: ReaderStyleRuleStyle,
        darkStyle: ReaderStyleRuleStyle
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.options = options
        self.lightStyle = lightStyle
        self.darkStyle = darkStyle
    }

    static let builtIns: [RegexHighlightRule] = [
        builtIn(
            id: "builtin.curly-double",
            name: "“對話”",
            pattern: "“[^”\\n]*”",
            colorHex: 0xFF8A34
        ),
        builtIn(
            id: "builtin.curly-single",
            name: "‘對話’",
            pattern: "‘[^’\\n]*’",
            colorHex: 0x3498DB
        ),
        builtIn(
            id: "builtin.corner",
            name: "「對話」",
            pattern: "「[^」\\n]*」",
            colorHex: 0x49B66D
        ),
        builtIn(
            id: "builtin.double-corner",
            name: "『對話』",
            pattern: "『[^』\\n]*』",
            colorHex: 0xAF5BCC
        ),
        builtIn(
            id: "builtin.prompt",
            name: "【提示】",
            pattern: "【[^】\\n]*】",
            colorHex: 0xE45151,
            isEnabled: false
        )
    ]

    static func custom(name: String, pattern: String) -> RegexHighlightRule {
        RegexHighlightRule(
            id: UUID().uuidString,
            name: name,
            pattern: pattern,
            isEnabled: true,
            isBuiltIn: false,
            options: [.doesNotCrossParagraph],
            lightStyle: .init(),
            darkStyle: .init()
        ).sanitizedAsCustom()
    }

    func copyAsCustom() -> RegexHighlightRule {
        RegexHighlightRule(
            id: UUID().uuidString,
            name: name,
            pattern: pattern,
            isEnabled: true,
            isBuiltIn: false,
            options: options,
            lightStyle: lightStyle,
            darkStyle: darkStyle
        ).sanitizedAsCustom()
    }

    func sanitized() -> RegexHighlightRule {
        if let canonical = Self.builtIns.first(where: { $0.id == id }) {
            return canonical.replacingMutableBuiltInValues(with: self)
        }
        return sanitizedAsCustom()
    }

    fileprivate func sanitizedAsCustom() -> RegexHighlightRule {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return RegexHighlightRule(
            id: UUID(uuidString: id)?.uuidString ?? UUID().uuidString,
            name: trimmedName.isEmpty ? "Custom" : trimmedName,
            pattern: pattern,
            isEnabled: isEnabled,
            isBuiltIn: false,
            options: options.sanitized,
            lightStyle: lightStyle,
            darkStyle: darkStyle
        )
    }

    fileprivate func replacingMutableBuiltInValues(
        with stored: RegexHighlightRule
    ) -> RegexHighlightRule {
        var result = self
        result.isEnabled = stored.isEnabled
        result.options = stored.options.sanitized
        result.lightStyle = stored.lightStyle
        result.darkStyle = stored.darkStyle
        return result
    }

    fileprivate func migratingLegacyGradientDefaults() -> RegexHighlightRule {
        var result = self
        result.lightStyle = lightStyle.migratingLegacyGradientDefault(for: .light)
        result.darkStyle = darkStyle.migratingLegacyGradientDefault(for: .dark)
        return result
    }

    private static func builtIn(
        id: String,
        name: String,
        pattern: String,
        colorHex: UInt32,
        isEnabled: Bool = true
    ) -> RegexHighlightRule {
        let style = ReaderStyleRuleStyle(
            text: ReaderStyleTextStyle(colorHex: colorHex),
            decoration: .init()
        )
        return RegexHighlightRule(
            id: id,
            name: name,
            pattern: pattern,
            isEnabled: isEnabled,
            isBuiltIn: true,
            options: [.doesNotCrossParagraph],
            lightStyle: style,
            darkStyle: style
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case pattern
        case isEnabled
        case isBuiltIn
        case options
        case lightStyle
        case darkStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id) ?? ""

        if let canonical = Self.builtIns.first(where: { $0.id == decodedID }) {
            self = canonical
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
                ?? canonical.isEnabled
            options = try container.decodeIfPresent(RegexHighlightOptions.self, forKey: .options)?
                .sanitized ?? canonical.options
            lightStyle = try container.decodeIfPresent(ReaderStyleRuleStyle.self, forKey: .lightStyle)
                ?? canonical.lightStyle
            darkStyle = try container.decodeIfPresent(ReaderStyleRuleStyle.self, forKey: .darkStyle)
                ?? canonical.darkStyle
            return
        }

        id = UUID(uuidString: decodedID)?.uuidString ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isBuiltIn = false
        options = try container.decodeIfPresent(RegexHighlightOptions.self, forKey: .options)?
            .sanitized ?? [.doesNotCrossParagraph]
        lightStyle = try container.decodeIfPresent(ReaderStyleRuleStyle.self, forKey: .lightStyle) ?? .init()
        darkStyle = try container.decodeIfPresent(ReaderStyleRuleStyle.self, forKey: .darkStyle) ?? .init()
        self = sanitizedAsCustom()
    }
}

private extension ReaderStyleRuleStyle {
    func migratingLegacyGradientDefault(
        for appearance: ReaderStyleAppearance
    ) -> ReaderStyleRuleStyle {
        guard decoration.backgroundGradient == RegexHighlightGradientDefaults.legacyInvisible(
            for: appearance
        ) else {
            return self
        }

        var result = self
        result.decoration.backgroundGradient = RegexHighlightGradientDefaults.visible(for: appearance)
        return result
    }
}

struct RegexHighlightOptions: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let caseInsensitive = RegexHighlightOptions(rawValue: 1 << 0)
    static let doesNotCrossParagraph = RegexHighlightOptions(rawValue: 1 << 1)

    fileprivate var sanitized: RegexHighlightOptions {
        RegexHighlightOptions(rawValue: rawValue & Self.knownMask)
    }

    private static let knownMask = caseInsensitive.rawValue | doesNotCrossParagraph.rawValue
}

enum RegexHighlightMigration {
    static func makeInitialConfiguration(
        oldGlobalEnabled: Bool
    ) -> RegexHighlightConfiguration {
        RegexHighlightConfiguration(
            isEnabled: oldGlobalEnabled,
            rules: RegexHighlightRule.builtIns,
            customRules: []
        )
    }
}

extension RegexHighlightConfiguration {
    /// The user's rules as they stand, plus imported ones (decided 2026-10-11): Reeden layers
    /// a theme's bound rules over its global ones. A user with highlighting switched off had
    /// no rule showing, so in that case their rules stay off and only the imported ones show.
    ///
    /// `replacingSameText` is a highlight pack's import (decided 2026-10-12): the pack is
    /// imported to be worn, so an existing rule marking the same text is switched off rather
    /// than painted under it. The same text, not the same pattern (2026-10-15): a pack seldom
    /// uses the built-ins' patterns — 十字架's one rule marks “…”, 「…」 and 『…』 — and the
    /// built-ins' boxes were painted under its frames.
    func addingImported(
        _ rules: [RegexHighlightRule],
        replacingSameText: Bool = false
    ) -> RegexHighlightConfiguration {
        var configuration = self
        // Importing the same pack again replaces its rules rather than stacking a second
        // copy (ids are fresh per parse, so compare what the rule does).
        configuration.customRules.removeAll { existing in
            rules.contains { $0.hasSameEffect(as: existing) }
        }
        if !isEnabled, rules.contains(where: \.isEnabled) {
            configuration.isEnabled = true
            for index in configuration.rules.indices { configuration.rules[index].isEnabled = false }
            for index in configuration.customRules.indices {
                configuration.customRules[index].isEnabled = false
            }
        }
        if replacingSameText {
            let worn = RegexHighlightImportOverlap(worn: rules.filter(\.isEnabled))
            for index in configuration.rules.indices where worn.marksSameText(as: configuration.rules[index]) {
                configuration.rules[index].isEnabled = false
            }
            for index in configuration.customRules.indices
            where worn.marksSameText(as: configuration.customRules[index]) {
                configuration.customRules[index].isEnabled = false
            }
        }
        configuration.customRules += rules
        return configuration.sanitized()
    }
}

/// What a highlight pack's worn rules mark, to find the rules already there that mark the same
/// text. No book is at hand on import, so the rules are tried on `probe`: dialogue and notes
/// as books set them, which is what such packs are made for.
struct RegexHighlightImportOverlap {
    /// One paragraph each.
    static let probe = [
        "他問：“你今天怎麼這麼早？”",
        "她低聲說：‘別出聲。’",
        "「走吧。」",
        "『這是誰的書？』",
        "【系統提示：獲得青銅劍 ×1】",
        "\"Where are you going?\"",
        "\"Not yet,\" she said, 'not yet.'",
        "《紅樓夢》（未完）",
    ].joined(separator: "\n\n")

    private let patterns: Set<String>
    private let marks: [NSRange]

    init(worn: [RegexHighlightRule]) {
        patterns = Set(worn.map(\.pattern))
        marks = worn.flatMap(Self.marks(of:))
    }

    /// Whether `rule` is on and marks text a worn rule marks: it has a worn rule's pattern, or
    /// it marks some of `probe` that one does.
    func marksSameText(as rule: RegexHighlightRule) -> Bool {
        guard rule.isEnabled else { return false }
        if patterns.contains(rule.pattern) { return true }
        return Self.marks(of: rule).contains { mark in
            marks.contains { NSIntersectionRange($0, mark).length > 0 }
        }
    }

    private static func marks(of rule: RegexHighlightRule) -> [NSRange] {
        do {
            return try RegexHighlightEngine.matchRanges(of: rule, in: probe)
        } catch {
            // A pattern that does not compile marks no text anywhere.
            AppLogger.render("highlight import: rule not compiled", error: error, context: ["rule": rule.id])
            return []
        }
    }
}

extension RegexHighlightRule {
    /// Same name, pattern, options and both styles — id and on/off state aside.
    func hasSameEffect(as other: RegexHighlightRule) -> Bool {
        name == other.name && pattern == other.pattern && options == other.options
            && lightStyle == other.lightStyle && darkStyle == other.darkStyle
    }
}
