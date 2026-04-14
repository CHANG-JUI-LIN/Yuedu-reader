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

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpMaximumConnectionsPerHost = 6
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpShouldSetCookies = true
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
        if let host = url.host {
            let allCookies = await Self.harvestWebViewCookies(for: host)
            for cookie in allCookies {
                session.configuration.httpCookieStorage?.setCookie(cookie)
                HTTPCookieStorage.shared.setCookie(cookie)
            }
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
        request.setValue(
            "zh-TW,zh;q=0.9,zh-CN;q=0.8,en;q=0.7",
            forHTTPHeaderField: "Accept-Language"
        )
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if !baseURL.isEmpty, let host = URL(string: baseURL)?.host, !host.isEmpty, url.host != nil {
            request.setValue(baseURL, forHTTPHeaderField: "Referer")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "Cookie") == nil,
            let cookieHeader = cookieHeader(for: url)
        {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let bodyStr = body, method == "POST" {
            let encoding = encoding(forIANA: bodyCharset) ?? .utf8
            request.httpBody = bodyStr.data(using: encoding)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                let charsetSuffix = bodyCharset.map { "; charset=\($0)" } ?? ""
                request.setValue(
                    "application/x-www-form-urlencoded\(charsetSuffix)",
                    forHTTPHeaderField: "Content-Type"
                )
            }
        }

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

        let requestCopy = request

        do {
            let (data, response) = try await PerHostSemaphore.shared.withLock(host: host) {
                try await self.session.data(for: requestCopy)
            }

            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 503 && allowInteractiveChallengeOn503 {
                    Task { @MainActor in
                        WebCrawlerDebugger.shared.logError(
                            FetchError.httpError(503),
                            url: url.absoluteString
                        )
                    }

                    guard let challengeHandler = cloudflareChallengeHandler else {
                        throw FetchError.cloudflareChallengeRequired(url.absoluteString)
                    }
                    let updatedHtml = try await challengeHandler(url)

                    if let host = url.host {
                        let allCookies = await Self.harvestWebViewCookies(for: host)
                        for cookie in allCookies {
                            session.configuration.httpCookieStorage?.setCookie(cookie)
                        }
                    }

                    return updatedHtml
                }

                let err = FetchError.httpError(http.statusCode)
                Task { @MainActor in
                    WebCrawlerDebugger.shared.logError(err, url: url.absoluteString)
                }
                ReaderTelemetry.shared.log(
                    "fetch_error",
                    attributes: [
                        "url": String(url.absoluteString.prefix(120)),
                        "statusCode": "\(http.statusCode)",
                        "latencyMs": "\(latencyMs)",
                    ]
                )
                throw err
            }

            if let html = smartDecode(data: data, response: response) {
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
            }

            throw FetchError.encodingError
        } catch {
            Task { @MainActor in
                WebCrawlerDebugger.shared.logError(error, url: url.absoluteString)
            }
            throw error
        }
    }

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

        let sniff = String(data: data.prefix(4096), encoding: .isoLatin1) ?? ""
        appendCandidate(encoding(forIANA: metaCharset(sniff)), priority: 340)

        appendCandidate(.utf8, priority: 260)
        appendCandidate(gbkEncoding, priority: 240)
        appendCandidate(cfEncoding(CFStringEncodings.big5), priority: 235)
        appendCandidate(.windowsCP1252, priority: 180)
        appendCandidate(.isoLatin1, priority: 120)

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

    private func decodeQualityScore(_ text: String) -> Int {
        if text.isEmpty { return -10_000 }

        var score = 0

        let replacementCount = text.reduce(into: 0) { partialResult, character in
            if character == "\u{FFFD}" { partialResult += 1 }
        }
        score -= replacementCount * 80

        let suspiciousTokens = [
            "锟斤拷", "Ã", "Â", "â€", "â€œ", "â€”", "ï»¿", "\u{FFFD}",
        ]
        for token in suspiciousTokens {
            score -= text.components(separatedBy: token).count > 1 ? 120 : 0
        }

        let controlCount = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if CharacterSet.controlCharacters.contains(scalar),
                scalar != "\n", scalar != "\r", scalar != "\t"
            {
                partialResult += 1
            }
        }
        score -= controlCount * 25

        let cjkCount = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF:
                partialResult += 1
            default:
                break
            }
        }
        score += min(cjkCount, 200)

        let htmlHints = ["<html", "<body", "</html>", "<meta", "<title"]
        for hint in htmlHints where text.localizedCaseInsensitiveContains(hint) {
            score += 20
        }

        let newlineCount = text.reduce(into: 0) { partialResult, character in
            if character == "\n" { partialResult += 1 }
        }
        score += min(newlineCount, 40)

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
        let patterns = [
            #"<meta[^>]+charset\s*=\s*["\']?\s*([A-Za-z0-9_\-]+)"#,
            #"charset\s*=\s*["\']?\s*([A-Za-z0-9_\-]+)"#,
        ]
        let lower = html.lowercased()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
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

    private func cookieHeader(for url: URL) -> String? {
        let cookies = session.configuration.httpCookieStorage?.cookies(for: url) ?? HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }
}
