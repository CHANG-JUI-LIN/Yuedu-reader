// Port of io.legado.app.model.analyzeRule.CustomUrl
// Wrapper that separates a Legado URL from its JSON option block.

import Foundation

struct CustomUrl {

    /// The raw URL portion (before the `,{` boundary).
    var url: String

    /// Parsed attributes from the JSON option block.
    var attributes: [String: Any]

    // MARK: - Regex matching Legado's paramPattern: optional whitespace + comma + whitespace + lookahead `{`
    static let paramPattern = try! NSRegularExpression(pattern: "\\s*,\\s*(?=\\{)")

    // MARK: - Initializers

    /// Create from a plain URL with no attributes.
    init(url: String) {
        self.url = url
        self.attributes = [:]
    }

    /// Parse a serialized Legado URL string (`"url,{json}"`).
    init(serialized: String) {
        let nsRange = NSRange(serialized.startIndex..., in: serialized)
        if let match = Self.paramPattern.firstMatch(in: serialized, range: nsRange),
           let swiftRange = Range(match.range, in: serialized) {
            self.url = String(serialized[serialized.startIndex..<swiftRange.lowerBound])
            let jsonStr = String(serialized[swiftRange.upperBound...])
            if let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.attributes = dict
            } else {
                self.attributes = [:]
            }
        } else {
            self.url = serialized
            self.attributes = [:]
        }
    }

    // MARK: - Attribute Access

    mutating func putAttribute(key: String, value: Any) {
        attributes[key] = value
    }

    func getAttribute<T>(key: String) -> T? {
        return attributes[key] as? T
    }

    // MARK: - Serialization

    /// Reconstruct the Legado format: `"url,{json}"`.
    /// If there are no attributes, returns just the URL.
    func serialized() -> String {
        guard !attributes.isEmpty else { return url }
        guard let data = try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return url
        }
        return "\(url),\(json)"
    }
}
