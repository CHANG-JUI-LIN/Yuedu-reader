import Foundation

struct ImportedTTSSource: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let urlTemplate: String
    let headers: [String: String]
    let loginUi: String?
    let loginUrl: String?
    let loginCheckJs: String?
    /// Legado `HttpTTS.jsLib`: shared helper functions the `url` rule may call. Upstream
    /// injects it into the scope of every rule evaluation (`BaseSource.evalJS`), which is why
    /// nothing else needs to be executed to make those helpers exist.
    let jsLib: String?
    let contentType: String?
    let concurrentRate: String?

    init(
        name: String,
        urlTemplate: String,
        sourceID: String? = nil,
        headers: [String: String] = [:],
        loginUi: String? = nil,
        loginUrl: String? = nil,
        loginCheckJs: String? = nil,
        jsLib: String? = nil,
        contentType: String? = nil,
        concurrentRate: String? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "TTS" : trimmedName
        self.urlTemplate = trimmedURL
        self.headers = headers
        self.loginUi = loginUi
        self.loginUrl = loginUrl
        self.loginCheckJs = loginCheckJs
        self.jsLib = jsLib
        self.contentType = contentType
        self.concurrentRate = concurrentRate
        let stableID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = stableID?.isEmpty == false ? stableID! : "\(self.name)|\(trimmedURL)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, urlTemplate, headers
        case loginUi, loginUrl, loginCheckJs, jsLib, contentType, concurrentRate
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
            let loginUi = firstString(in: dictionary, keys: ["loginUi"])
            let loginUrl = firstString(in: dictionary, keys: ["loginUrl"])
            let loginCheckJs = firstString(in: dictionary, keys: ["loginCheckJs"])
            let jsLib = firstString(in: dictionary, keys: ["jsLib"])
            let contentType = firstString(in: dictionary, keys: ["contentType"])
            let concurrentRate = firstString(in: dictionary, keys: ["concurrentRate"])
            let source = ImportedTTSSource(
                name: name,
                urlTemplate: url,
                sourceID: sourceID,
                headers: headers,
                loginUi: loginUi,
                loginUrl: loginUrl,
                loginCheckJs: loginCheckJs,
                jsLib: jsLib,
                contentType: contentType,
                concurrentRate: concurrentRate
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

/// Byte-level judgements about a TTS provider's response body, shared by the provider that
/// fetches it and the engine that plays it. One place, because both had to agree on what
/// counts as audio and neither could see the other's answer.
enum TTSAudioPayload {
    /// Whether the bytes open with a container `AVAudioFile` can actually decode.
    ///
    /// The same magic numbers `TTSChunkAudioPlayer.fileExtension(for:)` reads to pick a file
    /// extension — it just never used them to say no, defaulting anything unrecognised to
    /// "mp3" and letting AVFoundation discover the truth at playback time. Deciding it here
    /// keeps a bad payload out of the segment cache, so the failure is attributed to the
    /// request that produced it rather than to a segment several minutes of audio later.
    static func looksLikeAudioContainer(_ data: Data) -> Bool {
        let header = [UInt8](data.prefix(12))
        guard header.count >= 12 else { return false }
        // RIFF….WAVE
        if header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46 { return true }
        // ….ftyp (MPEG-4 / m4a / aac)
        if header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 { return true }
        // fLaC
        if header[0] == 0x66, header[1] == 0x4C, header[2] == 0x61, header[3] == 0x43 { return true }
        // OggS
        if header[0] == 0x4F, header[1] == 0x67, header[2] == 0x67, header[3] == 0x53 { return true }
        // ID3-tagged MP3
        if header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 { return true }
        // Bare MPEG audio frame sync (11 set bits)
        if header[0] == 0xFF, header[1] & 0xE0 == 0xE0 { return true }
        // AIFF/AIFC
        if header[0] == 0x46, header[1] == 0x4F, header[2] == 0x52, header[3] == 0x4D { return true }
        // CAF
        if header[0] == 0x63, header[1] == 0x61, header[2] == 0x66, header[3] == 0x66 { return true }
        return false
    }

    /// Hex plus printable ASCII of the first bytes. On a device this is the only record of
    /// what a provider actually sent when it did not send audio — an error page, a JSON
    /// quota notice, a truncated body all look identical in a decode failure otherwise.
    static func diagnosticHead(of data: Data, limit: Int = 32) -> String {
        let head = [UInt8](data.prefix(limit))
        let hex = head.map { String(format: "%02x", $0) }.joined()
        let ascii = String(head.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return "bytes=\(data.count) hex=\(hex) ascii=\(ascii)"
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

/// What a TTS provider actually sent back when it did not send audio.
///
/// Reading stops after three failed segments, and the anomaly that records it used to say only
/// `error=responsePostProcessingFailed` — true, and useless: it cannot tell a quota notice from
/// a login wall from a truncated body. The provider knows all of that at the moment it rejects
/// the response, so it is carried on the error and ends up in the anomaly's own detail.
///
/// Deliberately bounded and query-free, the same red line the book-source API log holds: the
/// endpoint without its query string (a TTS URL carries the user's API key there) and 200
/// characters of body.
struct TTSResponseDiagnostic: Equatable, Sendable, CustomStringConvertible {
    let endpoint: String
    let status: Int
    let contentType: String
    let byteCount: Int
    let bodyExcerpt: String

    static let excerptLimit = 200

    init(request: URLRequest, response: URLResponse?, data: Data) {
        let url = request.url
        endpoint = [url?.host, url?.path]
            .compactMap { $0 }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "-"
        byteCount = data.count
        bodyExcerpt = Self.excerpt(of: data)
    }

    /// The body as something a person can read. Text bodies — the quota notice, the JSON error,
    /// the login wall — are the whole point, so they are decoded and trimmed; anything else
    /// falls back to the byte head, which is what identifies a truncated or mislabelled audio
    /// container.
    private static func excerpt(of data: Data) -> String {
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else {
            return TTSAudioPayload.diagnosticHead(of: data)
        }
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return TTSAudioPayload.diagnosticHead(of: data) }
        return collapsed.count > excerptLimit
            ? String(collapsed.prefix(excerptLimit)) + "…"
            : collapsed
    }

    var description: String {
        "HTTP \(status) · \(endpoint) · \(byteCount) bytes · \(contentType) · \(bodyExcerpt)"
    }

    var logContext: [String: Any] {
        [
            "endpoint": endpoint,
            "status": status,
            "contentType": contentType,
            "bytes": byteCount,
            "body": bodyExcerpt
        ]
    }
}

enum TTSAudioProviderError: LocalizedError, CustomStringConvertible {
    case emptyTemplate
    case invalidURL
    /// The source's `@js:` template ran but produced nothing — a JS exception, a `null`
    /// return, or the engine's evaluation timeout. Kept distinct from `invalidURL` because
    /// the two have completely different causes and only the message reaches the user: one
    /// message for three branches made a report un-diagnosable.
    case jsTemplateProducedNothing
    /// The JS returned a string, but it could not be turned into a request (bad URL, or an
    /// options blob that failed to parse). Carries the head of that string.
    case jsResultNotRequestable(String)
    case emptyData
    /// Every response-shaped failure carries what came back, so the anomaly that ends the
    /// listening session names the actual cause instead of its own category.
    case badStatus(Int, TTSResponseDiagnostic)
    case responsePostProcessingFailed(TTSResponseDiagnostic)
    /// 200 OK, not obviously text, but not a container AVFoundation can open either —
    /// a truncated body, or a format the provider was not asked for.
    case unrecognisedAudioPayload(TTSResponseDiagnostic)

    var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            return "TTS URL template is empty"
        case .invalidURL:
            return "TTS URL template produced an invalid URL"
        case .jsTemplateProducedNothing:
            return "TTS source script returned no URL"
        case .jsResultNotRequestable(let head):
            return "TTS source script returned an unusable URL: \(head)"
        case .emptyData:
            return "TTS provider returned empty audio data"
        case .badStatus(_, let diagnostic):
            return "TTS provider rejected the request — \(diagnostic)"
        case .responsePostProcessingFailed(let diagnostic):
            return "TTS provider sent no usable audio — \(diagnostic)"
        case .unrecognisedAudioPayload(let diagnostic):
            return "TTS provider sent unrecognisable audio — \(diagnostic)"
        }
    }

    /// `HTTPTTSEngine` interpolates the error straight into the anomaly's detail, and the
    /// default enum reflection there would print the case name and a struct dump. Print what
    /// the reader needs to see instead.
    var description: String { errorDescription ?? "TTS provider failed" }
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
            return try await fetchAudioData(request: request, source: nil)
        }

        let template = GlobalSettings.shared.httpTtsUrlTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ttsLog("[TTS][Provider] template empty=\(template.isEmpty) textCount=\(text.count) title=\(title) rate=\(rate)")
        guard !template.isEmpty else {
            throw TTSAudioProviderError.emptyTemplate
        }

        let activeSource = GlobalSettings.shared.activeTTSSource

        var request: URLRequest
        if isJSTemplate(template) {
            request = try buildJSRequestOrThrow(
                template: template,
                text: text,
                title: title,
                rate: rate,
                source: activeSource
            )
        } else {
            guard let r = buildRequest(template: template, text: text, title: title, rate: rate) else {
                ttsLog("[TTS][Provider] invalid url template=\(template)")
                throw TTSAudioProviderError.invalidURL
            }
            request = r
        }

        for (field, value) in GlobalSettings.shared.httpTtsHeaders {
            if request.value(forHTTPHeaderField: field) == nil {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        ttsLog("[TTS][Provider] request method=\(request.httpMethod ?? "GET") url=\(request.url?.absoluteString ?? "")")

        return try await fetchAudioData(request: request, source: activeSource)
    }

    private func fetchAudioData(request: URLRequest, source: ImportedTTSSource?) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let responseContentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if let http = response as? HTTPURLResponse {
            let contentType = responseContentType
            ttsLog("[TTS][Provider] response status=\(http.statusCode) contentType=\(contentType) bytes=\(data.count)")
        } else {
            ttsLog("[TTS][Provider] response nonHTTP bytes=\(data.count)")
        }

        /// Records the rejection where the user can read it. `ttsLog` is `NSLog` only: it reaches
        /// Console on a tethered Mac and nothing else, which is why a stopped listening session
        /// left no trace in 診斷與回報 beyond the anomaly's own category name. Warning, not error —
        /// a single rejected segment is skipped and recovered from; the anomaly is what marks the
        /// run of them that ends playback.
        func reject(_ reason: String, _ error: TTSAudioProviderError) -> TTSAudioProviderError {
            let diagnostic = TTSResponseDiagnostic(request: request, response: response, data: data)
            ttsLog("[TTS][Provider] \(reason) \(diagnostic)")
            AppLogger.error(
                "[TTS] 語音段落被拒：\(reason)",
                context: diagnostic.logContext.merging(["source": source?.name ?? "-"]) { a, _ in a },
                level: .warning
            )
            return error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw reject(
                "HTTP 狀態碼錯誤",
                .badStatus(
                    http.statusCode,
                    TTSResponseDiagnostic(request: request, response: response, data: data)
                )
            )
        }
        guard !data.isEmpty else {
            throw reject("回應是空的", .emptyData)
        }

        if let source, let loginCheckJs = source.loginCheckJs, !loginCheckJs.isEmpty {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            if let processed = evaluateLoginCheckJs(loginCheckJs, responseBody: bodyStr, response: response) {
                ttsLog("[TTS][Provider] loginCheckJs extracted \(processed.count) bytes of audio")
                return processed
            }
        }

        // Applies to EVERY source, not just those carrying a `loginCheckJs`. This check used
        // to live inside that branch, so for the ordinary source a rate-limit or quota page
        // served with HTTP 200 was accepted as audio, cached, and only blew up in
        // `AVAudioFile(forReading:)` several segments later as
        // `kAudioFileError_InvalidFile` ('dta?', 1685348671). Three of those in a row ends
        // the listening session — the "朗讀失敗：第 N 段語音無法下載" report. Rejecting here
        // instead lets the existing retry → skip → three-strikes policy do its job.
        if responseLooksLikeTextPayload(data: data, contentType: responseContentType) {
            throw reject(
                "伺服器回的是文字不是音訊",
                .responsePostProcessingFailed(
                    TTSResponseDiagnostic(request: request, response: response, data: data)
                )
            )
        }
        if !TTSAudioPayload.looksLikeAudioContainer(data) {
            throw reject(
                "認不出這個音訊格式",
                .unrecognisedAudioPayload(
                    TTSResponseDiagnostic(request: request, response: response, data: data)
                )
            )
        }

        return data
    }

    private func responseLooksLikeTextPayload(data: Data, contentType: String) -> Bool {
        let loweredType = contentType.lowercased()
        if loweredType.contains("json") || loweredType.hasPrefix("text/") {
            return true
        }
        guard let text = String(data: Data(data.prefix(64)), encoding: .utf8) else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("<")
    }

    private func isJSTemplate(_ template: String) -> Bool {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("@js:") || t.hasPrefix("<js>")
    }

    private func buildJSRequestOrThrow(
        template: String,
        text: String,
        title: String,
        rate: Float,
        source: ImportedTTSSource?
    ) throws -> URLRequest {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsCode: String
        if trimmed.hasPrefix("@js:") {
            jsCode = String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("<js>") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 4)
            if let end = trimmed.range(of: "</js>", options: .backwards) {
                jsCode = String(trimmed[start..<end.lowerBound])
            } else {
                jsCode = String(trimmed[start...])
            }
        } else {
            ttsLog("[TTS][Provider] invalid js template=\(template.prefix(120))")
            throw TTSAudioProviderError.invalidURL
        }

        let sourceId = source?.id ?? ""
        let speed = legadoSpeakSpeed(for: rate)

        let engine = JSCoreEngine()

        // Wire up source bridge with login info
        engine.sourceBridge.getLoginInfoHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId).flatMap {
                guard let d = try? JSONSerialization.data(withJSONObject: $0),
                      let s = String(data: d, encoding: .utf8) else { return nil }
                return s
            }
        }
        engine.sourceBridge.getLoginInfoMapHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
        }
        engine.sourceBridge.putLoginInfoHandler = { info in
            if let d = info.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: dict)
            }
        }
        engine.sourceBridge.removeLoginInfoHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceId)
        }
        engine.sourceBridge.removeLoginHeaderHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceId)
        }

        var loginHeaders: [String: String] = [:]
        engine.sourceBridge.putLoginHeaderHandler = { header in
            if let d = header.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                loginHeaders.merge(dict) { _, new in new }
                LoginManager.shared.storeLoginHeaders(sourceUrl: sourceId, headers: dict)
            } else {
                var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
                info["__tts_header"] = header
                LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: info)
            }
        }
        engine.sourceBridge.getLoginHeaderHandler = {
            if let info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId),
               let state = info["__tts_header"] {
                return state
            }
            return LoginManager.shared.getLoginHeader(sourceUrl: sourceId)
        }
        engine.sourceBridge.getHeaderMapHandler = {
            LoginManager.shared.getLoginHeaders(sourceUrl: sourceId)
        }

        engine.sourceBridge.getVariableHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId)?["__tts_variable"]
        }
        engine.sourceBridge.setVariableHandler = { val in
            var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
            info["__tts_variable"] = val ?? ""
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: info)
        }

        engine.sourceBridge.getKeyValueHandler = { key in
            LoginManager.shared.getLoginInfo(sourceUrl: sourceId)?[key]
        }
        engine.sourceBridge.putKeyValueHandler = { key, value in
            var info = LoginManager.shared.getLoginInfo(sourceUrl: sourceId) ?? [:]
            info[key] = value
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceId, info: info)
        }

        // Shared helper functions the `url` rule calls live in `jsLib`, which is what Legado
        // injects into every rule evaluation (`BaseSource.evalJS`).
        //
        // This used to evaluate `loginUrl` here instead, and no Legado fork does that: upstream
        // runs `loginUrl` only from an explicit 登入 action (`BaseSource.login()`, which appends
        // its own `login()` call and throws `Function login not implements!!!` when there is
        // none) — never once per speech segment. Login state reaches a synthesis request the
        // way `AnalyzeUrl` delivers it, through the stored login header, applied below.
        // Running a login URL (or a JSON login descriptor) as JavaScript per segment produced
        // 337 `SyntaxError: Unexpected end of script` in one two-minute listening session,
        // every one of them dropped by a bare `_ =`.
        if let jsLib = source?.jsLib?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jsLib.isEmpty {
            _ = engine.evaluate(jsLib, result: nil, bindings: [:])
            // A jsLib that only declares functions completes with no value, so `nil` is not a
            // failure here — `lastError` is. Never silently discard it: a broken jsLib means the
            // url rule is about to fail with a confusing "produced nothing".
            if let error = engine.lastError {
                ttsLog("[TTS][Provider] jsLib failed source=\(source?.name ?? "-") error=\(error)")
                AppLogger.error("[TTS] 語音源 jsLib 執行失敗", context: [
                    "source": source?.name ?? "-",
                    "error": error
                ])
            }
        }

        // Prepare JS with speakText/speakSpeed bindings
        let bindings: [String: Any] = [
            "speakText": text,
            "speakSpeed": speed,
            "baseUrl": source?.urlTemplate ?? ""
        ]

        guard let result = engine.evaluate(jsCode, result: nil, bindings: bindings)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            // The script itself produced nothing. `JSCoreEngine.evaluate` collapses a JS
            // exception, a null return and its own 30s evaluation timeout into the same nil,
            // so report `lastError` alongside the source and text size: a thrown exception names
            // itself there, and its absence means the rule returned nothing or timed out.
            ttsLog("[TTS][Provider] JS evaluation returned empty result source=\(source?.name ?? "-") textCount=\(text.count) error=\(engine.lastError ?? "none")")
            AppLogger.error("[TTS] 語音源 url 規則沒有產生請求", context: [
                "source": source?.name ?? "-",
                "error": engine.lastError ?? "none",
                "textCount": text.count
            ])
            throw TTSAudioProviderError.jsTemplateProducedNothing
        }

        guard let request = AnalyzeUrl(ruleUrl: result, speakText: text, speakSpeed: speed).toURLRequest() else {
            ttsLog("[TTS][Provider] AnalyzeUrl failed to parse JS result: \(result.prefix(200))")
            throw TTSAudioProviderError.jsResultNotRequestable(String(result.prefix(80)))
        }

        // Login state reaches the request as headers, exactly like Legado's
        // `AnalyzeUrl(hasLoginHeader: true)` → `BaseSource.getHeaderMap` → `getLoginHeaderMap()`.
        // The stored header goes on first; anything the rule's own JS put there during this
        // evaluation is fresher and wins.
        var mutableRequest = request
        for (field, value) in LoginManager.shared.getLoginHeaders(sourceUrl: sourceId) {
            mutableRequest.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in loginHeaders {
            mutableRequest.setValue(value, forHTTPHeaderField: field)
        }
        return mutableRequest
    }

    /// Evaluate `loginCheckJs` against the HTTP response to extract audio data
    /// (e.g. base64-decoded audio from a JSON API response).
    /// Returns the extracted audio Data, or nil if no audio was decoded.
    private func evaluateLoginCheckJs(
        _ js: String,
        responseBody: String,
        response: URLResponse?
    ) -> Data? {
        var extractedData: Data?

        let engine = JSCoreEngine()
        engine.responseBase64Handler = { data, _ in
            extractedData = data
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        // Safely encode the response body as a JSON string literal for embedding in JS
        let bodyJsonData = (try? JSONSerialization.data(withJSONObject: responseBody, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""

        let wrappedJs = """
        (function() {
            var __responseBody = {
                string: function() { return \(bodyJsonData); }
            };
            var __body = function() { return __responseBody; };
            __body.string = __responseBody.string;
            var result = {
                code: function() { return \(statusCode); },
                body: __body
            };
            \(js)
        })();
        """

        _ = engine.evaluate(wrappedJs, result: nil, bindings: [:])
        // The script is allowed to extract nothing (many sources only refresh a login header),
        // so an empty result is not an error — a thrown exception is, and it used to vanish here
        // while the caller reported the response as "not audio".
        if let error = engine.lastError {
            ttsLog("[TTS][Provider] loginCheckJs failed error=\(error)")
            AppLogger.error("[TTS] 語音源 loginCheckJs 執行失敗", context: ["error": error])
        }
        return extractedData
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
        // Legado passes `speakSpeed = 語速滑桿 + 5`, so 10 == 1.0× and each unit is 0.1×.
        // Imported source JS (e.g. thresholds like `sp>14`/`sp<6`) is written against that
        // scale; UI rate 0.5 == 1.0× must therefore map to 10, and 200% to 20. The 0…50
        // clamp is Legado's own range: its rate seekbar is `android:max="45"`, so +5 tops
        // out at 50 == 5.0×, which is exactly `TTSCoordinator.maxSpeechRate`.
        let multiplier = Double(rate / 0.5)
        return max(0, min(50, Int((multiplier * 10).rounded())))
    }

    private func edgeTTSRateString(for rate: Float) -> String {
        let percentage = Int((((rate / 0.5) - 1) * 100).rounded())
        if percentage >= 0 {
            return "+\(percentage)%"
        }
        return "\(percentage)%"
    }
}
