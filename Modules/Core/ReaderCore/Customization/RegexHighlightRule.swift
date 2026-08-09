import Foundation

struct RegexHighlightConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1

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
        let storedBuiltIns = Dictionary(
            rules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let builtIns = RegexHighlightRule.builtIns.map { canonical in
            guard let stored = storedBuiltIns[canonical.id] else { return canonical }
            return canonical.replacingMutableBuiltInValues(with: stored)
        }

        var occupiedIDs = Set(builtIns.map(\.id))
        let custom = customRules.map { rule -> RegexHighlightRule in
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
