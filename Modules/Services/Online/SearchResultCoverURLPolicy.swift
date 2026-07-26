import Foundation

/// Bounds untrusted cover metadata before it reaches SwiftUI or the image cache.
///
/// Search sources occasionally return an inline image, a complete HTML element,
/// or even a response body for their cover rule. Remote cover requests cannot use
/// those payloads, and parsing them as URLs repeatedly on iOS 17 can monopolize
/// the main thread. 16 KiB still leaves ample room for signed CDN URLs.
enum SearchResultCoverURLPolicy {
    static let maximumUTF8ByteCount = 16 * 1_024

    @inline(never)
    static func normalizedString(
        _ raw: String,
        baseURL: String? = nil
    ) -> String {
        guard isWithinLimit(raw) else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("<"),
              !trimmed.contains(">")
        else {
            return ""
        }

        let resolved: URL?
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            resolved = absolute
        } else if let baseURL,
                  isWithinLimit(baseURL),
                  let base = URL(string: baseURL) {
            resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL
        } else {
            resolved = nil
        }

        guard let resolved,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              resolved.host != nil
        else {
            return ""
        }

        let value = resolved.absoluteString
        return isWithinLimit(value) ? value : ""
    }

    private static func isWithinLimit(_ value: String) -> Bool {
        value.utf8.prefix(maximumUTF8ByteCount + 1).count
            <= maximumUTF8ByteCount
    }
}
