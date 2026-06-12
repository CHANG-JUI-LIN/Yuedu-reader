import Foundation

struct ImportedTTSSource: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let urlTemplate: String
    let headers: [String: String]

    init(
        name: String,
        urlTemplate: String,
        sourceID: String? = nil,
        headers: [String: String] = [:]
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "TTS" : trimmedName
        self.urlTemplate = trimmedURL
        self.headers = headers
        let stableID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = stableID?.isEmpty == false ? stableID! : "\(self.name)|\(trimmedURL)"
    }
}

enum TTSSourceJSONParserError: LocalizedError {
    case noSources

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "No usable TTS sources were found in the JSON file"
        }
    }
}

enum TTSSourceJSONParser {
    static func parse(data: Data) throws -> [ImportedTTSSource] {
        let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let items = root.map(sourceItems(from:)) ?? lineDelimitedItems(from: data)
        var seen = Set<String>()
        let sources = items.compactMap { dictionary -> ImportedTTSSource? in
            guard let url = firstString(in: dictionary, keys: ["url", "ttsUrl", "sourceUrl"]),
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let name = firstString(in: dictionary, keys: ["name", "sourceName", "title"]) ?? "TTS"
            let sourceID = firstString(in: dictionary, keys: ["id", "sourceId", "uuid"])
            let headers = parsedHeaders(from: value(for: "header", in: dictionary))
                .merging(parsedHeaders(from: value(for: "headers", in: dictionary))) { _, new in new }
            let source = ImportedTTSSource(
                name: name,
                urlTemplate: url,
                sourceID: sourceID,
                headers: headers
            )
            let duplicateKey = source.urlTemplate
            guard !seen.contains(duplicateKey) else { return nil }
            seen.insert(duplicateKey)
            return source
        }

        guard !sources.isEmpty else {
            throw TTSSourceJSONParserError.noSources
        }
        return sources
    }

    private static func sourceItems(from value: Any) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        guard let dictionary = value as? [String: Any] else {
            return []
        }
        for key in ["sources", "ttsSources", "voiceSources", "data", "items", "list"] {
            guard let nested = Self.value(for: key, in: dictionary) else { continue }
            let items = sourceItems(from: nested)
            if !items.isEmpty {
                return items
            }
        }
        if Self.value(for: "url", in: dictionary) != nil {
            return [dictionary]
        }
        return []
    }

    private static func lineDelimitedItems(from data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"),
                      let lineData = trimmed.data(using: .utf8),
                      let dictionary = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return nil
                }
                return dictionary
            }
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let candidate = value(for: key, in: dictionary) else { continue }
            if let string = candidate as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = candidate as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func value(for key: String, in dictionary: [String: Any]) -> Any? {
        if let direct = dictionary[key] { return direct }
        let lower = key.lowercased()
        return dictionary.first { $0.key.lowercased() == lower }?.value
    }

    private static func parsedHeaders(from value: Any?) -> [String: String] {
        guard let value else { return [:] }
        if let dictionary = value as? [String: Any] {
            return stringifyHeaders(dictionary)
        }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return stringifyHeaders(dictionary)
        }
        return [:]
    }

    private static func stringifyHeaders(_ dictionary: [String: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in dictionary {
            switch value {
            case let string as String:
                headers[key] = string
            case let number as NSNumber:
                headers[key] = number.stringValue
            case _ as NSNull:
                continue
            default:
                headers[key] = "\(value)"
            }
        }
        return headers
    }
}

protocol TTSAudioProvider: AnyObject {
    var displayName: String { get }
    func audioData(for text: String, title: String, rate: Float) async throws -> Data
}

enum DirectChapterAudioResolver {
    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "aif", "flac", "m4a", "m4b", "mp3", "oga", "ogg", "opus", "wav"
    ]

    static func request(from content: String) -> URLRequest? {
        for candidate in candidates(from: content) {
            guard isAudioCandidate(candidate) else { continue }
            if let request = AnalyzeUrl(ruleUrl: candidate).toURLRequest() {
                return request
            }
            if let url = URL(string: stripLegadoOptions(from: candidate)) {
                return URLRequest(url: url)
            }
        }
        return nil
    }

    /// Heuristic that decides whether a fetched chapter is actually an audiobook
    /// stream rather than prose. Aggregation sources serve audiobooks under a
    /// text (`bookSourceType == 0`) source, so the only reliable signal is the
    /// content itself: a single audio direct link with essentially no body text.
    /// Mirrors `MangaChapterParser.looksLikeMangaContent` (strip the media
    /// reference + markup, confirm little prose remains).
    static func looksLikeAudioContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, request(from: trimmed) != nil else { return false }

        var residual = trimmed
        for candidate in candidates(from: trimmed) where isAudioCandidate(candidate) {
            residual = residual.replacingOccurrences(of: candidate, with: "")
        }
        // Strip <audio> elements, any remaining markup, leftover URLs and Legado
        // option objects, then check that almost nothing (prose) is left over.
        for pattern in [
            #"(?is)<audio\b[^>]*>.*?</audio>"#,
            #"(?is)<audio\b[^>]*/?>"#,
            #"<[^>]+>"#,
            #"https?://[^\s<>"']+"#,
            #"\{[^}]*\}"#,
        ] {
            residual = residual.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        residual = residual.trimmingCharacters(in: .whitespacesAndNewlines)
        return residual.count <= 16
    }

    private static func candidates(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var values: [String] = [trimmed]
        values.append(contentsOf: urlLikeMatches(in: trimmed))
        values.append(contentsOf: htmlMediaSources(in: trimmed))
        return values
    }

    private static func urlLikeMatches(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s<>"']+(?:\s*,\s*\{[^ \n\r]*\})?"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func htmlMediaSources(in text: String) -> [String] {
        guard text.localizedCaseInsensitiveContains("<audio"),
              let regex = try? NSRegularExpression(
                pattern: #"<audio\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
                options: [.caseInsensitive]
              )
        else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func isAudioCandidate(_ candidate: String) -> Bool {
        let rawURL = stripLegadoOptions(from: candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }

        let pathExtension = url.pathExtension.lowercased()
        if audioExtensions.contains(pathExtension) {
            return true
        }

        let lowered = rawURL.lowercased()
        return lowered.contains("mime=audio")
            // 番茄畅听-style CDN links carry no file extension and live under a /video/
            // path; the only audio signal is the query, e.g. `mime_type=audio_mpeg`.
            || lowered.contains("mime_type=audio")
            || lowered.contains("content-type=audio")
            || lowered.contains("/audio/")
            || lowered.contains("/audiobook/")
            || lowered.contains("/tts/")
    }

    private static func stripLegadoOptions(from candidate: String) -> String {
        if let range = candidate.range(of: #"\s*,\s*\{"#, options: .regularExpression) {
            return String(candidate[..<range.lowerBound])
        }
        return candidate
    }
}

enum TTSAudioProviderError: LocalizedError {
    case emptyTemplate
    case invalidURL
    case emptyData
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            return "TTS URL template is empty"
        case .invalidURL:
            return "TTS URL template produced an invalid URL"
        case .emptyData:
            return "TTS provider returned empty audio data"
        case .badStatus(let status):
            return "TTS provider returned HTTP \(status)"
        }
    }
}

final class CustomHTTPProvider: TTSAudioProvider {
    var displayName: String { "網路語音" }

    static func buildURL(template: String, text: String, title: String, rate: Float) -> URL? {
        let provider = CustomHTTPProvider()
        return provider.buildLegacyURL(template: template, text: text, title: title, rate: rate)
    }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        if var request = DirectChapterAudioResolver.request(from: text) {
            for (field, value) in GlobalSettings.shared.httpTtsHeaders {
                if request.value(forHTTPHeaderField: field) == nil {
                    request.setValue(value, forHTTPHeaderField: field)
                }
            }
            ttsLog("[TTS][Provider] direct audio request url=\(request.url?.absoluteString ?? "")")
            return try await fetchAudioData(request: request)
        }

        let template = GlobalSettings.shared.httpTtsUrlTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ttsLog("[TTS][Provider] template empty=\(template.isEmpty) textCount=\(text.count) title=\(title) rate=\(rate)")
        guard !template.isEmpty else {
            throw TTSAudioProviderError.emptyTemplate
        }
        guard var request = buildRequest(template: template, text: text, title: title, rate: rate) else {
            ttsLog("[TTS][Provider] invalid url template=\(template)")
            throw TTSAudioProviderError.invalidURL
        }
        for (field, value) in GlobalSettings.shared.httpTtsHeaders {
            if request.value(forHTTPHeaderField: field) == nil {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        ttsLog("[TTS][Provider] request method=\(request.httpMethod ?? "GET") url=\(request.url?.absoluteString ?? "")")

        return try await fetchAudioData(request: request)
    }

    private func fetchAudioData(request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            ttsLog("[TTS][Provider] response status=\(http.statusCode) contentType=\(contentType) bytes=\(data.count)")
        } else {
            ttsLog("[TTS][Provider] response nonHTTP bytes=\(data.count)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TTSAudioProviderError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw TTSAudioProviderError.emptyData
        }
        return data
    }

    private func buildRequest(template: String, text: String, title: String, rate: Float) -> URLRequest? {
        if isLegadoTemplate(template) {
            return buildLegadoRequest(template: template, text: text, title: title, rate: rate)
        }
        guard let url = buildLegacyURL(template: template, text: text, title: title, rate: rate) else {
            return nil
        }
        return URLRequest(url: url)
    }

    private func buildLegacyURL(template: String, text: String, title: String, rate: Float) -> URL? {
        var queryValueCS = CharacterSet.urlQueryAllowed
        queryValueCS.remove(charactersIn: "&+=?#%")
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: queryValueCS) ?? text
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: queryValueCS) ?? title
        let speedStr = edgeTTSRateString(for: rate)
            .addingPercentEncoding(withAllowedCharacters: queryValueCS) ?? "%2B0%25"

        let resolved = template
            .replacingOccurrences(of: "{{text}}", with: encodedText)
            .replacingOccurrences(of: "{{title}}", with: encodedTitle)
            .replacingOccurrences(of: "{{speakSpeed}}", with: speedStr)

        return URL(string: resolved)
    }

    private func buildLegadoRequest(template: String, text: String, title: String, rate: Float) -> URLRequest? {
        let hasOptions = templateContainsOptions(template)
        let speed = legadoSpeakSpeed(for: rate)
        let resolved = resolveLegadoTemplate(
            template,
            text: text,
            title: title,
            speed: speed,
            useRawSpeakText: hasOptions
        )

        if hasOptions {
            return AnalyzeUrl(
                ruleUrl: resolved,
                speakText: text,
                speakSpeed: speed
            ).toURLRequest()
        }
        guard let url = URL(string: resolved) else {
            return nil
        }
        return URLRequest(url: url)
    }

    private func isLegadoTemplate(_ template: String) -> Bool {
        template.contains("speakText")
            || template.contains("java.encodeURI")
            || template.contains("encodeURIComponent")
            || templateContainsOptions(template)
    }

    private func templateContainsOptions(_ template: String) -> Bool {
        template.range(of: #"\s*,\s*\{"#, options: .regularExpression) != nil
    }

    private func resolveLegadoTemplate(
        _ template: String,
        text: String,
        title: String,
        speed: Int,
        useRawSpeakText: Bool
    ) -> String {
        let encodedText = percentEncoded(text)
        let doubleEncodedText = percentEncoded(encodedText)
        let encodedTitle = percentEncoded(title)
        let speakText = useRawSpeakText ? text : encodedText
        var resolved = template

        resolved = replacePattern(
            #"\{\{\s*java\.encodeURI\(\s*java\.encodeURI\(\s*speakText\s*\)\s*\)\s*\}\}"#,
            in: resolved,
            with: doubleEncodedText
        )
        resolved = replacePattern(
            #"\{\{\s*java\.encodeURI\(\s*speakText\s*\)\s*\}\}"#,
            in: resolved,
            with: encodedText
        )
        resolved = replacePattern(
            #"\{\{\s*encodeURIComponent\(\s*speakText\s*\)\s*\}\}"#,
            in: resolved,
            with: encodedText
        )
        resolved = replaceSpeedExpressions(in: resolved, speed: speed)

        resolved = replaceTemplate("speakText", in: resolved, with: speakText)
        resolved = replaceTemplate("speakSpeed", in: resolved, with: "\(speed)")
        resolved = replaceTemplate("text", in: resolved, with: encodedText)
        resolved = replaceTemplate("title", in: resolved, with: encodedTitle)
        return resolved
    }

    private func replaceTemplate(_ name: String, in input: String, with value: String) -> String {
        replacePattern(#"\{\{\s*\#(name)\s*\}\}"#, in: input, with: value)
    }

    private func replacePattern(_ pattern: String, in input: String, with value: String) -> String {
        input.replacingOccurrences(of: pattern, with: value, options: .regularExpression)
    }

    private func replaceSpeedExpressions(in input: String, speed: Int) -> String {
        let pattern = #"\{\{\s*([^{}]*speakSpeed[^{}]*)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let nsRange = NSRange(input.startIndex..., in: input)
        var result = input
        let matches = regex.matches(in: input, range: nsRange)
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let expressionRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let expression = String(result[expressionRange])
            guard expression.trimmingCharacters(in: .whitespacesAndNewlines) != "speakSpeed",
                  let evaluated = evaluateSpeedExpression(expression, speed: speed) else {
                continue
            }
            result.replaceSubrange(fullRange, with: evaluated)
        }
        return result
    }

    private func evaluateSpeedExpression(_ expression: String, speed: Int) -> String? {
        let normalized = expression
            .replacingOccurrences(of: "speakSpeed", with: "\(speed)")
            .replacingOccurrences(of: " ", with: "")
        guard let value = evaluateArithmetic(normalized) else {
            return nil
        }
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.2f", value)
    }

    private func evaluateArithmetic(_ expression: String) -> Double? {
        let tokens = tokenize(expression)
        guard !tokens.isEmpty else { return nil }
        var values: [Double] = []
        var operators: [Character] = []

        func applyLastOperator() -> Bool {
            guard let op = operators.popLast(),
                  let rhs = values.popLast(),
                  let lhs = values.popLast() else {
                return false
            }
            switch op {
            case "+": values.append(lhs + rhs)
            case "-": values.append(lhs - rhs)
            case "*": values.append(lhs * rhs)
            case "/":
                guard rhs != 0 else { return false }
                values.append(lhs / rhs)
            default:
                return false
            }
            return true
        }

        for token in tokens {
            if let value = Double(token) {
                values.append(value)
                continue
            }
            guard let op = token.first else {
                return nil
            }
            if op == "(" {
                operators.append(op)
                continue
            }
            if op == ")" {
                while let last = operators.last, last != "(" {
                    guard applyLastOperator() else { return nil }
                }
                guard operators.last == "(" else { return nil }
                _ = operators.popLast()
                continue
            }
            guard ["+", "-", "*", "/"].contains(op) else { return nil }
            while let last = operators.last, precedence(last) >= precedence(op) {
                guard applyLastOperator() else { return nil }
            }
            operators.append(op)
        }
        while !operators.isEmpty {
            guard operators.last != "(" else { return nil }
            guard applyLastOperator() else { return nil }
        }
        return values.count == 1 ? values[0] : nil
    }

    private func tokenize(_ expression: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in expression {
            if char.isNumber || char == "." {
                current.append(char)
            } else if ["+", "-", "*", "/", "(", ")"].contains(char) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(char))
            } else {
                return []
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func precedence(_ op: Character) -> Int {
        switch op {
        case "*", "/": return 2
        case "+", "-": return 1
        default: return 0
        }
    }

    private func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func legadoSpeakSpeed(for rate: Float) -> Int {
        let normalized = Double(rate / 0.5)
        return max(0, min(15, Int((normalized * 5).rounded())))
    }

    private func edgeTTSRateString(for rate: Float) -> String {
        let percentage = Int((((rate / 0.5) - 1) * 100).rounded())
        if percentage >= 0 {
            return "+\(percentage)%"
        }
        return "\(percentage)%"
    }
}
