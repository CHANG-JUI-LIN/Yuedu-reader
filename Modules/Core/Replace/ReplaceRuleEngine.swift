import Foundation
import os

/// Applies a list of `ReplaceRule` objects to a string.
///
/// Used after the book-source's per-source `##` replacement rules so
/// user-configured global rules run last.
///
/// Thread-safe: NSRegularExpression objects are reused via a simple cache.
enum ReplaceRuleEngine {

    // LRU-lite cache keyed by pattern string.
    private static let regexCache = OSAllocatedUnfairLock(initialState: [String: NSRegularExpression]())

    /// Apply all `rules` to `content` in order and return the result.
    static func apply(_ rules: [ReplaceRule], to content: String) -> String {
        var output = content
        for rule in rules {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            output = apply(rule, to: output)
        }
        return output
    }

    /// Apply a single rule to `content`.
    static func apply(_ rule: ReplaceRule, to content: String) -> String {
        guard !rule.pattern.isEmpty else { return content }
        return replacing(rule, in: content, limit: outputLimit(for: content.utf16.count)) ?? content
    }

    /// `content` with `rule` applied, or nil when the rule's output would pass `limit`
    /// UTF-16 units (logged), its search ran past `regexTimeout` (logged), or its pattern
    /// does not compile (logged by `regex(for:)`).
    static func replacing(_ rule: ReplaceRule, in content: String, limit: Int) -> String? {
        let text = content as NSString
        switch edits(of: rule, in: text, range: NSRange(location: 0, length: text.length), limit: limit) {
        case nil:
            return nil
        case .overBudget:
            logOverBudget(limit)
            return nil
        case .timedOut:
            logTimedOut(rule)
            return nil
        case .edits(let edits):
            guard !edits.isEmpty else { return content }
            let output = NSMutableString(capacity: text.length)
            var cursor = 0
            for edit in edits {
                output.append(text.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)))
                output.append(edit.text)
                cursor = NSMaxRange(edit.range)
            }
            output.append(text.substring(from: cursor))
            return output as String
        }
    }

    // MARK: - Private

    /// Reject expansion before allocating it. A zero-width or broad rule can otherwise
    /// grow a chapter until Foundation aborts the entire process. The chapter is kept as
    /// it was only when this externally supplied rule would exceed the budget; remove the
    /// budget only when the pipeline streams its output.
    private static func outputLimit(for length: Int) -> Int {
        max(length, 8 * 1024 * 1024)
    }

    private static func logOverBudget(_ limit: Int) {
        AppLogger.error("Replace rule output exceeds chapter budget", context: ["limit": "\(limit)"])
    }

    /// Names the rule, so the 替換規則 to fix can be found; `RegexMatching` has already
    /// logged the pattern and the time it took.
    private static func logTimedOut(_ rule: ReplaceRule) {
        AppLogger.error("Replace rule skipped at its timeout", context: [
            "rule": rule.name,
            "id": rule.id,
            "timeoutMs": "\(Int(regexTimeout * 1000))",
        ])
    }

    /// The compiled rule, shared by both entry points so a string and an attributed string
    /// see exactly the same options (`anchorsMatchLines`).
    private static func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.withLock({ $0[pattern] }) {
            return cached
        }
        let compiled: NSRegularExpression
        do {
            compiled = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        } catch {
            AppLogger.error("Replace rule pattern does not compile", context: [
                "pattern": String(pattern.prefix(120)),
                "error": error.localizedDescription,
            ])
            return nil
        }
        regexCache.withLock { cache in
            if cache.count > 64 { cache.removeAll() } // simple eviction
            cache[pattern] = compiled
        }
        return compiled
    }

    /// How long one rule may search one chapter: Legado's `ReplaceRule.timeoutMillisecond`
    /// default (3000 ms in legado, Sigma and MD3). A rule that runs out is skipped for that
    /// chapter and logged; Legado instead disables the rule for good and shows the error in
    /// place of the chapter.
    static let regexTimeout: TimeInterval = 3

    /// `ruleEdits(_:in:from:)` on a cooperative thread, for callers on the main actor: each
    /// rule may take up to `regexTimeout`, and several slow rules on the main thread would
    /// still reach the scene-update watchdog (Crashlytics 1dbb0353). Only the string and the
    /// edits cross; the caller replays them onto its attributed text with `replay(_:on:)`.
    @concurrent
    static func ruleEditsOffMain(_ rules: [ReplaceRule], in string: String, from start: Int) async -> [[Edit]] {
        ruleEdits(rules, in: string, from: start)
    }

    /// `apply(_:to:)` on a cooperative thread, for callers on the main actor.
    @concurrent
    static func applyingOffMain(_ rules: [ReplaceRule], to content: String) async -> String {
        apply(rules, to: content)
    }

    // MARK: - Attributed text

    /// Applies `rules` to the text of `attributed` from `start` to its end, in place, with
    /// exactly the semantics of `apply(_:to:)` — same regex options, same `$n` template
    /// syntax, same output budget. Each replacement takes the attributes of the text it
    /// replaces, so the reader's styling survives.
    ///
    /// This is how the online reader applies rules at display time. It used to carry its
    /// own copy of this loop, which had drifted three ways: `$1` became the literal "1",
    /// `^`/`$` matched only the chapter's ends, and a rule whose replacement had the same
    /// length as its match ("永夜"→"長夜") was discarded as "no change".
    /// - Returns: whether any rule matched.
    @discardableResult
    static func apply(
        _ rules: [ReplaceRule],
        to attributed: NSMutableAttributedString,
        from start: Int
    ) -> Bool {
        replay(ruleEdits(rules, in: attributed.string, from: start), on: attributed)
    }

    /// What `rules` do to `string` from `start` to its end: one list of edits per rule that
    /// matched, in rule order, each against the text the rules before it left. Plain strings
    /// and edits only, so the regex work can run anywhere and the attributed text it applies
    /// to stays where it lives.
    static func ruleEdits(_ rules: [ReplaceRule], in string: String, from start: Int) -> [[Edit]] {
        let text = NSMutableString(string: string)
        var result: [[Edit]] = []
        for rule in rules {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            let lower = min(max(0, start), text.length)
            let range = NSRange(location: lower, length: text.length - lower)
            let limit = outputLimit(for: text.length)
            switch edits(of: rule, in: text, range: range, limit: limit) {
            case nil:
                continue
            case .overBudget:
                logOverBudget(limit)
                continue
            case .timedOut:
                logTimedOut(rule)
                continue
            case .edits(let found):
                guard !found.isEmpty else { continue }
                for edit in found.reversed() {
                    text.replaceCharacters(in: edit.range, with: edit.text)
                }
                result.append(found)
            }
        }
        return result
    }

    /// Applies `ruleEdits` to `attributed` in order. Each replacement takes the attributes of
    /// the text it replaces. Returns whether anything changed.
    @discardableResult
    static func replay(_ ruleEdits: [[Edit]], on attributed: NSMutableAttributedString) -> Bool {
        for edits in ruleEdits {
            for edit in edits.reversed() {
                attributed.replaceCharacters(in: edit.range, with: edit.text)
            }
        }
        return !ruleEdits.isEmpty
    }

    struct Edit {
        let range: NSRange
        let text: String
    }

    enum RuleEdits {
        case edits([Edit])
        /// The rule's output would pass the budget. Enumeration stopped at the match that
        /// passed it, after `scanned` matches.
        case overBudget(scanned: Int)
        /// The regex search ran past `regexTimeout` and was stopped; the rule does nothing.
        case timedOut
    }

    /// What `rule` does to `range` of `text`: the single place matches turn into
    /// replacement text, for both entry points. Nil when the pattern does not compile.
    /// A regex search runs through `RegexMatching`, stopped at `regexTimeout`.
    ///
    /// The output is counted as it is produced, and enumeration stops at the first match
    /// that would take it past `limit` UTF-16 units. Output only grows from left to right,
    /// so the first prefix past the limit is where the whole would be past it too. The
    /// display-time path used to build every replacement first and check the total after,
    /// so a broad rule held matches × template in memory before being refused: the
    /// out-of-memory abort the budget exists to prevent (Organizer, 2.0.7 (104)).
    static func edits(of rule: ReplaceRule, in text: NSString, range: NSRange, limit: Int) -> RuleEdits? {
        var edits: [Edit] = []
        // Output length minus input length, over the matches accepted so far.
        var growth = 0
        var scanned = 0
        var exceeded = false
        if rule.isRegex {
            guard let regex = regex(for: rule.pattern) else { return nil }
            let parts = templateParts(rule.replacement, captureCount: regex.numberOfCaptureGroups)
            let completed = RegexMatching.enumerateMatches(
                of: regex, in: text as String, range: range, timeout: regexTimeout
            ) { match, stop in
                scanned += 1
                // The output so far ends where this match starts.
                var length = match.range.location + growth
                var output = ""
                func append(_ count: Int, _ piece: () -> String) -> Bool {
                    guard length + count <= limit else { return false }
                    length += count
                    output += piece()
                    return true
                }
                var fits = true
                for part in parts where fits {
                    switch part {
                    case .literal(let literal):
                        fits = append(literal.utf16.count) { literal }
                    case .capture(let group):
                        guard group < match.numberOfRanges else { continue }
                        let captured = match.range(at: group)
                        guard captured.location != NSNotFound else { continue }
                        fits = append(captured.length) { text.substring(with: captured) }
                    }
                }
                guard fits else {
                    exceeded = true
                    stop = true
                    return
                }
                growth += output.utf16.count - match.range.length
                edits.append(Edit(range: match.range, text: output))
            }
            guard completed else { return .timedOut }
        } else {
            let replacementLength = rule.replacement.utf16.count
            var searchRange = range
            while searchRange.length > 0 {
                let found = text.range(of: rule.pattern, options: [], range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                scanned += 1
                guard found.location + growth + replacementLength <= limit else {
                    exceeded = true
                    break
                }
                growth += replacementLength - found.length
                edits.append(Edit(range: found, text: rule.replacement))
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: NSMaxRange(range) - next)
            }
        }
        guard !exceeded, text.length + growth <= limit else { return .overBudget(scanned: scanned) }
        return .edits(edits)
    }

    private enum TemplatePart {
        case literal(String)
        case capture(Int)
    }

    /// Foundation already uses Legado's $0/$1 syntax. Backslashes escape the
    /// next character; converting $1 to \1 made it the literal character 1.
    private static func templateParts(_ template: String, captureCount: Int) -> [TemplatePart] {
        let units = Array(template.utf16)
        let maxDigits = String(captureCount).count
        var parts: [TemplatePart] = []
        var literal: [UInt16] = []
        var index = 0
        func flush() {
            if !literal.isEmpty {
                parts.append(.literal(String(decoding: literal, as: UTF16.self)))
                literal.removeAll(keepingCapacity: true)
            }
        }
        while index < units.count {
            let unit = units[index]
            index += 1
            if unit == 92, index < units.count {
                literal.append(units[index])
                index += 1
            } else if unit == 36, index < units.count, (48...57).contains(units[index]) {
                flush()
                var group = 0
                var digits = 0
                while index < units.count, digits < maxDigits, (48...57).contains(units[index]) {
                    group = group * 10 + Int(units[index] - 48)
                    index += 1
                    digits += 1
                }
                parts.append(.capture(group))
            } else if unit != 92 {
                literal.append(unit)
            }
        }
        flush()
        return parts
    }
}
