import Foundation

// MARK: - Rule Debug Event

/// Structured debug event emitted at each pipeline step inside ModernRuleEngine.
/// Mirrors the log nodes that Legado's AnalyzeRule emits during debugging,
/// making it possible to do diff-driven alignment between iOS and Android outputs.
///
/// Event flow for a single rule evaluation:
///   contentSet → rulesParsed → [for each segment: beforeExtract → afterExtract
///                                 → regexApplied → jsExecuted] → finalResult
enum RuleDebugEvent {

    // MARK: Content

    /// Content was loaded into the engine.
    case contentSet(
        contentType: String,       // "HTML" / "JSON" / "Elements" / "String"
        length: Int,               // character count
        preview: String,           // first 200 chars
        baseUrl: String
    )

    // MARK: Rule Parsing

    /// Rule string was split into SourceRule segments.
    case rulesParsed(
        ruleStr: String,           // original rule string
        segments: [RuleSegmentInfo]
    )

    struct RuleSegmentInfo: Sendable {
        let index: Int
        let mode: String           // "css" / "xpath" / "json" / "js" / "regex" / "default"
        let rule: String
        let replacePattern: String
    }

    // MARK: Extraction

    /// Before running an extractor on a segment.
    case beforeExtract(
        segmentIndex: Int,
        mode: String,
        qualifiedRule: String,
        inputPreview: String       // first 200 chars of input content
    )

    /// After running an extractor — value result.
    case afterExtractValue(
        segmentIndex: Int,
        result: String             // extracted string
    )

    /// After running an extractor — list result.
    case afterExtractList(
        segmentIndex: Int,
        count: Int,
        items: [String]            // first 10 items
    )

    // MARK: Regex Post-Processing

    /// Regex replacement was applied to the extracted value.
    case regexApplied(
        segmentIndex: Int,
        pattern: String,
        replacement: String,
        before: String,
        after: String
    )

    // MARK: JavaScript

    /// A JS segment was evaluated.
    case jsExecuted(
        segmentIndex: Int,
        script: String,            // first 300 chars of script
        inputPreview: String,
        result: String             // result string
    )

    // MARK: Final

    /// Final result after all segments processed.
    case finalResult(
        value: String,
        elapsedMs: Double
    )

    case finalResultList(
        values: [String],
        elapsedMs: Double
    )

    // MARK: Error

    case extractionError(
        segmentIndex: Int,
        mode: String,
        rule: String,
        error: String
    )
}

// MARK: - Legado-Compatible Log Line

extension RuleDebugEvent {

    /// Format the event as a log line that can be visually compared with Legado's debug output.
    /// Legado uses: "[Rule Debug] >> {step}: {value}"
    var legadoStyleLog: String {
        switch self {
        case let .contentSet(type, length, preview, url):
            return "[Raw Data] type=\(type) length=\(length) url=\(url)\n  ↳ \(preview.prefix(200))"

        case let .rulesParsed(ruleStr, segments):
            let segs = segments.map { "    [\($0.index)] \($0.mode): \($0.rule.prefix(80))" }
                .joined(separator: "\n")
            return "[Rule Parsed] \"\(ruleStr.prefix(100))\"\n\(segs)"

        case let .beforeExtract(idx, mode, rule, input):
            return "[Before Extract #\(idx)] mode=\(mode) rule=\(rule.prefix(80))\n  ↳ input: \(input.prefix(100))"

        case let .afterExtractValue(idx, result):
            return "[String Extracted #\(idx)] → \"\(result.prefix(200))\""

        case let .afterExtractList(idx, count, items):
            let preview = items.prefix(5).enumerated().map { "  [\($0.offset)] \($0.element.prefix(80))" }
                .joined(separator: "\n")
            return "[Nodes Extracted #\(idx)] count=\(count)\n\(preview)"

        case let .regexApplied(idx, pattern, replacement, before, after):
            return "[Regex Applied #\(idx)] /\(pattern.prefix(60))/ → \"\(replacement.prefix(40))\"\n  before: \(before.prefix(100))\n  after:  \(after.prefix(100))"

        case let .jsExecuted(idx, script, input, result):
            return "[JS #\(idx)]\n  script: \(script.prefix(200))\n  input:  \(input.prefix(80))\n  result: \(result.prefix(200))"

        case let .finalResult(value, ms):
            return "[Final Result] \"\(value.prefix(200))\" (\(String(format: "%.1f", ms))ms)"

        case let .finalResultList(values, ms):
            let preview = values.prefix(10).enumerated().map { "  [\($0.offset)] \($0.element.prefix(80))" }
                .joined(separator: "\n")
            return "[Final List] count=\(values.count) (\(String(format: "%.1f", ms))ms)\n\(preview)"

        case let .extractionError(idx, mode, rule, error):
            return "[ERROR #\(idx)] mode=\(mode) rule=\(rule.prefix(60))\n  ⚠️ \(error)"
        }
    }
}
