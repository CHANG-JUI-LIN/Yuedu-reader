import Foundation

/// Converts Java `java.util.regex` patterns to ICU syntax (NSRegularExpression / ICU).
///
/// Book source authors write regex on Android, targeting Java's `java.util.regex` engine.
/// NSRegularExpression uses ICU, which differs in:
///  - Possessive quantifiers  `X++`, `X*+`, `X?+`, `X{n,m}+` — not in ICU, silently break compile
///  - Atomic groups           `(?>X)` — not in ICU, breaks compile
///  - `\R`                    — any Unicode line break; ICU does NOT support \R
///  - `\e`                    — ESC char; ICU needs `\x1B`
///  - Java flag `(?d)`        — UNIX_LINES mode; no ICU equivalent
///  - `\p{javaXxx}`           — Java-only Unicode category names
///
/// All conversions are semantically approximate.  Possessive quantifiers and
/// atomic groups lose their backtrack-preventing semantics but remain valid.
/// Box for safely transferring a value across a DispatchQueue boundary without
/// requiring `T: Sendable`. The semaphore signal/wait pair provides the
/// happens-before ordering that makes the @unchecked Sendable safe:
/// write completes before signal(), read happens after wait().
private final class _TimeoutResultBox<T>: @unchecked Sendable {
    var value: T?
}

enum RegexSanitizer {

    // MARK: - Public API

    /// Sanitize a Java regex pattern for use with NSRegularExpression (ICU).
    /// Returns the original string unchanged if no Java-specific syntax is detected.
    static func sanitize(_ pattern: String) -> String {
        guard needsSanitization(pattern) else { return pattern }
        var s = pattern
        s = removePossessiveQuantifiers(s)
        s = s.replacingOccurrences(of: "(?>", with: "(?:")           // atomic group → non-capturing
        s = s.replacingOccurrences(of: "\\R", with: "(?:\\r\\n|[\\n\\r\\u0085\\u2028\\u2029])")
        s = s.replacingOccurrences(of: "\\e", with: "\\x1B")         // ESC char
        s = s.replacingOccurrences(of: "(?d)", with: "")             // UNIX_LINES flag
        s = convertJavaUnicodeCategories(s)
        return s
    }

    /// Returns `true` if the sanitized pattern can be compiled by NSRegularExpression.
    static func canCompile(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: sanitize(pattern))) != nil
    }

    // MARK: - Timeout-Protected Execution

    /// Execute `work` on a background thread, returning `fallback` if it takes
    /// longer than `seconds`.  The background thread is not cancelled — it will
    /// finish eventually — but the caller is unblocked.
    ///
    /// Use this wrapper around any NSRegularExpression matching call to guard
    /// against catastrophic backtracking.
    static func withTimeout<T>(
        seconds: TimeInterval,
        work: @escaping @Sendable () -> T,
        fallback: T
    ) -> T {
        let box = _TimeoutResultBox<T>()
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            sema.signal()
        }
        if sema.wait(timeout: .now() + seconds) == .timedOut {
            return fallback
        }
        return box.value ?? fallback
    }

    // MARK: - Private Helpers

    /// Quick scan: skip allocation of the regex pipeline when there is nothing to fix.
    private static func needsSanitization(_ pattern: String) -> Bool {
        pattern.contains("(?>")
        || pattern.contains("\\R")
        || pattern.contains("\\e")
        || pattern.contains("(?d)")
        || pattern.contains("\\p{java")
        || hasPossessiveQuantifier(pattern)
    }

    /// Detect `+`, `*`, `?`, `}` immediately followed by `+` (possessive).
    private static func hasPossessiveQuantifier(_ s: String) -> Bool {
        var prev: Character = "\0"
        for ch in s {
            if ch == "+" && (prev == "+" || prev == "*" || prev == "?" || prev == "}") {
                return true
            }
            prev = ch
        }
        return false
    }

    /// Strip the trailing `+` from possessive quantifiers:
    ///   `++` → `+`, `*+` → `*`, `?+` → `?`, `{n,m}+` → `{n,m}`
    /// Uses NSRegularExpression with a pattern that itself is ICU-safe.
    private static func removePossessiveQuantifiers(_ s: String) -> String {
        // Match a quantifier character (*+?}) followed immediately by + that is NOT itself
        // the start of a look-ahead / group (preceded by a quantifier, not `(`)
        guard let regex = try? NSRegularExpression(pattern: #"([*+?}])\+"#) else {
            return s
        }
        let ns = s as NSString
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "$1"
        )
    }

    /// Convert Java-only `\p{javaXxx}` Unicode category names to ICU equivalents.
    private static func convertJavaUnicodeCategories(_ s: String) -> String {
        var r = s
        let replacements: [(String, String)] = [
            ("\\p{javaLetterOrDigit}", "\\w"),
            ("\\p{javaLetter}",        "[\\p{L}]"),
            ("\\P{javaLetterOrDigit}", "\\W"),
            ("\\p{javaUpperCase}",     "\\p{Lu}"),
            ("\\p{javaLowerCase}",     "\\p{Ll}"),
            ("\\p{javaWhitespace}",    "\\s"),
            ("\\p{javaMirrored}",      "."),
        ]
        for (java, icu) in replacements {
            r = r.replacingOccurrences(of: java, with: icu)
        }
        return r
    }
}
