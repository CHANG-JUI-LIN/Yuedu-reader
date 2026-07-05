import Foundation

struct LegadoRequestParser {
    static func parseChapterRequest(_ raw: String) -> ChapterRequestSpec {
        var source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let encodedRange = source.range(
            of: #",\s*%7B[\s\S]*%7D\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let prefix = String(source[..<encodedRange.lowerBound])
            let encodedSuffix = String(source[encodedRange])
            if let decodedSuffix = encodedSuffix.removingPercentEncoding {
                source = prefix + decodedSuffix
            }
        }
        guard let match = source.range(of: #",\s*\{.*\}\s*$"#, options: .regularExpression),
            let commaIndex = source[match].firstIndex(of: ",")
        else {
            return ChapterRequestSpec(
                url: source,
                method: "GET",
                body: nil,
                headers: [:],
                referer: nil,
                useWebView: false,
                charset: nil
            )
        }

        let urlPart = String(source[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let optionsText = normalizeLegadoOptionsJSONLike(
            String(source[source.index(after: commaIndex)...])
        )

        guard let endBrace = optionsText.lastIndex(of: "}"),
            let data = optionsText[..<optionsText.index(after: endBrace)].data(using: .utf8),
            let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ChapterRequestSpec(
                url: urlPart,
                method: "GET",
                body: nil,
                headers: [:],
                referer: nil,
                useWebView: false,
                charset: nil
            )
        }

        let method = ((options["method"] as? String) ?? "GET").uppercased() == "POST"
            ? "POST" : "GET"
        return ChapterRequestSpec(
            url: urlPart,
            method: method,
            body: stringifyJSONValue(options["body"]),
            headers: stringDictionary(from: options["headers"]),
            referer: stringifyJSONValue(options["referer"]),
            useWebView: asBool(options["webView"]),
            charset: stringifyJSONValue(options["charset"]),
            webViewDelayMs: parseWebViewDelay(options)
        )
    }

    private static func stringifyJSONValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }

    private static func stringDictionary(from value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (key, rawValue) in dict {
            guard let stringValue = stringifyJSONValue(rawValue) else { continue }
            output[key] = stringValue
        }
        return output
    }

    private static func parseWebViewDelay(_ options: [String: Any]) -> Int {
        if let d = options["webViewDelayTime"] as? Int { return d }
        if let d = options["webViewDelayTime"] as? String, let v = Int(d) { return v }
        if let d = options["webViewDelay"] as? Int { return d }
        if let d = options["webViewDelay"] as? String, let v = Int(d) { return v }
        return 0
    }

    private static func asBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        let text = String(describing: value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["true", "1", "yes", "y"].contains(text)
    }

    private static func normalizeLegadoOptionsJSONLike(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(",") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "\"")
            .replacingOccurrences(of: "’", with: "\"")
        if s.contains("'") {
            s = s.replacingOccurrences(
                of: #"(?<!\\)'([^']*)'"#,
                with: #"\"$1\""#,
                options: .regularExpression
            )
        }
        s = s.replacingOccurrences(
            of: #"([\{\[,]\s*)([A-Za-z_][A-Za-z0-9_\-]*)(\s*:)"#,
            with: #"$1\"$2\"$3"#,
            options: .regularExpression
        )
        return s
    }
}
