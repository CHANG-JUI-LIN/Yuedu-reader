import Foundation

/// Carries a Legado per-image `headers` option from the chapter HTML to the image download.
///
/// Legado treats the `,{json}` suffix on any rule URL as *URL options*, and `headers` is one of
/// them — `AnalyzeUrl` merges it over the source's own header map, which is how a source ships an
/// illustration whose CDN needs a different `Referer` from the pages. The comic reader has always
/// honoured it (`MangaChapterParser.parseImageToken`); the prose reader could not, because
/// `sanitizeOnlineChapterMarkup` has to delete the whole suffix before SwiftSoup sees it (its inner
/// double-quotes close the `src` attribute early and the rest of the chapter leaks out as text).
///
/// So the suffix is not deleted, it is *moved*: the headers are re-encoded into a URL fragment on
/// the `src` itself. A fragment is never sent to a server, is base64url so it cannot re-break
/// attribute parsing, and — unlike a marker attribute — travels with the src through the render IR,
/// the offline manifest and the disk cache without any of them having to know about it.
///
/// One encode point (`ReaderHTMLUtilities.rewriteLegadoImageTag`), one decode point
/// (`OnlineImageLoader`); everything in between just sees a slightly longer URL.
enum OnlineImageRequestOptions {

    /// Fragment marker. `#` + this + base64url(JSON object of headers).
    private static let marker = "#yd-imgh="

    /// Reads a `headers` object out of a Legado `,{json}` option suffix. Returns [:] for a suffix
    /// that carries no headers (the overwhelming majority — click configs, styles, `js`).
    static func headers(fromOptionSuffix suffix: String) -> [String: String] {
        guard suffix.range(of: "\"headers\"") != nil || suffix.range(of: "'headers'") != nil else {
            return [:]
        }
        // The suffix starts at the `,` Legado appends; the object itself is what follows.
        let json = suffix.hasPrefix(",") ? String(suffix.dropFirst()) : suffix
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["headers"] as? [String: Any]
        else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }

    /// Appends `headers` to `src` as a fragment. Returns `src` unchanged when there is nothing to
    /// carry, when it already carries a fragment we would clobber, or when the src is not a remote
    /// URL (a `data:` URI carries its bytes with it — there is no request to add headers to).
    static func encoding(src: String, headers: [String: String]) -> String {
        guard !headers.isEmpty, !src.contains(marker) else { return src }
        let lowercased = src.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return src }
        guard let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])
        else { return src }
        return src + marker + base64URLEncoded(data)
    }

    /// Splits an encoded src back into the URL to request and the headers to request it with.
    /// A src without the marker comes back untouched with no headers, which is every other image.
    static func decode(_ src: String) -> (src: String, headers: [String: String]) {
        guard let range = src.range(of: marker, options: .backwards) else { return (src, [:]) }
        let url = String(src[..<range.lowerBound])
        let payload = String(src[range.upperBound...])
        guard let data = base64URLDecoded(payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (url, [:]) }
        return (url, object.compactMapValues { $0 as? String })
    }

    /// True when `src` carries an encoded header payload — lets callers skip the split entirely.
    static func carriesHeaders(_ src: String) -> Bool {
        src.range(of: marker) != nil
    }

    // MARK: - base64url

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}
