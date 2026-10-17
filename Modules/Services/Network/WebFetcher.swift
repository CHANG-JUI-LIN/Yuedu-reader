import Foundation

/// A response as it arrived, status included — see `WebFetcher.fetchPage`.
struct FetchedPage {
    let request: URLRequest
    let data: Data
    let response: URLResponse
    let latencyMs: Int

    var statusCode: Int { (response as? HTTPURLResponse)?.statusCode ?? 200 }
}

actor WebFetcher {
    static let shared = WebFetcher()

    /// Nonisolated so the request/response path can run off the actor's executor.
    nonisolated private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.defaultSessionConfiguration())
    }

    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Matches `LegadoJSBridge.requestSession` (and Legado's own default
        // threadCount of 16). At 6 the native rule path throttled itself well
        // below the search fan-out width, so raising search concurrency alone
        // did nothing — the extra sources just queued on connections.
        config.httpMaximumConnectionsPerHost = 16
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .always
        // Source pages are parsed once and never read back from a URL cache; backed by
        // `URLCache.shared`, every cacheable response was a write to its Cache.db (Organizer's
        // disk-write reports, 2.0.7 (127)).
        config.urlCache = nil
        return config
    }

    /// `nonisolated` on purpose. Request building and — above all — response decoding
    /// are pure work that used to run on the actor's serial executor, so every book
    /// source in a search fan-out decoded its HTML one at a time behind the others.
    ///
    /// A response comes back as the site sent it. This used to take every 403 and 503 —
    /// and any page with Cloudflare markers — for a Cloudflare challenge and open a
    /// full-screen verification page from wherever the request came from: a chapter, the
    /// launch-time update, a 50,000-source 書源驗證 run, which then sat waiting for someone
    /// to solve it. Legado (both Legado-E and MD3) never opens a page on its own: the
    /// source's JS calls `java.startBrowserAwait`, or the reader opens the page from the
    /// reading menu (開啟網頁).
    nonisolated func fetchHTML(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String? = nil
    ) async throws -> String {
        let page = try await fetchPage(
            url: url, method: method, body: body,
            headers: headers, baseURL: baseURL, bodyCharset: bodyCharset
        )
        do {
            if !(200...299).contains(page.statusCode) {
                throw nonSuccessStatus(page.statusCode, url: url, latencyMs: page.latencyMs)
            }

            guard let html = HTMLResponseDecoder.decode(data: page.data, response: page.response) else {
                throw FetchError.encodingError
            }

            WebCrawlerDebugger.logResponse(
                url: url.absoluteString,
                statusCode: page.statusCode,
                htmlBody: html
            )
            ReaderTelemetry.shared.log(
                "fetch_done",
                attributes: [
                    "url": String(url.absoluteString.prefix(120)),
                    "statusCode": "\(page.statusCode)",
                    "bytes": "\((page.response as? HTTPURLResponse)?.expectedContentLength ?? Int64(html.utf8.count))",
                    "latencyMs": "\(page.latencyMs)",
                ]
            )
            return html
        } catch {
            WebCrawlerDebugger.logError(error, url: url.absoluteString)
            throw error
        }
    }

    /// One exchange, built exactly as `fetchHTML` builds it, with the status left to the
    /// caller: a non-2xx response comes back instead of being thrown. A source's
    /// `loginCheckJs` reads that response — its login wall, its Cloudflare page — before
    /// anything decides it failed (`BookSourceFetcher.fetchStageHTML`).
    ///
    /// - Parameter redirect: asked before each redirect is followed. A refused redirect is not
    ///   sent: its 3xx response comes back as the answer. Nil follows every redirect.
    nonisolated func fetchPage(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String? = nil,
        redirect: (@Sendable (URL) -> Bool)? = nil
    ) async throws -> FetchedPage {
        let request = await buildRequest(
            url: url, method: method, body: body,
            headers: headers, baseURL: baseURL, bodyCharset: bodyCharset
        )

        WebCrawlerDebugger.logRequest(
            url: url.absoluteString, method: method, headers: request.allHTTPHeaderFields ?? [:]
        )

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
                if let redirect {
                    return try await self.session.data(for: request, delegate: RedirectGate(allows: redirect))
                }
                return try await self.session.data(for: request)
            }
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)
            return FetchedPage(request: request, data: data, response: response, latencyMs: latencyMs)
        } catch {
            WebCrawlerDebugger.logError(error, url: url.absoluteString)
            throw error
        }
    }

    /// Assembles a fully-configured URLRequest, including harvested WebView cookies,
    /// custom headers, and optional POST body encoding.
    nonisolated private func buildRequest(
        url: URL,
        method: String,
        body: String?,
        headers: [String: String],
        baseURL: String,
        bodyCharset: String?
    ) async -> URLRequest {
        let allCookies: [HTTPCookie]
        if let host = url.host {
            allCookies = await WebViewCookieMirror.shared.cookies(for: host)
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
        if request.value(forHTTPHeaderField: "Cookie") == nil {
            // CookieStore is the durable Legado cookie jar. Native URLSession
            // storage can be empty after a cold launch even though a source's
            // login session is still persisted (e.g. shenmoxs.top
            // `admin_session`); reading it here prevents authenticated chapter
            // requests from incorrectly becoming HTTP 401.
            let persistedCookie = CookieStore.shared.get(url: url.absoluteString)
            if !persistedCookie.isEmpty {
                request.setValue(persistedCookie, forHTTPHeaderField: "Cookie")
            }
        }
        if let bodyStr = body, method == "POST" {
            let enc = HTMLResponseDecoder.encoding(forIANA: bodyCharset) ?? .utf8
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

    /// A non-2xx response, logged and turned into `FetchError.httpError`.
    nonisolated private func nonSuccessStatus(_ statusCode: Int, url: URL, latencyMs: Int) -> FetchError {
        let err = FetchError.httpError(statusCode)
        WebCrawlerDebugger.logError(err, url: url.absoluteString)
        ReaderTelemetry.shared.log(
            "fetch_error",
            attributes: [
                "url": String(url.absoluteString.prefix(120)),
                "statusCode": "\(statusCode)",
                "latencyMs": "\(latencyMs)",
            ]
        )
        return err
    }

    nonisolated private func cookieHeaderString(from cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    nonisolated private func cookieHeader(for url: URL) -> String? {
        let cookies = session.configuration.httpCookieStorage?.cookies(for: url) ?? HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }
}

/// Asks before a redirect is followed (`WebFetcher.fetchPage(redirect:)`).
private final class RedirectGate: NSObject, URLSessionTaskDelegate, Sendable {
    let allows: @Sendable (URL) -> Bool

    init(allows: @escaping @Sendable (URL) -> Bool) {
        self.allows = allows
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, allows(url) else { return nil }
        return request
    }
}
