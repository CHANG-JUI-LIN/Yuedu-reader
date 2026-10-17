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
    /// UTF-16 units (logged) or its pattern does not compile (logged by `regex(for:)`).
    static func replacing(_ rule: ReplaceRule, in content: String, limit: Int) -> String? {
        let text = content as NSString
        switch edits(of: rule, in: text, range: NSRange(location: 0, length: text.length), limit: limit) {
        case nil:
            return nil
        case .overBudget:
            logOverBudget(limit)
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
        var changed = false
        for rule in rules {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            let text = attributed.string as NSString
            let lower = min(max(0, start), text.length)
            let range = NSRange(location: lower, length: text.length - lower)
            let limit = outputLimit(for: text.length)
            let edits: [Edit]
            switch Self.edits(of: rule, in: text, range: range, limit: limit) {
            case nil:
                continue
            case .overBudget:
                logOverBudget(limit)
                continue
            case .edits(let found):
                edits = found
            }
            guard !edits.isEmpty else { continue }
            for edit in edits.reversed() {
                attributed.replaceCharacters(in: edit.range, with: edit.text)
            }
            changed = true
        }
        return changed
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
    }

    /// What `rule` does to `range` of `text`: the single place matches turn into
    /// replacement text, for both entry points. Nil when the pattern does not compile.
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
            regex.enumerateMatches(in: text as String, range: range) { match, _, stop in
                guard let match else { return }
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
                    stop.pointee = true
                    return
                }
                growth += output.utf16.count - match.range.length
                edits.append(Edit(range: match.range, text: output))
            }
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
