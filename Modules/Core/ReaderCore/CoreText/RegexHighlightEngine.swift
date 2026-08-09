import Foundation
import UIKit

enum RegexHighlightError: Error, Equatable, Sendable {
    case invalidPattern(ruleID: String, message: String)
    case patternTooLong(ruleID: String, maximum: Int)
}

enum RegexHighlightDiagnostic: Equatable, Sendable {
    case matchLimitExceeded(ruleID: String, maximum: Int)
}

struct RegexHighlightSegment: Equatable, Sendable {
    var range: NSRange
    var style: ReaderStyleRuleStyle
    var contributingRuleIDs: [String]
}

struct RegexHighlightResult: Equatable, Sendable {
    var segments: [RegexHighlightSegment]
    var diagnostics: [RegexHighlightDiagnostic]
}

/// Immutable value attached to highlighted attributed-string runs. The drawing
/// pipeline consumes it without consulting mutable settings, so a page/chunk is
/// always rendered with the same style revision it was built with.
final class RegexHighlightDecoration: NSObject, NSCopying, @unchecked Sendable {
    static let attributeKey = RegexHighlightEngine.decorationAttributeKey

    let style: ReaderStyleDecorationStyle
    let assetRevision: UInt64

    init(style: ReaderStyleDecorationStyle, assetRevision: UInt64) {
        self.style = style
        self.assetRevision = assetRevision
    }

    func copy(with zone: NSZone? = nil) -> Any { self }
}

enum RegexHighlightEngine {
    static let maximumPatternLength = 2_048
    static let maximumMatchesPerRule = 10_000
    static let decorationAttributeKey = NSAttributedString.Key("YDRegexHighlightDecoration")
    static let originalAttributesKey = NSAttributedString.Key("YDRegexHighlightOriginalAttributes")

    private static let expressionCache = RegexHighlightExpressionCache()

    static func compile(_ rule: RegexHighlightRule) throws -> NSRegularExpression {
        guard rule.pattern.utf16.count <= maximumPatternLength else {
            throw RegexHighlightError.patternTooLong(
                ruleID: rule.id,
                maximum: maximumPatternLength
            )
        }

        let key = RegexHighlightExpressionCache.Key(
            ruleID: rule.id,
            pattern: rule.pattern,
            optionRawValue: rule.options.rawValue
        )
        if let cached = expressionCache.value(for: key) {
            return cached
        }

        var options: NSRegularExpression.Options = []
        if rule.options.contains(.caseInsensitive) {
            options.insert(.caseInsensitive)
        }

        do {
            let expression = try NSRegularExpression(pattern: rule.pattern, options: options)
            return expressionCache.insertIfAbsent(expression, for: key)
        } catch {
            throw RegexHighlightError.invalidPattern(
                ruleID: rule.id,
                message: error.localizedDescription
            )
        }
    }

    static func evaluate(
        text: String,
        rules: [RegexHighlightRule],
        appearance: ReaderStyleAppearance
    ) throws -> RegexHighlightResult {
        let nsText = text as NSString
        var evaluatedMatches: [EvaluatedMatch] = []
        var diagnostics: [RegexHighlightDiagnostic] = []

        for (ruleIndex, rule) in rules.enumerated() where rule.isEnabled {
            let expression = try compile(rule)
            let outcome = matches(
                expression: expression,
                in: nsText,
                paragraphLocal: rule.options.contains(.doesNotCrossParagraph)
            )

            if outcome.exceededLimit {
                diagnostics.append(
                    .matchLimitExceeded(
                        ruleID: rule.id,
                        maximum: maximumMatchesPerRule
                    )
                )
                continue
            }

            let style = appearance == .light ? rule.lightStyle : rule.darkStyle
            evaluatedMatches.append(contentsOf: outcome.ranges.map {
                EvaluatedMatch(
                    range: $0,
                    ruleIndex: ruleIndex,
                    ruleID: rule.id,
                    style: style
                )
            })
        }

        return RegexHighlightResult(
            segments: cascade(matches: evaluatedMatches),
            diagnostics: diagnostics
        )
    }

    @discardableResult
    static func apply(
        configuration: RegexHighlightConfiguration,
        appearance: ReaderStyleAppearance,
        assetRevision: UInt64 = 0,
        to attributedString: NSMutableAttributedString
    ) throws -> RegexHighlightResult {
        restoreOriginalAttributes(in: attributedString)
        let fullRange = NSRange(location: 0, length: attributedString.length)
        if fullRange.length > 0 {
            attributedString.removeAttribute(decorationAttributeKey, range: fullRange)
        }

        guard configuration.isEnabled else {
            return RegexHighlightResult(segments: [], diagnostics: [])
        }

        let result = try evaluate(
            text: attributedString.string,
            rules: configuration.evaluationRules,
            appearance: appearance
        )

        for segment in result.segments {
            applyTextStyle(segment.style.text, range: segment.range, to: attributedString)
            if !segment.style.decoration.isEmpty {
                attributedString.addAttribute(
                    decorationAttributeKey,
                    value: RegexHighlightDecoration(
                        style: segment.style.decoration,
                        assetRevision: assetRevision
                    ),
                    range: segment.range
                )
            }
        }
        return result
    }

    private static func matches(
        expression: NSRegularExpression,
        in text: NSString,
        paragraphLocal: Bool
    ) -> (ranges: [NSRange], exceededLimit: Bool) {
        let searchRanges = paragraphLocal
            ? paragraphContentRanges(in: text)
            : [NSRange(location: 0, length: text.length)]
        var ranges: [NSRange] = []
        ranges.reserveCapacity(min(text.length, maximumMatchesPerRule))
        var exceededLimit = false

        for searchRange in searchRanges {
            guard !exceededLimit else { break }
            expression.enumerateMatches(
                in: text as String,
                options: [],
                range: searchRange
            ) { result, _, stop in
                guard let result else { return }
                if ranges.count == maximumMatchesPerRule {
                    exceededLimit = true
                    stop.pointee = true
                    return
                }
                // Zero-width matches count toward the deterministic rule limit,
                // but cannot produce an attributed-string segment.
                ranges.append(result.range)
            }
        }

        if exceededLimit {
            return ([], true)
        }
        return (ranges.filter { $0.length > 0 }, false)
    }

    private static func paragraphContentRanges(in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }

        var result: [NSRange] = []
        var cursor = 0
        while cursor < text.length {
            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            text.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            result.append(
                NSRange(
                    location: paragraphStart,
                    length: max(0, contentsEnd - paragraphStart)
                )
            )
            cursor = paragraphEnd > cursor ? paragraphEnd : cursor + 1
        }
        return result
    }

    private static func cascade(matches: [EvaluatedMatch]) -> [RegexHighlightSegment] {
        guard !matches.isEmpty else { return [] }

        var starts: [Int: [Int]] = [:]
        var ends: [Int: [Int]] = [:]
        var boundaries = Set<Int>()
        var stylesByRuleIndex: [Int: ReaderStyleRuleStyle] = [:]
        var IDsByRuleIndex: [Int: String] = [:]

        for match in matches where match.range.length > 0 {
            let lower = match.range.location
            let upper = NSMaxRange(match.range)
            guard lower >= 0, upper > lower else { continue }
            starts[lower, default: []].append(match.ruleIndex)
            ends[upper, default: []].append(match.ruleIndex)
            boundaries.insert(lower)
            boundaries.insert(upper)
            stylesByRuleIndex[match.ruleIndex] = match.style
            IDsByRuleIndex[match.ruleIndex] = match.ruleID
        }

        let sortedBoundaries = boundaries.sorted()
        guard sortedBoundaries.count >= 2 else { return [] }

        var activeCounts: [Int: Int] = [:]
        var segments: [RegexHighlightSegment] = []

        for boundaryIndex in 0..<(sortedBoundaries.count - 1) {
            let lower = sortedBoundaries[boundaryIndex]
            let upper = sortedBoundaries[boundaryIndex + 1]

            for ruleIndex in ends[lower, default: []] {
                let nextCount = (activeCounts[ruleIndex] ?? 0) - 1
                if nextCount > 0 {
                    activeCounts[ruleIndex] = nextCount
                } else {
                    activeCounts.removeValue(forKey: ruleIndex)
                }
            }
            for ruleIndex in starts[lower, default: []] {
                activeCounts[ruleIndex, default: 0] += 1
            }

            let activeRuleIndices = activeCounts.keys.sorted()
            guard upper > lower, !activeRuleIndices.isEmpty else { continue }

            var mergedStyle = ReaderStyleRuleStyle()
            var contributingIDs: [String] = []
            var seenIDs = Set<String>()
            for ruleIndex in activeRuleIndices {
                guard let style = stylesByRuleIndex[ruleIndex],
                      let ruleID = IDsByRuleIndex[ruleIndex] else { continue }
                mergedStyle.mergeCascade(style)
                if seenIDs.insert(ruleID).inserted {
                    contributingIDs.append(ruleID)
                }
            }

            let segment = RegexHighlightSegment(
                range: NSRange(location: lower, length: upper - lower),
                style: mergedStyle,
                contributingRuleIDs: contributingIDs
            )
            if let last = segments.last,
               NSMaxRange(last.range) == segment.range.location,
               last.style == segment.style,
               last.contributingRuleIDs == segment.contributingRuleIDs {
                segments[segments.count - 1].range.length += segment.range.length
            } else {
                segments.append(segment)
            }
        }

        return segments
    }

    private static func applyTextStyle(
        _ style: ReaderStyleTextStyle,
        range: NSRange,
        to attributedString: NSMutableAttributedString
    ) {
        let keys = style.overwrittenAttributeKeys
        guard !keys.isEmpty, range.length > 0 else { return }

        var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        attributedString.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            runs.append((runRange, attributes))
        }

        for run in runs {
            var present: [NSAttributedString.Key: Any] = [:]
            var absent = Set<NSAttributedString.Key>()
            for key in keys {
                if let value = run.attributes[key] {
                    present[key] = value
                } else {
                    absent.insert(key)
                }
            }
            attributedString.addAttribute(
                originalAttributesKey,
                value: RegexHighlightOriginalAttributes(present: present, absent: absent),
                range: run.range
            )

            if style.overwritesFont {
                let current = run.attributes[.font] as? UIFont
                    ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
                attributedString.addAttribute(
                    .font,
                    value: resolvedFont(from: current, style: style),
                    range: run.range
                )
            }
            if let colorHex = style.colorHex {
                attributedString.addAttribute(
                    .foregroundColor,
                    value: color(hex: colorHex),
                    range: run.range
                )
            }
            if let letterSpacing = style.letterSpacing {
                attributedString.addAttribute(
                    .kern,
                    value: NSNumber(value: letterSpacing),
                    range: run.range
                )
            }
            if let lineHeight = style.lineHeight {
                let paragraphStyle = (run.attributes[.paragraphStyle] as? NSParagraphStyle)?
                    .mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                paragraphStyle.minimumLineHeight = lineHeight
                paragraphStyle.maximumLineHeight = lineHeight
                attributedString.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: run.range
                )
            }
            if let underline = style.underline {
                setLineStyle(underline, key: .underlineStyle, range: run.range, in: attributedString)
            }
            if let strikethrough = style.strikethrough {
                setLineStyle(
                    strikethrough,
                    key: .strikethroughStyle,
                    range: run.range,
                    in: attributedString
                )
            }
        }
    }

    private static func restoreOriginalAttributes(
        in attributedString: NSMutableAttributedString
    ) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        guard fullRange.length > 0 else { return }

        var savedRuns: [(range: NSRange, saved: RegexHighlightOriginalAttributes)] = []
        attributedString.enumerateAttribute(
            originalAttributesKey,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard let saved = value as? RegexHighlightOriginalAttributes else { return }
            savedRuns.append((range, saved))
        }

        for run in savedRuns {
            for (key, value) in run.saved.present {
                attributedString.addAttribute(key, value: value, range: run.range)
            }
            for key in run.saved.absent {
                attributedString.removeAttribute(key, range: run.range)
            }
        }
        attributedString.removeAttribute(originalAttributesKey, range: fullRange)
    }

    private static func setLineStyle(
        _ enabled: Bool,
        key: NSAttributedString.Key,
        range: NSRange,
        in attributedString: NSMutableAttributedString
    ) {
        if enabled {
            attributedString.addAttribute(
                key,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        } else {
            attributedString.removeAttribute(key, range: range)
        }
    }

    private static func resolvedFont(
        from publisherFont: UIFont,
        style: ReaderStyleTextStyle
    ) -> UIFont {
        let size = CGFloat(style.fontSize ?? Double(publisherFont.pointSize))
        var font = style.fontPostScriptName.flatMap { UIFont(name: $0, size: size) }
            ?? publisherFont.withSize(size)
        var descriptor = font.fontDescriptor
        var symbolicTraits = descriptor.symbolicTraits

        if let italic = style.italic {
            if italic {
                symbolicTraits.insert(.traitItalic)
            } else {
                symbolicTraits.remove(.traitItalic)
            }
        }
        if let fontWeight = style.fontWeight {
            let weight = uiFontWeight(from: fontWeight)
            if weight.rawValue >= UIFont.Weight.semibold.rawValue {
                symbolicTraits.insert(.traitBold)
            } else {
                symbolicTraits.remove(.traitBold)
            }
            descriptor = descriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight],
            ])
        }
        if let traitDescriptor = descriptor.withSymbolicTraits(symbolicTraits) {
            descriptor = traitDescriptor
        }
        font = UIFont(descriptor: descriptor, size: max(size, 0.01))
        return font
    }

    private static func uiFontWeight(from cssWeight: Int) -> UIFont.Weight {
        switch cssWeight {
        case ..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        case 750..<850: return .heavy
        default: return .black
        }
    }

    private static func color(hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct EvaluatedMatch {
    var range: NSRange
    var ruleIndex: Int
    var ruleID: String
    var style: ReaderStyleRuleStyle
}

private final class RegexHighlightOriginalAttributes: NSObject, NSCopying, @unchecked Sendable {
    let present: [NSAttributedString.Key: Any]
    let absent: Set<NSAttributedString.Key>

    init(
        present: [NSAttributedString.Key: Any],
        absent: Set<NSAttributedString.Key>
    ) {
        self.present = present
        self.absent = absent
    }

    func copy(with zone: NSZone? = nil) -> Any { self }
}

private final class RegexHighlightExpressionCache: @unchecked Sendable {
    struct Key: Hashable {
        var ruleID: String
        var pattern: String
        var optionRawValue: Int
    }

    private let lock = NSLock()
    private var storage: [Key: NSRegularExpression] = [:]

    func value(for key: Key) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func insertIfAbsent(
        _ expression: NSRegularExpression,
        for key: Key
    ) -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage[key] {
            return existing
        }
        storage[key] = expression
        return expression
    }
}

private extension ReaderStyleRuleStyle {
    mutating func mergeCascade(_ later: ReaderStyleRuleStyle) {
        text.mergeCascade(later.text)
        decoration.mergeCascade(later.decoration)
    }
}

private extension ReaderStyleTextStyle {
    var overwritesFont: Bool {
        fontPostScriptName != nil || fontSize != nil || fontWeight != nil || italic != nil
    }

    var overwrittenAttributeKeys: Set<NSAttributedString.Key> {
        var keys = Set<NSAttributedString.Key>()
        if overwritesFont { keys.insert(.font) }
        if colorHex != nil { keys.insert(.foregroundColor) }
        if letterSpacing != nil { keys.insert(.kern) }
        if lineHeight != nil { keys.insert(.paragraphStyle) }
        if underline != nil { keys.insert(.underlineStyle) }
        if strikethrough != nil { keys.insert(.strikethroughStyle) }
        return keys
    }

    mutating func mergeCascade(_ later: ReaderStyleTextStyle) {
        if let value = later.colorHex { colorHex = value }
        if let value = later.fontPostScriptName { fontPostScriptName = value }
        if let value = later.fontSize { fontSize = value }
        if let value = later.fontWeight { fontWeight = value }
        if let value = later.italic { italic = value }
        if let value = later.letterSpacing { letterSpacing = value }
        if let value = later.lineHeight { lineHeight = value }
        if let value = later.underline { underline = value }
        if let value = later.strikethrough { strikethrough = value }
    }
}

private extension ReaderStyleDecorationStyle {
    var isEmpty: Bool {
        backgroundColorHex == nil
            && backgroundGradient == nil
            && backgroundImage == nil
            && padding == nil
            && margin == nil
            && visualGap == nil
            && (borders?.isEmpty ?? true)
            && cornerRadius == nil
            && shadows.isEmpty
            && opacity == nil
    }

    mutating func mergeCascade(_ later: ReaderStyleDecorationStyle) {
        if let value = later.backgroundColorHex { backgroundColorHex = value }
        if let value = later.backgroundGradient { backgroundGradient = value }
        if let value = later.backgroundImage { backgroundImage = value }
        if let value = later.padding { padding = value }
        if let value = later.margin { margin = value }
        if let value = later.visualGap { visualGap = value }
        if let laterBorders = later.borders {
            var mergedBorders = borders ?? [:]
            for (edge, border) in laterBorders {
                mergedBorders[edge] = border
            }
            borders = mergedBorders
        }
        if let value = later.cornerRadius { cornerRadius = value }
        shadows.append(contentsOf: later.shadows)
        if let value = later.opacity { opacity = value }
    }
}
