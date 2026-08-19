import Foundation

typealias CloudflareChallengeHandler = @Sendable (URL) async throws -> String

actor WebFetcher {
    static let shared = WebFetcher()

    /// Nonisolated so the request/response path can run off the actor's executor.
    /// Only the Cloudflare challenge state below is genuinely actor-protected.
    nonisolated private let session: URLSession
    private var cloudflareChallengeHandler: CloudflareChallengeHandler?

    /// Per-host Cloudflare challenge barrier. When a challenge is in progress for a
    /// host, subsequent requests that also receive a CF error await this task instead
    /// of each launching their own challenge UI (thundering-herd prevention).
    private var pendingChallenges: [String: Task<Void, Error>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
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
            self.session = URLSession(configuration: config)
        }
    }

    func setCloudflareChallengeHandler(_ handler: CloudflareChallengeHandler?) {
        cloudflareChallengeHandler = handler
    }

    /// `nonisolated` on purpose. Request building and — above all — response decoding
    /// are pure work that used to run on the actor's serial executor, so every book
    /// source in a search fan-out decoded its HTML one at a time behind the others.
    /// Only the Cloudflare branches below hop onto the actor, and only when a
    /// challenge is actually detected.
    nonisolated func fetchHTML(
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
                try await self.session.data(for: request)
            }
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return try await handleNonSuccessStatus(
                    http.statusCode, request: request, url: url, host: host,
                    allowCFChallenge: allowInteractiveChallengeOn503, latencyMs: latencyMs
                )
            }

            guard let html = HTMLResponseDecoder.decode(data: data, response: response) else {
                throw FetchError.encodingError
            }

            if allowInteractiveChallengeOn503,
                LegadoJSBridge.isCloudflareChallengedBody(html),
                let challengeHandler = await self.cloudflareChallengeHandler
            {
                return try await retryAfterCloudflareChallenge(
                    handler: challengeHandler, originalRequest: request, url: url, host: host
                )
            }

            WebCrawlerDebugger.logResponse(
                url: url.absoluteString,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 200,
                htmlBody: html
            )
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
            WebCrawlerDebugger.logError(FetchError.httpError(statusCode), url: url.absoluteString)
            guard let challengeHandler = cloudflareChallengeHandler else {
                throw FetchError.cloudflareChallengeRequired(url.absoluteString)
            }
            return try await retryAfterCloudflareChallenge(
                handler: challengeHandler, originalRequest: request, url: url, host: host
            )
        }

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

        // Forced re-read, not the mirror: the challenge WebView has just written the
        // clearance cookie and this retry must carry exactly that value, so it must
        // not race the observer callback that refreshes the mirror.
        let retryCookies = await WebViewCookieMirror.shared.refreshedCookies(for: host)
        var retryRequest = originalRequest
        let retryCookieHeader = cookieHeaderString(from: retryCookies) ?? cookieHeader(for: url)
        retryRequest.setValue(retryCookieHeader, forHTTPHeaderField: "Cookie")

        let (retryData, retryResponse) = try await PerHostSemaphore.shared.withLock(host: host) { [retryRequest] in
            try await self.session.data(for: retryRequest)
        }
        guard let html = HTMLResponseDecoder.decode(data: retryData, response: retryResponse) else {
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
