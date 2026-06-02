import Foundation
import WebKit

typealias CloudflareChallengeHandler = @Sendable (URL) async throws -> String

actor WebFetcher {
    static let shared = WebFetcher()

    private let session: URLSession
    private var cloudflareChallengeHandler: CloudflareChallengeHandler?
    private let gbkEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// Per-host Cloudflare challenge barrier. When a challenge is in progress for a
    /// host, subsequent requests that also receive a CF error await this task instead
    /// of each launching their own challenge UI (thundering-herd prevention).
    private var pendingChallenges: [String: Task<Void, Error>] = [:]

    /// Pre-compiled charset detection patterns. Compiled once at app start; reused
    /// for every `smartDecode` call to avoid O(n_requests × n_patterns) compilations.
    private static let metaCharsetRegexes: [NSRegularExpression] = [
        // <meta … charset="utf-8"> or <meta charset=utf-8>
        try! NSRegularExpression(
            pattern: #"<meta[^>]+charset\s*=\s*["\']?\s*([A-Za-z0-9_\-]+)"#
        ),
        // Fallback: bare charset= anywhere in the sniff window
        try! NSRegularExpression(
            pattern: #"charset\s*=\s*["\']?\s*([A-Za-z0-9_\-]+)"#
        ),
    ]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpMaximumConnectionsPerHost = 6
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .always
            self.session = URLSession(configuration: config)
        }
    }

    func setCloudflareChallengeHandler(_ handler: CloudflareChallengeHandler?) {
        cloudflareChallengeHandler = handler
    }

    func fetchHTML(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String? = nil,
        allowInteractiveChallengeOn503: Bool = true
    ) async throws -> String {
        let request = await buildRequest(
            url: url, method: method, body: body,
            headers: headers, baseURL: baseURL, bodyCharset: bodyCharset
        )

        Task { @MainActor in
            WebCrawlerDebugger.shared.logRequest(
                url: url.absoluteString, method: method, headers: request.allHTTPHeaderFields ?? [:]
            )
        }

        let host = url.host ?? "default"
        let fetchStart = CFAbsoluteTimeGetCurrent()
        ReaderTelemetry.shared.log(
            "fetch_start",
            attributes: [
                "url": String(url.absoluteString.prefix(120)),
                "host": host,
                "method": method,
            ]
        )

        do {
            let (data, response) = try await PerHostSemaphore.shared.withLock(host: host) {
                try await self.session.data(for: request)
            }
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return try await handleNonSuccessStatus(
                    http.statusCode, request: request, url: url, host: host,
                    allowCFChallenge: allowInteractiveChallengeOn503, latencyMs: latencyMs
                )
            }

            guard let html = smartDecode(data: data, response: response) else {
                throw FetchError.encodingError
            }

            if allowInteractiveChallengeOn503,
                LegadoJSBridge.isCloudflareChallengedBody(html),
                let challengeHandler = cloudflareChallengeHandler
            {
                return try await retryAfterCloudflareChallenge(
                    handler: challengeHandler, originalRequest: request, url: url, host: host
                )
            }

            Task { @MainActor in
                WebCrawlerDebugger.shared.logResponse(
                    url: url.absoluteString,
                    statusCode: (response as? HTTPURLResponse)?.statusCode ?? 200,
                    htmlBody: html
                )
            }
            ReaderTelemetry.shared.log(
                "fetch_done",
                attributes: [
                    "url": String(url.absoluteString.prefix(120)),
                    "statusCode": "\((response as? HTTPURLResponse)?.statusCode ?? 200)",
                    "bytes": "\((response as? HTTPURLResponse)?.expectedContentLength ?? Int64(html.utf8.count))",
                    "latencyMs": "\(latencyMs)",
                ]
            )
            return html

        } catch {
            Task { @MainActor in
                WebCrawlerDebugger.shared.logError(error, url: url.absoluteString)
            }
            throw error
        }
    }

    /// Assembles a fully-configured URLRequest, including harvested WebView cookies,
    /// custom headers, and optional POST body encoding.
    private func buildRequest(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String?
    ) async -> URLRequest {
        let allCookies: [HTTPCookie]
        if let host = url.host {
            allCookies = await Self.harvestWebViewCookies(for: host)
        } else {
            allCookies = []
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-TW,zh;q=0.9,zh-CN;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if !baseURL.isEmpty, let host = URL(string: baseURL)?.host, !host.isEmpty, url.host != nil {
            request.setValue(baseURL, forHTTPHeaderField: "Referer")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let wvCookieHeader = cookieHeaderString(from: allCookies) {
            request.setValue(wvCookieHeader, forHTTPHeaderField: "Cookie")
        }
        if request.value(forHTTPHeaderField: "Cookie") == nil,
            let cookieHeader = cookieHeader(for: url)
        {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let bodyStr = body, method == "POST" {
            let enc = encoding(forIANA: bodyCharset) ?? .utf8
            request.httpBody = bodyStr.data(using: enc)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                let charsetSuffix = bodyCharset.map { "; charset=\($0)" } ?? ""
                request.setValue(
                    "application/x-www-form-urlencoded\(charsetSuffix)",
                    forHTTPHeaderField: "Content-Type"
                )
            }
        }
        return request
    }

    /// Handles a non-2xx HTTP status code. Triggers Cloudflare challenge on 503/403
    /// if a handler is registered; otherwise throws `FetchError.httpError`.
    private func handleNonSuccessStatus(
        _ statusCode: Int,
        request: URLRequest,
        url: URL,
        host: String,
        allowCFChallenge: Bool,
        latencyMs: Int
    ) async throws -> String {
        let isCFError = (statusCode == 503 || statusCode == 403) && allowCFChallenge
        if isCFError {
            Task { @MainActor in
                WebCrawlerDebugger.shared.logError(FetchError.httpError(statusCode), url: url.absoluteString)
            }
            guard let challengeHandler = cloudflareChallengeHandler else {
                throw FetchError.cloudflareChallengeRequired(url.absoluteString)
            }
            return try await retryAfterCloudflareChallenge(
                handler: challengeHandler, originalRequest: request, url: url, host: host
            )
        }

        let err = FetchError.httpError(statusCode)
        Task { @MainActor in
            WebCrawlerDebugger.shared.logError(err, url: url.absoluteString)
        }
        ReaderTelemetry.shared.log(
            "fetch_error",
            attributes: [
                "url": String(url.absoluteString.prefix(120)),
                "statusCode": "\(statusCode)",
                "latencyMs": "\(latencyMs)",
            ]
        )
        throw err
    }

    /// Presents a Cloudflare challenge, harvests the resulting cookies, then replays
    /// the original request with those cookies injected.
    ///
    /// A per-host barrier prevents a thundering herd: if a challenge is already in
    /// progress for `host`, this method awaits it instead of launching a second one.
    /// At most one challenge UI is shown per host at any given time.
    private func retryAfterCloudflareChallenge(
        handler: @escaping CloudflareChallengeHandler,
        originalRequest: URLRequest,
        url: URL,
        host: String
    ) async throws -> String {
        try await resolveCloudflareChallenge(handler: handler, url: url, host: host)

        let retryCookies = await Self.harvestWebViewCookies(for: host)
        var retryRequest = originalRequest
        let retryCookieHeader = cookieHeaderString(from: retryCookies) ?? cookieHeader(for: url)
        retryRequest.setValue(retryCookieHeader, forHTTPHeaderField: "Cookie")

        let (retryData, retryResponse) = try await PerHostSemaphore.shared.withLock(host: host) { [retryRequest] in
            try await self.session.data(for: retryRequest)
        }
        guard let html = smartDecode(data: retryData, response: retryResponse) else {
            throw FetchError.emptyContent
        }
        return html
    }

    /// Ensures exactly one Cloudflare challenge UI runs per host at a time.
    /// Concurrent callers for the same host await the first challenge task;
    /// once it resolves (success or failure) they all proceed to retry with
    /// the freshly harvested CF cookies.
    private func resolveCloudflareChallenge(
        handler: @escaping CloudflareChallengeHandler,
        url: URL,
        host: String
    ) async throws {
        if let existing = pendingChallenges[host] {
            try await existing.value
            return
        }

        let challengeTask = Task<Void, Error> { _ = try await handler(url) }
        pendingChallenges[host] = challengeTask
        do {
            try await challengeTask.value
            pendingChallenges.removeValue(forKey: host)
        } catch {
            pendingChallenges.removeValue(forKey: host)
            throw error
        }
    }

    /// Multi-strategy charset detection with scoring for ambiguous encodings.
    private func smartDecode(data: Data, response: URLResponse) -> String? {
        struct DecodeCandidate {
            let encoding: String.Encoding
            let priority: Int
        }

        var candidates: [DecodeCandidate] = []
        var seen = Set<UInt>()

        func appendCandidate(_ encoding: String.Encoding?, priority: Int) {
            guard let encoding else { return }
            guard seen.insert(encoding.rawValue).inserted else { return }
            candidates.append(DecodeCandidate(encoding: encoding, priority: priority))
        }

        appendCandidate(bomEncoding(in: data), priority: 500)
        appendCandidate(encoding(forIANA: response.textEncodingName), priority: 380)

        if let http = response as? HTTPURLResponse,
            let ct = http.value(forHTTPHeaderField: "Content-Type")
        {
            appendCandidate(encoding(forIANA: charsetInHeader(ct)), priority: 360)
        }

        let sniff = String(data: data.prefix(DecodeScoreWeights.sampleSize), encoding: .isoLatin1) ?? ""
        appendCandidate(encoding(forIANA: metaCharset(sniff)), priority: 340)

        appendCandidate(.utf8, priority: 260)
        appendCandidate(gbkEncoding, priority: 240)
        appendCandidate(cfEncoding(CFStringEncodings.big5), priority: 235)
        appendCandidate(.windowsCP1252, priority: 180)
        appendCandidate(.isoLatin1, priority: 120)

        // Short-circuit: if a high-confidence candidate decodes cleanly, return immediately
        let highConfidence = candidates.filter { $0.priority >= 340 }
        for candidate in highConfidence {
            guard let decoded = String(data: data, encoding: candidate.encoding) else { continue }
            let replacements = decoded.unicodeScalars.filter { $0.value == 0xFFFD }.count
            let ratio = Double(replacements) / Double(max(decoded.unicodeScalars.count, 1))
            if ratio < 0.0001 {
                return decoded
            }
        }

        var best: (text: String, score: Int)?
        for candidate in candidates {
            guard let decoded = String(data: data, encoding: candidate.encoding) else { continue }
            let score = candidate.priority + decodeQualityScore(decoded)
            if best == nil || score > best!.score {
                best = (decoded, score)
            }
        }
        return best?.text
    }

    private func bomEncoding(in data: Data) -> String.Encoding? {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return .utf8
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return .unicode
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return .utf16LittleEndian
        }
        return nil
    }

    // Scoring weights used by decodeQualityScore.
    private enum DecodeScoreWeights {
        /// Penalty per U+FFFD replacement character.
        static let replacementChar = 80

        /// Penalty when a known mojibake token appears in the sample.
        /// Tokens such as "锟斤拷" or "â€" only appear when code-pages are mixed.
        static let mojibakeToken = 120

        /// Penalty per unexpected control character (non-whitespace).
        static let controlChar = 25

        /// Cap on the CJK character bonus.
        static let maxCJKBonus = 200

        /// Bonus per recognised HTML structural tag (e.g. <html>, <body>).
        static let htmlTagBonus = 20

        /// Cap on the newline bonus.
        static let maxNewlineBonus = 40

        /// Score returned immediately for an empty sample.
        static let emptyStringSentinel = -10_000

        /// Number of leading characters sampled from the document.
        static let sampleSize = 4096
    }

    private func decodeQualityScore(_ text: String) -> Int {
        let sample = text.count > DecodeScoreWeights.sampleSize
            ? String(text.prefix(DecodeScoreWeights.sampleSize))
            : text
        if sample.isEmpty { return DecodeScoreWeights.emptyStringSentinel }

        var score = 0

        let replacementCount = sample.unicodeScalars.filter { $0.value == 0xFFFD }.count
        score -= replacementCount * DecodeScoreWeights.replacementChar

        let suspiciousTokens = ["锟斤拷", "Ã", "Â", "â€", "â€œ", "â€\u{201D}", "ï»¿", "\u{FFFD}"]
        for token in suspiciousTokens {
            score -= sample.components(separatedBy: token).count > 1 ? DecodeScoreWeights.mojibakeToken : 0
        }

        let controlCount = sample.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        score -= controlCount * DecodeScoreWeights.controlChar

        let cjkCount = sample.unicodeScalars.filter {
            switch $0.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF: return true
            default: return false
            }
        }.count
        score += min(cjkCount, DecodeScoreWeights.maxCJKBonus)

        let htmlHints = ["<html", "<body", "</html>", "<meta", "<title"]
        for hint in htmlHints where sample.localizedCaseInsensitiveContains(hint) {
            score += DecodeScoreWeights.htmlTagBonus
        }

        let newlineCount = sample.filter { $0 == "\n" }.count
        score += min(newlineCount, DecodeScoreWeights.maxNewlineBonus)

        return score
    }

    private func charsetInHeader(_ contentType: String) -> String? {
        let lower = contentType.lowercased()
        guard let r = lower.range(of: "charset=") else { return nil }
        let tail = lower[r.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let name = tail.components(separatedBy: CharacterSet(charactersIn: " ;,\"'")).first ?? ""
        return name.isEmpty ? nil : name
    }

    private func metaCharset(_ html: String) -> String? {
        let lower = html.lowercased()
        let nsLower = lower as NSString
        let fullRange = NSRange(location: 0, length: nsLower.length)
        for regex in Self.metaCharsetRegexes {
            guard let match = regex.firstMatch(in: lower, range: fullRange),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: lower)
            else { continue }
            return String(lower[range])
        }
        return nil
    }

    private func encoding(forIANA name: String?) -> String.Encoding? {
        guard let n = name?.lowercased().trimmingCharacters(in: .whitespaces), !n.isEmpty else {
            return nil
        }
        switch n {
        case "utf-8", "utf8", "unicode-1-1-utf-8": return .utf8
        case "gbk", "gb2312", "gb_2312", "csgb2312", "x-gbk", "gb18030", "gb-18030", "gb_18030":
            return gbkEncoding
        case "big5", "big5-hkscs", "csbig5", "x-x-big5":
            return cfEncoding(CFStringEncodings.big5)
        case "iso-8859-1", "iso8859-1", "latin1", "iso_8859-1", "csisolatin1":
            return .isoLatin1
        case "windows-1252", "cp1252", "x-cp1252":
            return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji":
            return cfEncoding(CFStringEncodings.shiftJIS)
        case "euc-jp", "x-euc-jp", "cseucpkdfmtjapanese":
            return cfEncoding(CFStringEncodings.EUC_JP)
        case "iso-2022-jp":
            return cfEncoding(CFStringEncodings.ISO_2022_JP)
        case "euc-kr", "x-euc-kr", "cseuckr", "ks_c_5601-1987":
            return cfEncoding(CFStringEncodings.EUC_KR)
        case "windows-1251", "cp1251", "x-cp1251":
            return cfEncoding(CFStringEncodings.windowsCyrillic)
        case "koi8-r", "koi8r":
            return cfEncoding(CFStringEncodings.KOI8_R)
        case "koi8-u":
            return cfEncoding(CFStringEncodings.KOI8_U)
        default:
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            guard cfEnc != kCFStringEncodingInvalidId else { return nil }
            return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        }
    }

    private func cfEncoding(_ enc: CFStringEncodings) -> String.Encoding {
        .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc.rawValue)))
    }

    @MainActor
    private static func harvestWebViewCookies(for host: String) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter { $0.domain.contains(host) })
            }
        }
    }

    private func cookieHeaderString(from cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func cookieHeader(for url: URL) -> String? {
        let cookies = session.configuration.httpCookieStorage?.cookies(for: url) ?? HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }
}
