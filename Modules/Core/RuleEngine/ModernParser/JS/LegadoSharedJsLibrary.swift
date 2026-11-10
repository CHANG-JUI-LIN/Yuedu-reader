import CryptoKit
import Foundation

/// Legado `SharedJsScope`: a `jsLib` written as a JSON object (`{"名稱": "https://…/jsLib.js"}`)
/// is not code. Each value that is an absolute URL names a script library; Legado downloads it
/// once, keeps it in `cacheDir/shareJs` under the URL's MD5 with no expiry, and evaluates the
/// libraries in the object's order. Values that are not URLs are ignored.
///
/// The qyyuapi 漫画 sources (G站漫画, 漫画屋, 如漫画, 皮皮漫画, 哔哩漫画 — YCK 1329／1331) define
/// `Reload`, `Get`, `Map` and the rest of their helpers this way; evaluated as code, the object
/// defined nothing and every rule failed with `Can't find variable: Reload`.
enum LegadoSharedJsLibrary {

    /// Where downloaded libraries live: Legado's `shareJs` cache, one directory every source
    /// shares, so two sources naming the same CDN file download it once.
    static let cacheDirectory: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LegadoSharedJs", isDirectory: true)

    /// The library URLs of a JSON-object `jsLib`, in the object's order — nil when `jsLib` is
    /// code. Legado's test is `isJsonObject()` (trimmed text starts with `{` and ends with `}`)
    /// followed by a Gson parse into `Map<String, String>`.
    static func libraryURLs(in jsLib: String) -> [String]? {
        let text = jsLib.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return nil }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return nil
            }
            object = parsed
        } catch {
            // A block of code wrapped in braces. Legado's Gson parse throws here and the
            // source's scripts all fail; it runs as code instead.
            AppLogger.parse("jsLib starts and ends with braces but is not a JSON object; evaluating it as code", context: [
                "error": error.localizedDescription
            ])
            return nil
        }
        return orderedKeys(of: text).compactMap { key in
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") ? trimmed : nil
        }
    }

    /// A library's text: the cached copy, or a fresh download through `download` that is kept
    /// when it is a successful, non-empty response. Nil when neither exists.
    static func script(for url: String, download: (String) -> LegadoHTTPResult) -> String? {
        let file = cacheDirectory.appendingPathComponent(cacheKey(for: url) + ".js")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let cached = try String(contentsOf: file, encoding: .utf8)
                if !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return cached }
            } catch {
                AppLogger.parse("Cached jsLib library could not be read; downloading it again", context: [
                    "url": String(url.prefix(200)), "error": error.localizedDescription
                ])
            }
        }
        let response = download(url)
        let body = response.body
        // Legado keeps whatever body OkHttp returned, an error page included, and then fails
        // on every evaluation until the cache is cleared. Only a real script is kept here.
        guard (200...299).contains(response.statusCode),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLogger.network("jsLib library download failed", context: [
                "url": String(url.prefix(200)),
                "statusCode": response.statusCode,
                "error": response.transportError.map { String(describing: $0) } ?? "none"
            ])
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.parse("jsLib library could not be cached; it is downloaded again next time", context: [
                "url": String(url.prefix(200)), "error": error.localizedDescription
            ])
        }
        return body
    }

    /// Legado's key: `MD5Utils.md5Encode(url)`, the full 32-character hex digest.
    static func cacheKey(for url: String) -> String {
        Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The object's top-level keys in source order. `JSONSerialization` returns an unordered
    /// dictionary, while Gson's `LinkedTreeMap` keeps the order and Legado evaluates the
    /// libraries in it (a CryptoJS listed before the code that uses it).
    private static func orderedKeys(of text: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var expectingKey = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "{", "[":
                depth += 1
                if depth == 1 { expectingKey = true }
            case "}", "]":
                depth -= 1
            case ",":
                if depth == 1 { expectingKey = true }
            case "\"":
                let start = index
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\" { index = text.index(after: index) }
                    if index < text.endIndex { index = text.index(after: index) }
                }
                guard index < text.endIndex else { return keys }
                if depth == 1, expectingKey {
                    let token = String(text[start...index])
                    // The whole object already parsed, so every key token is valid JSON.
                    if let key = (try? JSONSerialization.jsonObject(
                        with: Data(token.utf8), options: .fragmentsAllowed
                    )) as? String {
                        keys.append(key)
                    }
                    expectingKey = false
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        return keys
    }
}
