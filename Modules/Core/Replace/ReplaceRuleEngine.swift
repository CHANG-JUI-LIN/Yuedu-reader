import Foundation

/// Applies a list of `ReplaceRule` objects to a string.
///
/// Used after the book-source's per-source `##` replacement rules so
/// user-configured global rules run last.
///
/// Thread-safe: NSRegularExpression objects are reused via a simple cache.
enum ReplaceRuleEngine {

    // LRU-lite cache keyed by pattern string.
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

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
        if rule.isRegex {
            return applyRegex(pattern: rule.pattern,
                              replacement: rule.replacement,
                              to: content)
        } else {
            return content.replacingOccurrences(of: rule.pattern, with: rule.replacement)
        }
    }

    // MARK: - Private

    private static func applyRegex(pattern: String, replacement: String, to content: String) -> String {
        guard !pattern.isEmpty, let regex = regex(for: pattern) else { return content }

        // Reject expansion before allocating it. A zero-width or broad rule can
        // otherwise grow a chapter until Foundation aborts the entire process.
        // Keep the original chapter only when this externally supplied rule would
        // exceed the budget; remove this guard only when the pipeline streams output.
        let limit = max(content.utf16.count, 8 * 1024 * 1024)
        guard let output = boundedReplacement(regex, template: replacement, content: content, limit: limit) else {
            AppLogger.error("Replace rule output exceeds chapter budget", context: ["limit": "\(limit)"])
            return content
        }
        return output
    }

    /// The compiled rule, shared by both entry points so a string and an attributed string
    /// see exactly the same options (`anchorsMatchLines`).
    private static func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        if let cached = regexCache[pattern] {
            lock.unlock()
            return cached
        }
        lock.unlock()
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
        lock.lock()
        if regexCache.count > 64 { regexCache.removeAll() } // simple eviction
        regexCache[pattern] = compiled
        lock.unlock()
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
            let edits = rule.isRegex
                ? regexEdits(rule, in: text, range: range)
                : literalEdits(rule, in: text, range: range)
            guard let edits, !edits.isEmpty else { continue }

            // Same budget as the string path: a zero-width or broad rule must not grow a
            // chapter until Foundation aborts.
            let limit = max(text.length, 8 * 1024 * 1024)
            let grown = edits.reduce(text.length) { $0 - $1.range.length + ($1.text as NSString).length }
            guard grown <= limit else {
                AppLogger.error("Replace rule output exceeds chapter budget", context: ["limit": "\(limit)"])
                continue
            }
            for edit in edits.reversed() {
                attributed.replaceCharacters(in: edit.range, with: edit.text)
            }
            changed = true
        }
        return changed
    }

    private struct Edit {
        let range: NSRange
        let text: String
    }

    private static func regexEdits(_ rule: ReplaceRule, in text: NSString, range: NSRange) -> [Edit]? {
        guard let regex = regex(for: rule.pattern) else { return nil }
        let parts = templateParts(rule.replacement, captureCount: regex.numberOfCaptureGroups)
        var edits: [Edit] = []
        regex.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            var output = ""
            for part in parts {
                switch part {
                case .literal(let literal):
                    output += literal
                case .capture(let group):
                    guard group < match.numberOfRanges else { continue }
                    let captured = match.range(at: group)
                    if captured.location != NSNotFound { output += text.substring(with: captured) }
                }
            }
            edits.append(Edit(range: match.range, text: output))
        }
        return edits
    }

    private static func literalEdits(_ rule: ReplaceRule, in text: NSString, range: NSRange) -> [Edit] {
        var edits: [Edit] = []
        var searchRange = range
        while searchRange.length > 0 {
            let found = text.range(of: rule.pattern, options: [], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            edits.append(Edit(range: found, text: rule.replacement))
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: NSMaxRange(range) - next)
        }
        return edits
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

    static func boundedReplacement(
        _ regex: NSRegularExpression, template: String, content: String, limit: Int
    ) -> String? {
        guard template.utf16.count <= limit else { return nil }
        let parts = templateParts(template, captureCount: regex.numberOfCaptureGroups)
        let source = content as NSString
        let output = NSMutableString()
        var cursor = 0
        var remaining = limit
        var exceeded = false
        func appendRange(_ range: NSRange) {
            guard range.location != NSNotFound else { return }
            guard range.length <= remaining else { exceeded = true; return }
            remaining -= range.length
            output.append(source.substring(with: range))
        }
        regex.enumerateMatches(in: content, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match else { return }
            appendRange(NSRange(location: cursor, length: match.range.location - cursor))
            for part in parts where !exceeded {
                switch part {
                case .literal(let text):
                    guard text.utf16.count <= remaining else { exceeded = true; break }
                    remaining -= text.utf16.count
                    output.append(text)
                case .capture(let group):
                    if group < match.numberOfRanges { appendRange(match.range(at: group)) }
                }
            }
            cursor = NSMaxRange(match.range)
            if exceeded { stop.pointee = true }
        }
        guard !exceeded else { return nil }
        appendRange(NSRange(location: cursor, length: source.length - cursor))
        return exceeded ? nil : output as String
    }
}
