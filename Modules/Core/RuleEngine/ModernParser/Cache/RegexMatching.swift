import Foundation

/// Runs a source- or user-supplied regex against a deadline that stops the matcher itself.
///
/// Book sources ship their own regexes (`##pattern##replacement`, `##` extraction rules), and
/// so do replace rules (替換規則, `ReplaceRuleEngine`); some backtrack catastrophically. The match runs on the calling thread through
/// `enumerateMatches(options: .reportProgress)`: ICU calls the block periodically even in the
/// middle of a single `find`, and setting `stop` there aborts the search. So a timed-out match
/// costs `timeout` of CPU and nothing more.
///
/// It replaces `RegexSanitizer.withTimeout`, which ran the match on a detached thread and only
/// stopped *waiting* for it: the thread kept backtracking at 100% CPU, one more for every
/// timed-out call, until MetricKit reported 90 s of CPU in 93.6 s during a background
/// `refresh.all` (Crashlytics 58c94021, build 143).
enum RegexMatching {

    /// Every match of `regex` in `string` (just the first under `firstOnly`), or `nil` when the
    /// search ran past `timeout` and was stopped.
    static func matches(
        of regex: NSRegularExpression,
        in string: String,
        range: NSRange? = nil,
        firstOnly: Bool,
        timeout: TimeInterval
    ) -> [NSTextCheckingResult]? {
        var found: [NSTextCheckingResult] = []
        let completed = enumerateMatches(of: regex, in: string, range: range, timeout: timeout) { match, stop in
            found.append(match)
            if firstOnly { stop = true }
        }
        return completed ? found : nil
    }

    /// Hands each match of `regex` in `string` to `body` as it is found, so a caller that
    /// counts its output (replace rules' budget) can stop before holding every match. Returns
    /// false when the search ran past `timeout` and was stopped (logged); `body` setting
    /// `stop` is a normal completion.
    @discardableResult
    static func enumerateMatches(
        of regex: NSRegularExpression,
        in string: String,
        range: NSRange? = nil,
        timeout: TimeInterval,
        _ body: (NSTextCheckingResult, inout Bool) -> Void
    ) -> Bool {
        let range = range ?? NSRange(location: 0, length: (string as NSString).length)
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + timeout
        var timedOut = false
        SourcePerfTrace.mainThreadWait("wait.regex", "timeout=\(timeout)s") {
            regex.enumerateMatches(in: string, options: [.reportProgress], range: range) { match, _, stop in
                if let match {
                    var stopHere = false
                    body(match, &stopHere)
                    if stopHere {
                        stop.pointee = true
                        return
                    }
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    timedOut = true
                    stop.pointee = true
                }
            }
        }
        guard !timedOut else {
            AppLogger.parse("Regex stopped at its timeout", context: [
                "pattern": String(regex.pattern.prefix(160)),
                "inputLength": range.length,
                "timeoutMs": Int(timeout * 1000),
                "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
            ], level: .warning)
            return false
        }
        return true
    }

    /// `string` with every match of `regex` (just the first under `firstOnly`) replaced by
    /// `template`, `$0`–`$99` resolved as `stringByReplacingMatches` does — or `nil` when the
    /// search ran past `timeout`.
    static func replacing(
        _ regex: NSRegularExpression,
        in string: String,
        template: String,
        firstOnly: Bool,
        timeout: TimeInterval
    ) -> String? {
        guard let matches = matches(of: regex, in: string, firstOnly: firstOnly, timeout: timeout) else {
            return nil
        }
        guard !matches.isEmpty else { return string }
        let source = string as NSString
        let output = NSMutableString()
        var cursor = 0
        for match in matches {
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            output.append(regex.replacementString(for: match, in: string, offset: 0, template: template))
            cursor = NSMaxRange(match.range)
        }
        output.append(source.substring(from: cursor))
        return output as String
    }
}
