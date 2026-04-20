import Foundation
import JavaScriptCore
import os

/// Security sandbox for JavaScript execution.
/// Limits what book source JS code can access, enforces timeouts,
/// and installs safe polyfills expected by Legado-compatible sources.
final class JSSandbox {

    // MARK: - Constants

    /// Maximum script length allowed (100 KB).
    private static let maxScriptLength = 100 * 1024

    /// Default execution timeout in seconds.
    static let defaultTimeout: TimeInterval = 10.0

    /// Globals considered unsafe that should be removed or neutered.
    private static let unsafeGlobals: [String] = [
        "XMLHttpRequest",
        "fetch",
        "WebSocket",
    ]

    /// Single shared JS evaluation queue. Bounds thread leaks to at most one.
    private static let evalQueue = DispatchQueue(
        label: "com.yuedu.jssandbox.eval",
        qos: .userInitiated
    )

    // MARK: - Public API

    /// Configure a JSContext with security restrictions and safe polyfills.
    static func configure(_ context: JSContext) {
        removeUnsafeGlobals(context)
        configureResourceLimits(context)
        installPolyfills(context)
        installExceptionHandler(context)
    }

    /// Evaluate a script with timeout protection.
    /// - Parameters:
    ///   - context: A pre-configured JSContext.
    ///   - script: The JavaScript source to evaluate.
    ///   - timeout: Maximum wall-clock time allowed (default 10 s).
    /// - Returns: The evaluation result, or `nil` on timeout / error.
    static func evaluateWithTimeout(
        _ context: JSContext,
        script: String,
        timeout: TimeInterval = defaultTimeout
    ) -> JSValue? {
        guard sanitize(script) else {
            logSecurity("Script rejected by sanitization (length: \(script.count))")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: JSValue?

        evalQueue.async {
            result = context.evaluateScript(script)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            logSecurity("Script execution timed out after \(timeout)s")
            return nil
        }
        return result
    }

    // MARK: - Security Measures

    /// Remove or neuter dangerous global objects from the context.
    private static func removeUnsafeGlobals(_ context: JSContext) {
        for name in unsafeGlobals {
            context.setObject(nil, forKeyedSubscript: name as NSString)
        }

        // Neuter Function constructor to prevent arbitrary code creation.
        // Wrap in try so sources that don't touch it are unaffected.
        context.evaluateScript("""
        (function() {
            var _origFunction = Function;
            Function = function() {
                throw new Error('Function constructor is disabled in sandbox');
            };
            Function.prototype = _origFunction.prototype;
        })();
        """)

        context.evaluateScript("""
        (function() {
            eval = function(code) {
                throw new Error('eval() is disabled in sandbox');
            };
        })();
        """)
    }

    /// Set up resource-limit tracking for the context.
    private static func configureResourceLimits(_ context: JSContext) {
        // JavaScriptCore on iOS does not expose public heap-limit APIs.
        // We install a lightweight counter so callers can monitor usage.
        context.evaluateScript("""
        var __sandbox = {
            evalCount: 0,
            maxEvalCount: 5000,
            tick: function() {
                this.evalCount++;
                if (this.evalCount > this.maxEvalCount) {
                    throw new Error('Sandbox: evaluation count exceeded ' + this.maxEvalCount);
                }
            }
        };
        """)
    }

    /// Install safe polyfills expected by many Legado-compatible book sources.
    private static func installPolyfills(_ context: JSContext) {
        // console → redirects to java.log bridge
        context.evaluateScript("""
        var console = {
            log: function() {
                if (typeof java !== 'undefined' && java.log) {
                    java.log(Array.prototype.join.call(arguments, ' '));
                }
            },
            warn: function() {
                if (typeof java !== 'undefined' && java.log) {
                    java.log('[WARN] ' + Array.prototype.join.call(arguments, ' '));
                }
            },
            error: function() {
                if (typeof java !== 'undefined' && java.log) {
                    java.log('[ERROR] ' + Array.prototype.join.call(arguments, ' '));
                }
            },
            info: function() {
                if (typeof java !== 'undefined' && java.log) {
                    java.log('[INFO] ' + Array.prototype.join.call(arguments, ' '));
                }
            }
        };
        """)

        // btoa / atob polyfills
        context.evaluateScript("""
        if (typeof btoa === 'undefined') {
            var btoa = function(str) {
                if (typeof java !== 'undefined' && java.base64Encode) {
                    return java.base64Encode(str);
                }
                throw new Error('btoa is not available');
            };
        }
        if (typeof atob === 'undefined') {
            var atob = function(str) {
                if (typeof java !== 'undefined' && java.base64DecodeStr) {
                    return java.base64DecodeStr(str);
                }
                throw new Error('atob is not available');
            };
        }
        """)
    }

    /// Attach a global exception handler that logs JS errors.
    private static func installExceptionHandler(_ context: JSContext) {
        context.exceptionHandler = { _, exception in
            guard let exception = exception else { return }
            logSecurity("JS exception: \(exception)")
        }
    }

    // MARK: - Sanitization

    /// Basic input validation before evaluation.
    /// Returns `true` if the script is acceptable.
    static func sanitize(_ script: String) -> Bool {
        if script.count > maxScriptLength {
            logSecurity("Script too large: \(script.count) chars (max \(maxScriptLength))")
            return false
        }
        return true
    }

    // MARK: - URL Whitelist

    /// Validate that a URL is allowed for network access.
    /// - Parameters:
    ///   - url: The URL string requested by JS code.
    ///   - allowedDomains: Optional set of allowed domain suffixes. `nil` means allow all.
    /// - Returns: `true` if the URL is permitted.
    static func isURLAllowed(_ url: String, allowedDomains: Set<String>?) -> Bool {
        guard let allowedDomains = allowedDomains, !allowedDomains.isEmpty else {
            return true // no whitelist configured — allow all
        }
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased() else {
            logSecurity("URL rejected (invalid): \(url)")
            return false
        }
        let allowed = allowedDomains.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
        if !allowed {
            logSecurity("URL rejected (domain not whitelisted): \(url)")
        }
        return allowed
    }

    // MARK: - Logging

    private static func logSecurity(_ message: String) {
        #if DEBUG
        print("[JSSandbox] \(message)")
        #endif
        // In release builds the message is silently dropped.
        // Integrate with your analytics / logging system as needed.
    }
}
