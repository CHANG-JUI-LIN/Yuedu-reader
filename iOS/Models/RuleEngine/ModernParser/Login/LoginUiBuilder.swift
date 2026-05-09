// Builds login-form definitions from Legado's loginUi JSON and
// substitutes credential values into the login request URL/body.

import Foundation

/// Utilities for working with Legado's `loginUi` form definitions.
enum LoginUiBuilder {

    // MARK: - Parse Fields

    /// Parse a `loginUi` JSON string into an array of `LoginField`.
    ///
    /// Expected format:
    /// ```json
    /// [
    ///   {"name":"用户名","type":"text"},
    ///   {"name":"密码","type":"password"},
    ///   {"name":"登录","type":"button","action":"login()"}
    /// ]
    /// ```
    static func parseFields(from json: String) -> [LoginField] {
        return LoginManager.shared.parseLoginUi(json)
    }

    // MARK: - Validate Credentials

    /// Check that every non-button field has a corresponding value in `values`.
    static func validateCredentials(
        fields: [LoginField],
        values: [String: String]
    ) -> Bool {
        for field in fields {
            if field.type == .button { continue }
            guard let val = values[field.name], !val.isEmpty else {
                return false
            }
        }
        return true
    }

    // MARK: - Build Login Request

    /// Substitute credential values into a `loginUrl` template and
    /// determine whether the result is a GET URL or a POST with body.
    ///
    /// Legado conventions:
    /// - `{{fieldName}}` placeholders in the URL are replaced.
    /// - If the URL contains a `,` separator followed by `{` it is a
    ///   POST request (body follows the comma); otherwise it is GET.
    ///
    /// - Returns: A tuple of `(url, body)`. `body` is `nil` for GET.
    static func buildLoginRequest(
        loginUrl: String,
        fields: [LoginField],
        values: [String: String]
    ) -> (url: String, body: String?) {
        var processed = loginUrl

        // Replace {{key}} placeholders with percent-encoded values.
        for field in fields {
            let placeholder = "{{\(field.name)}}"
            let replacement = values[field.name]?
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            processed = processed.replacingOccurrences(of: placeholder, with: replacement)
        }

        // Also replace any extra keys in values that are not in fields.
        for (key, value) in values {
            let placeholder = "{{\(key)}}"
            let replacement = value
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            processed = processed.replacingOccurrences(of: placeholder, with: replacement)
        }

        // Detect POST body (Legado format: "url, { ... }")
        if let separatorRange = findPostSeparator(in: processed) {
            let url = String(processed[processed.startIndex..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(processed[separatorRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (url, body.isEmpty ? nil : body)
        }

        return (processed.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    // MARK: - Collect Login Data

    /// Build the credential map from fields and user-provided values.
    /// Only non-button fields are included.
    static func collectLoginData(
        fields: [LoginField],
        values: [String: String]
    ) -> [String: String] {
        var loginData: [String: String] = [:]
        for field in fields {
            switch field.type {
            case .text, .password:
                if let val = values[field.name] {
                    loginData[field.name] = val
                }
            case .button:
                break
            }
        }
        return loginData
    }

    // MARK: - Private

    /// Find the `, {` boundary that separates URL from POST body in
    /// Legado's combined URL format.
    private static func findPostSeparator(in string: String) -> Range<String.Index>? {
        // Look for ", {" — the comma-space-brace pattern.
        var searchStart = string.startIndex
        while let commaIndex = string[searchStart...].firstIndex(of: ",") {
            let afterComma = string.index(after: commaIndex)
            guard afterComma < string.endIndex else { break }

            // Skip optional whitespace after comma.
            var cursor = afterComma
            while cursor < string.endIndex && string[cursor] == " " {
                cursor = string.index(after: cursor)
            }
            if cursor < string.endIndex && string[cursor] == "{" {
                return commaIndex..<afterComma
            }
            searchStart = afterComma
        }
        return nil
    }
}
