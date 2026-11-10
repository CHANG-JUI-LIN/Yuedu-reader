import Foundation
import JavaScriptCore
import os
import CryptoKit
import CommonCrypto
import Network
import UIKit
import zlib

/// A source-authored browser page passed through Legado's four-argument
/// `java.showBrowser(url, html, injectedJS, configuration)` contract.
struct LegadoBrowserPageRequest: Equatable, Sendable {
    let baseURL: String
    /// The page the source built, or nil when it passed none (`showBrowser(url, null, js,
    /// config)`): then `baseURL` itself is the page to open, as legado's
    /// `BottomWebViewDialog` fetches it. Showing "" with `baseURL` as its base instead was the
    /// 段評 white screen (知秋 起点段评, 聚合段评; 2026-10-10).
    let html: String?
    let injectedJavaScript: String
    let configurationJSON: String
}

/// A page source JS asked to open: Legado `java.startBrowser` / `java.startBrowserAwait`.
struct SourceBrowserRequest {
    /// The URL as the source wrote it — possibly with Legado `,{options}`, or a `data:` page.
    let url: String
    let title: String
    /// `url` carrying the source's headers, login headers and cookie jar, the way Legado's
    /// `WebViewModel` loads it (`AnalyzeUrl(url, source).headerMap`). nil when `url` is not
    /// http(s) — a `data:` page has nothing to send.
    let urlRequest: URLRequest?
    /// Opened by `java.startBrowserAwait`, whose script waits for the page. Legado calls this
    /// `sourceVerificationEnable`: such a page finishes by itself once a Cloudflare challenge
    /// on it clears.
    let awaitsResult: Bool
    /// Page HTML the source supplied (`startBrowser(url, title, html)`,
    /// `startBrowserAwait(url, title, refetchAfterSuccess, html)`), shown with `url` as its
    /// base instead of loading `url`.
    var html: String? = nil
    /// Set when a script waits on the page; the presenter takes it away early through this
    /// (`LegadoUserWaitRegistry.cancelAll`).
    var withdrawal: SourceWaitWithdrawal? = nil
}

/// How whoever shows a page or captcha a script is waiting on hears that the wait was ended
/// from outside — a source-validation run's time ran out — so the sheet does not stay up with
/// nobody waiting behind it. The presenter installs `onWithdraw`; it runs once, on the main
/// queue, at once if the wait already ended.
final class SourceWaitWithdrawal: Sendable {
    private let state = OSAllocatedUnfairLock<(withdrawn: Bool, handler: (@Sendable @MainActor () -> Void)?)>(
        initialState: (false, nil)
    )

    var isWithdrawn: Bool { state.withLock { $0.withdrawn } }

    func onWithdraw(_ handler: @escaping @Sendable @MainActor () -> Void) {
        let runNow = state.withLock { state -> Bool in
            guard !state.withdrawn else { return true }
            state.handler = handler
            return false
        }
        if runNow { Task { @MainActor in handler() } }
    }

    func withdraw() {
        let handler = state.withLock { state -> (@Sendable @MainActor () -> Void)? in
            guard !state.withdrawn else { return nil }
            state.withdrawn = true
            defer { state.handler = nil }
            return state.handler
        }
        if let handler { Task { @MainActor in handler() } }
    }
}

/// A link source JS asked the system to open: Legado `java.openUrl(url[, mimeType])`.
struct SourceOpenURLRequest: Sendable {
    let url: URL
    /// Legado hands it to Android's intent; iOS opens by URL alone, so it is only logged.
    let mimeType: String?
    let sourceName: String

    /// legado-E sends `legado://` and `yuedu://` links to its importer instead of the system.
    /// The same parser `onOpenURL` reads them with decides which those are.
    var isImportLink: Bool { BookSourceImportDeepLink.target(from: url) != nil }
}

/// A code the source asks the reader to read off an image: Legado
/// `java.getVerificationCode(imageUrl)`.
struct SourceCaptchaRequest {
    /// `http(s)` or `data:` — a few sources draw their code as an SVG data URI.
    let imageURL: String
    /// The source's headers and cookie jar for fetching the image. A captcha belongs to the
    /// session that fetched it, and the source's next request carries that session.
    let headers: [String: String]
    let sourceName: String
    let sourceURL: String
    var withdrawal: SourceWaitWithdrawal? = nil
}

extension Notification.Name {
    /// A book source's JS asked the app to search for a keyword
    /// (`java.searchBook` / `java.open('search', …)`). `userInfo["keyword"]`.
    static let bookSourceRequestedSearch = Notification.Name("bookSourceRequestedSearch")
    /// A source's `java.openUrl` named an import link (`legado://import/…`, `yuedu://…`).
    /// `userInfo["url"]` is the `URL`; the app handles it as it does one from `onOpenURL`.
    static let sourceRequestedImportLink = Notification.Name("sourceRequestedImportLink")
}

/// A `java.*` request on the AnalyzeUrl route (`url,{…}`, `data:`), split where its JS ends.
///
/// `java.ajaxAll` holds the engine's JS queue while its workers run, so nothing a worker does may
/// reach that queue. The AnalyzeUrl handler builds this on the JS thread, which is where the URL's
/// own JS runs: `{{…}}` templates, `@js:` / `<js>`, the `js` option, the source headers. `fetch` is
/// the network alone — `ajaxAll`'s workers call it, several at once — and `finish` runs on the JS
/// thread again, for the response's `bodyJs`. A single `java.ajax` runs the three in a row there.
struct PreparedSourceRequest {
    struct Response: Sendable {
        let body: String
        /// Where the response came from; `bodyJs` reads it as `baseUrl`.
        let url: String
        /// The bytes `body` was read from, for `java.downloadFile`; `nil` for a `data:` URI.
        var data: Data? = nil
        var transportError: (any Error)? = nil
        /// The HTTP response itself — where a redirect landed, its status, headers and cookies —
        /// which `java.connect` and `java.ajaxAll` hand the script as their `StrResponse`.
        /// `nil` for a `data:` URI or a WebView page, which have none.
        var http: LegadoHTTPResult? = nil
    }

    /// Network only, on any thread; must never reach the JS queue. `nil` when the request failed.
    let fetch: () -> Response?
    /// JS thread only. `nil` when the response's transform failed.
    let finish: (Response) -> String?
    /// The URL's `type` option (`url,{"type":"mp3"}`): `java.downloadFile` names the file by it.
    var type: String? = nil
}

/// The waits for the user (`java.startBrowserAwait`, `getVerificationCode`) a source's
/// scripts are parked in, each endable from outside the script's thread.
///
/// A script waiting for the user is exempt from the runaway-script timeout, and an
/// interactive reader needs that. A source-validation run does not wait: its per-source
/// timeout ended the check but not the wait, so the script — and the validation worker
/// behind it — stayed parked for as long as the page was up (茶杯狐狸, over ten minutes
/// past a 180-second limit, YCK1330 report). The run now ends the source's waits when its
/// time is up (`BookSourceHealthChecker`).
final class LegadoUserWaitRegistry: Sendable {
    private let waits = OSAllocatedUnfairLock<[UUID: @Sendable () -> Void]>(initialState: [:])

    var isWaiting: Bool { waits.withLock { !$0.isEmpty } }

    func register(_ cancel: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        waits.withLock { $0[token] = cancel }
        return token
    }

    func unregister(_ token: UUID) {
        _ = waits.withLock { $0.removeValue(forKey: token) }
    }

    /// Answers every wait in progress as dismissed. Their scripts go on, and raise the
    /// dismissal (`browser cancelled`) as they do when the user closes the page.
    func cancelAll() {
        let cancels = waits.withLock { waits -> [@Sendable () -> Void] in
            defer { waits.removeAll() }
            return Array(waits.values)
        }
        cancels.forEach { $0() }
    }
}

/// Whether a `java.*` request follows HTTP redirects.
///
/// Legado-E's `java.get`, `java.head` and `java.post` are jsoup requests with
/// `followRedirects(false)` (`JsExtensions.get/head/post`): sources call them to read a
/// redirect's `Location` header — the 3xx response itself is the result. Every other request
/// (`java.ajax`, `java.connect`, the okhttp shim) follows redirects. The flag rides on the
/// request so the runtime's transport, which owns the session, honours it too.
enum LegadoRedirectPolicy {
    private static let propertyKey = "YueduLegadoRefusesRedirects"

    static func refusingRedirects(_ request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.setProperty(true, forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }

    static func refusesRedirects(_ request: URLRequest) -> Bool {
        (URLProtocol.property(forKey: propertyKey, in: request) as? Bool) == true
    }
}

/// A request whose answer is bytes, not a page: a URL with Legado's `type` option
/// (`url,{"type":"hex"}`, `java.downloadFile(url)` of such a URL), which Legado answers with the
/// hex of the body. It is read up to `WebFetcher.binaryResponseByteLimit` instead of the page
/// limit. The mark rides on the request, as `LegadoRedirectPolicy`'s does, through whatever
/// transport a runtime installs.
enum LegadoBinaryDownload {
    private static let propertyKey = "YueduLegadoBinaryDownload"

    static func marking(_ request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.setProperty(true, forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }

    static func isMarked(_ request: URLRequest) -> Bool {
        (URLProtocol.property(forKey: propertyKey, in: request) as? Bool) == true
    }

    static func byteLimit(for request: URLRequest) -> Int {
        isMarked(request) ? WebFetcher.binaryResponseByteLimit : WebFetcher.responseByteLimit
    }
}

extension URLSession {
    /// A data task that honours `LegadoRedirectPolicy`. Every `java.*` request is sent through
    /// this, by the bridge itself and by the transport a runtime installs.
    ///
    /// The body is read up to `WebFetcher.responseByteLimit`, as every page a source reads is
    /// (`BoundedResponseLoader`), or a binary download's larger limit (`LegadoBinaryDownload`):
    /// a larger one reaches the script as a failed request.
    ///
    /// It goes out with the headers of the Legado client it stands for — okhttp's, or a
    /// `java.get`/`head`/`post`'s jsoup ones (`LegadoOutgoingHeaders`).
    func legadoDataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> any SourceRequestTask {
        let request = LegadoOutgoingHeaders.prepared(request, as: LegadoOutgoingHeaders.client(of: request))
        // A refused redirect is not sent: the task completes with the 3xx response.
        let redirect: (@Sendable (URL) -> Bool)?
        if LegadoRedirectPolicy.refusesRedirects(request) {
            redirect = { _ in false }
        } else {
            redirect = nil
        }
        return BoundedResponseLoader.dataTask(
            with: request, session: self, limit: LegadoBinaryDownload.byteLimit(for: request),
            redirect: redirect, transport: "jsBridge", completionHandler: completionHandler
        )
    }
}

/// One runtime's scripts blocked on something outside them, and for how long: the network (a
/// request, a `java.ajaxAll` batch, a headless `java.webView` page) or the reader (a
/// `startBrowserAwait` page, a captcha). A request waits up to `WebFetcher.sourceRequestTimeout`
/// (60 s, Legado's OkHttp `readTimeout`/`callTimeout`) and the reader's sheet always ends, so the
/// engine's 30 s runaway-script timeout counts none of this time (`JSCoreEngine.onJSQueueWithTimeout`).
/// Legado has no script timeout; the request's own bounds the wait. Only the waits are counted —
/// a URL's own JS, built before its request, stays under the runaway timeout.
final class LegadoScriptWaits: Sendable {
    private struct State {
        var count = 0
        /// When `count` last went from 0 to 1.
        var since: UInt64 = 0
        /// The waits that have ended, overlapping ones (`ajaxAll`'s workers) counted once.
        var ended: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isWaiting: Bool { state.withLock { $0.count > 0 } }

    /// The time spent waiting so far, the wait in progress included.
    var waitedSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let nanos = state.withLock { $0.ended + ($0.count > 0 ? now - $0.since : 0) }
        return TimeInterval(nanos) / 1_000_000_000
    }

    func during<T>(_ wait: () -> T) -> T {
        state.withLock { state in
            if state.count == 0 { state.since = DispatchTime.now().uptimeNanoseconds }
            state.count += 1
        }
        defer {
            state.withLock { state in
                state.count -= 1
                if state.count == 0 { state.ended += DispatchTime.now().uptimeNanoseconds - state.since }
            }
        }
        return wait()
    }
}

/// The transport every `java.*` request goes through when a runtime installs one.
///
/// `declaredCharset` is the AnalyzeUrl `charset` option (`url,{"charset":"gbk"}`), `nil` for a
/// request that names none. The transport decodes the body itself, so the option has to reach
/// it: Legado decodes with it (`AnalyzeUrl.getStrResponse`), and detection alone misreads a
/// page whose encoding it cannot tell apart, such as Big5 bytes that are also valid GBK.
typealias SourceScriptTransport = (URLRequest, _ declaredCharset: String?) -> LegadoHTTPResult?

/// Complete response payload captured from the same request that produced the body.
/// Response-shaped JavaScript APIs retain this metadata; string-shaped APIs consume
/// only `body` without issuing a second request.
struct LegadoHTTPResult {
    /// The URL the response came from, after redirects: okhttp's `Response.request().url()`,
    /// which is also what `StrResponse.url()` reads.
    let finalURL: URL
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let cookies: [String: String]
    let body: String
    /// The response's bytes as they arrived; `nil` for a result built from text alone. Legado
    /// reads them for a request with a `type` option (the body is their hex) and for
    /// `java.downloadFile`, where decoding to text first would corrupt them.
    var data: Data? = nil
    /// Why no response arrived. `java.ajaxTestAll` reports it as Legado's error code.
    var transportError: (any Error)? = nil
    /// The URL the request asked for, which `urlString` reads a fragment from.
    var requestedURL: URL? = nil
    /// The redirects followed to reach this response, oldest first, with no body: okhttp's
    /// `priorResponse()` chain (`URLResponse.followedRedirects`).
    var redirects: [LegadoHTTPResult] = []

    /// `finalURL` as a source reads it (`AnalyzeUrl.legadoURLString`): `StrResponse.url()`,
    /// and the `baseUrl` of the page's rules.
    var urlString: String { AnalyzeUrl.legadoURLString(final: finalURL, requested: requestedURL) }

    static func bodyOnly(request: URLRequest, body: String) -> LegadoHTTPResult {
        let url = request.url ?? URL(string: "about:blank")!
        return LegadoHTTPResult(
            finalURL: url,
            statusCode: 200,
            statusMessage: HTTPURLResponse.localizedString(forStatusCode: 200).capitalized,
            headers: [:],
            cookies: [:],
            body: body,
            requestedURL: request.url
        )
    }

    /// This response with `body` for its own: Legado's `StrResponse(raw, body)`, which
    /// `AnalyzeUrl.getStrResponseAwait` answers with once a `bodyJs` has run. The bytes that
    /// arrived are not that body, so none are kept.
    func replacingBody(_ body: String) -> LegadoHTTPResult {
        LegadoHTTPResult(
            finalURL: finalURL, statusCode: statusCode, statusMessage: statusMessage,
            headers: headers, cookies: cookies, body: body, requestedURL: requestedURL,
            redirects: redirects
        )
    }

    static func make(
        request: URLRequest, data: Data?, response: URLResponse?, declaredCharset: String? = nil,
        error: (any Error)? = nil
    ) -> LegadoHTTPResult {
        let http = response as? HTTPURLResponse
        let finalURL = response?.url ?? request.url ?? URL(string: "about:blank")!
        var headers: [String: String] = [:]
        http?.allHeaderFields.forEach { key, value in headers[String(describing: key)] = String(describing: value) }
        let cookieObjects = HTTPCookie.cookies(withResponseHeaderFields: headers, for: finalURL)
        // A response may legally set the same cookie name for different paths.
        // Avoid Dictionary(uniqueKeysWithValues:) trapping at the JS boundary;
        // Legado's name-keyed Map likewise exposes one value per name.
        let cookies = cookieObjects.reduce(into: [String: String]()) { values, cookie in
            values[cookie.name] = cookie.value
        }
        let code = http?.statusCode ?? (data == nil ? 0 : 200)
        return LegadoHTTPResult(
            finalURL: finalURL,
            statusCode: code,
            statusMessage: code == 0 ? "" : HTTPURLResponse.localizedString(forStatusCode: code).capitalized,
            headers: headers,
            cookies: cookies,
            // A binary download's answer is its bytes (`LegadoBinaryDownload`), which Legado
            // never reads as text: decoding 22 MB of audio as a page took a second (11-09).
            body: LegadoBinaryDownload.isMarked(request) ? "" : data.map {
                LegadoJSBridge.decodeData($0, response: response, declaredCharset: declaredCharset)
            } ?? "",
            data: data,
            transportError: error,
            requestedURL: request.url,
            // As okhttp hands them out: a redirect's body is never read.
            redirects: response?.followedRedirects.map {
                make(request: URLRequest(url: $0.url ?? finalURL), data: nil, response: $0)
            } ?? []
        )
    }
}

// MARK: - JSExport Protocol

/// Protocol for Legado's `java.*` bridge functions.
/// Conforms to JSExport so methods are callable from JavaScript.
@objc protocol LegadoJSBridgeExport: JSExport {
    // Networking
    func ajax(_ urlStr: String) -> String
    func axja(_ urlStr: String) -> String
    /// The list is a `JSValue`, not `[String]`: a script's list may hold objects or numbers, and
    /// the bridging cast to `[String]` aborts the app before the method runs.
    func ajaxAll(_ urlArray: JSValue) -> [LegadoStrResponse]
    /// Legado-E `java.ajaxTestAll(urls, timeout[, skipRateLimit])`.
    func ajaxTestAll(_ urlArray: JSValue, _ timeout: Double, _ skipRateLimit: JSValue) -> [LegadoStrResponse]
    func connect(_ urlStr: String) -> LegadoStrResponse
    func connectWithOptions(_ urlStr: String, _ headers: JSValue, _ timeout: JSValue) -> LegadoStrResponse
    func head(_ urlStr: String, _ headers: JSValue) -> LegadoStrResponse
    func headWithOptions(_ urlStr: String, _ headers: JSValue, _ timeout: JSValue) -> LegadoStrResponse
    func post(_ urlStr: String, _ body: String, _ headers: JSValue) -> LegadoStrResponse
    func postWithOptions(_ urlStr: String, _ body: String, _ headers: JSValue, _ timeout: JSValue) -> LegadoStrResponse
    func httpExecute(_ method: String, _ urlStr: String, _ body: String, _ headers: JSValue) -> LegadoStrResponse
    /// Backs the two-argument `java.get(url, headers)`; see `installJavaGetOverload`.
    func httpGet(_ urlStr: String, _ headers: JSValue) -> LegadoStrResponse
    func importScript(_ url: String) -> String

    // Source files under `LegadoJSBridge.sourceFilesRoot` (Legado `JsExtensions.getFile`)
    /// `null` when there is no file.
    func readFile(_ path: String) -> JSValue
    /// `readTxtFile(path[, charsetName])`.
    func readTxtFile(_ path: String, _ charset: JSValue) -> String
    func deleteFile(_ path: String) -> Bool
    /// `downloadFile(url)` and the deprecated `downloadFile(hex, url)`.
    func downloadFile(_ first: String, _ second: JSValue) -> String
    /// `cacheFile(url[, saveTime])`.
    func cacheFile(_ url: String, _ saveTime: JSValue) -> String

    // Headless WebView (Legado java.webView(html, url, js) — runs js after load, returns result)
    func webView(_ html: JSValue, _ url: JSValue, _ js: JSValue) -> String
    func webViewGetSource(_ html: JSValue, _ url: JSValue, _ js: JSValue, _ sourceRegex: String) -> String
    func webViewGetOverrideUrl(_ html: JSValue, _ url: JSValue, _ js: JSValue, _ overrideUrlRegex: String) -> String

    // Cookie helpers (used by sources like 光遇)
    func getCookie(_ url: String) -> String
    func getCookie(_ url: String, _ key: String) -> String
    func getCookieValue(_ url: String, _ key: String) -> String
    func removeCookie(_ url: String)
    func getWebViewUA() -> String

    // Variable storage
    /// Legado's `AnalyzeRule.put` returns the value it stored: 晋江 (YCK1330 index 109)
    /// searches with `keyword={{key;java.put("key",key)}}`, which is the keyword in Legado and
    /// was an empty template here.
    @discardableResult func put(_ key: String, _ value: String) -> String
    func get(_ key: String) -> String

    // Rule evaluation (placeholder — connected to ModernRuleEngine later)
    /// Legado: `AnalyzeRule.getString(ruleStr, mContent = null, isUrl = false)`.
    /// `mContent` is optional in JS — JavaScriptCore passes `undefined` when the source
    /// calls `java.getString(rule)` with one argument.
    func getString(_ ruleStr: String, _ mContent: JSValue) -> String
    func getStringList(_ ruleStr: String) -> [String]
    func setContent(_ content: JSValue, _ baseUrl: JSValue) -> String
    func getElements(_ ruleStr: String) -> Any
    /// Backs `java.getElement(rule)` (Legado `AnalyzeRule.getElement`); the JS dispatcher in
    /// `JSCoreEngine.installJavaElementAccessors` wraps nodes as jsoup `Element`s.
    func getElementValue(_ ruleStr: String) -> Any?
    /// Backs `Packages.io.legado.app.model.analyzeRule.AnalyzeRule()` (`LegadoAnalyzeRule`);
    /// `null` when no parse wired a reader factory.
    func newAnalyzeRule() -> LegadoAnalyzeRule?

    // Java/Android classes the interop runtime builds on (LegadoJavaInteropRuntime)
    /// `MessageDigest.digest()`: unsigned bytes in and out; `[]` for an unknown algorithm.
    func digestBytes(_ bytes: JSValue, _ algorithm: String) -> [Int]
    /// `Thread.sleep(millis)`: blocks this script's thread, as under Rhino.
    func sleepMillis(_ millis: Double)
    /// `new StrResponse(url, body)`.
    func makeStrResponse(_ url: String, _ body: String) -> LegadoStrResponse
    /// legado `java.getUserAgent()`: the source's own `User-Agent` header, else the app's.
    func getUserAgent() -> String

    // Browser WebView (Legado startBrowser / startBrowserAwait) and image captcha
    func getVerificationCode(_ imageUrl: String) -> String
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String) -> LegadoStrResponse
    func startBrowserAwait(_ url: String, _ title: String, _ refetchAfterSuccess: Bool) -> LegadoStrResponse

    // Toast notifications
    func toast(_ msg: String)
    func longToast(_ msg: String)

    // Hand a keyword back to the app's own search
    func searchBook(_ key: String, _ source: JSValue?)
    func open(_ target: String, _ argument: JSValue?)

    // Logging
    func log(_ msg: String) -> String
    func logType(_ msg: String)

    // Response processing (TTS)
    func setResponseBase64(_ data: String, _ mimeType: String)

    // Time utilities
    func timeFormat(_ timestamp: JSValue) -> String
    func timeFormatUTC(_ time: Double, _ format: String, _ sh: Int) -> String

    // Encoding / Decoding
    func base64Decode(_ str: String) -> String
    func base64Encode(_ str: String) -> String
    func HMacBase64(_ content: String, _ algorithm: String, _ key: String) -> String
    func HMacHex(_ content: String, _ algorithm: String, _ key: String) -> String
    func digestHex(_ content: String, _ algorithm: String) -> String
    func digestBase64Str(_ content: String, _ algorithm: String) -> String
    func strToBytes(_ str: String, _ charset: JSValue) -> [Int]
    func bytesToStr(_ bytes: JSValue, _ charset: JSValue) -> String
    func base64DecodeToByteArray(_ str: String) -> [Int]
    func hexDecodeToByteArray(_ hex: String) -> [Int]
    func md5Encode(_ str: String) -> String
    func md5Encode16(_ str: String) -> String
    func hexDecodeToString(_ hex: String) -> String
    func hexEncodeToString(_ str: String) -> String
    // Symmetric crypto (low-level helpers used by the javax.crypto JS shim).
    // All args/returns are lowercase hex; empty string means failure.
    func aesDecryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String
    func aesEncryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String
    /// Backs `java.createAsymmetricCrypto` (`LegadoAsymmetricCrypto`). Hex in and out; a
    /// failure throws into the script, as hutool's does.
    func rsaCryptHex(_ transformation: String, _ keyHex: String, _ usePublicKey: Bool, _ encrypt: Bool, _ dataHex: String) -> String
    func encodeURI(_ str: String, _ enc: JSValue) -> String
    func encodeURIComponent(_ str: String) -> String
    func htmlFormat(_ str: String) -> String
    func randomUUID() -> String
    func toNumChapter(_ title: String) -> String
    func urlParts(_ url: String, _ baseURL: JSValue) -> NSDictionary
    func gzipBytes(_ value: JSValue) -> [Int]

    // Byte-level primitives behind the java.io / java.util.zip / java.net / java.security
    // classes `LegadoJavaInteropRuntime` writes in JavaScript. Bytes are arrays of 0–255.
    /// zlib inflate: `windowBits` -15 raw (`Inflater(true)`), 15 zlib (`Inflater()`), 31 gzip.
    /// Answers `{bytes, finished, consumed}`; malformed input throws into the script.
    func inflateBytes(_ value: JSValue, _ windowBits: Int) -> NSDictionary
    func secureRandomBytes(_ count: Int) -> [Int]
    func hmacBytes(_ data: JSValue, _ algorithm: String, _ key: JSValue) -> [Int]
    func aesGcmHex(
        _ encrypt: Bool, _ keyHex: String, _ ivHex: String, _ aadHex: String, _ tagBits: Int, _ dataHex: String
    ) -> String
    func rsaKeySizeBytes(_ keyHex: String, _ isPublic: Bool) -> Int
    func rsaSignHex(_ algorithm: String, _ keyHex: String, _ dataHex: String) -> String
    func rsaVerify(_ algorithm: String, _ keyHex: String, _ dataHex: String, _ signatureHex: String) -> Bool
    /// One request whose body is bytes (hex), for `HttpURLConnection`; the response's bytes
    /// are `bodyBytes()`.
    func httpExecuteBytes(_ method: String, _ urlStr: String, _ bodyHex: String, _ headers: JSValue) -> LegadoStrResponse
    /// `java.net.Socket.connect`: milliseconds to a TCP connection, -1 when none was made.
    func tcpConnectMillis(_ host: String, _ port: Int, _ timeoutMillis: Int) -> Int
    /// Java's `new URL(context, spec)`; "" when `context` is no absolute URL.
    func absoluteURL(_ spec: String, _ base: String) -> String

    // App theme information exposed by Android's JsExtensions.
    // `getThemeMode`: 0 follows system, 1 light, 2 dark, 3 e-ink.
    func getThemeMode() -> String
    func getThemeConfig() -> String
    func getThemeConfigMap() -> LegadoJavaMap

    // Chinese character conversion
    func t2s(_ text: String) -> String
    func s2t(_ text: String) -> String

    // UI actions used by complex Legado sources. Most are safe no-ops in parser-only flows.
    func refreshExplore()
    func reLoginView()
    func refreshBookInfo()
    func refreshBookToc()
    func refreshContent()
    func showBrowser(_ url: String, _ title: String)
    func showReadingBrowser(_ url: String, _ title: String)
    func startBrowserDp(_ url: String, _ title: String)
    func copyText(_ text: String)
    func deviceID() -> String
    func androidId() -> String
    func openVideoPlayer(_ url: String, _ title: String)
    /// legado-E `java.openUrl(url[, mimeType])`.
    func openUrl(_ url: String, _ mimeType: JSValue)
    /// legado `java.getTag()`: the source's name (`BaseSource.getTag`). `String?` in
    /// `JsExtensions`, so `null` without a source (`LegadoJavaNull`).
    @objc(getTag) func jsGetTag() -> JSValue
    func getAppVariant() -> String
    func upLoginData(_ data: JSValue)
    // `java.qread()` is a no-op stub ON PURPOSE: it makes 起点-family content JS set
    // `dev='android-轻阅读'`, so createSvg emits the 轻阅读 段评 SVG variant — the one the user wants
    // on iOS. (Removing it → `dev='ios'` → the ios variant, which the user rejected.) Don't remove it.
    func qread()
}

// MARK: - Cookie Bridge

/// Legado's `cookie` object — accessible from JS as `cookie.get(url)`, `cookie.set(url, val)`, `cookie.remove(url)`.
@objc protocol LegadoCookieBridgeExport: JSExport {
    func get(_ url: String) -> String
    func getCookie(_ url: String) -> String
    func getKey(_ url: String, _ key: String) -> String
    func set(_ url: String, _ cookie: String)
    func setCookie(_ url: String, _ cookie: String)
    func replaceCookie(_ url: String, _ cookie: String)
    func remove(_ url: String)
    func removeCookie(_ url: String)
}

@objc class LegadoCookieBridge: NSObject, LegadoCookieBridgeExport {

    func get(_ url: String) -> String {
        CookieStore.shared.get(url: url)
    }

    /// Legado `cookie.getKey(tag, key)` — value of a single cookie for a domain/URL.
    func getKey(_ url: String, _ key: String) -> String {
        CookieStore.shared.getKey(url: url, key: key)
    }

    func getCookie(_ url: String) -> String {
        CookieStore.shared.get(url: url)
    }

    func set(_ url: String, _ cookie: String) {
        CookieStore.shared.set(url: url, cookie: cookie)
    }

    func setCookie(_ url: String, _ cookie: String) {
        CookieStore.shared.set(url: url, cookie: cookie)
    }

    /// Legado `cookie.replaceCookie(url, cookie)` — merge these key=value pairs over
    /// whatever is stored for the domain. `CookieStore.set` already merges per key, so
    /// this is `set` under Legado's name; it existed only under ours, and the missing
    /// name threw. 同人小说网's 段评 mints a `_csrfToken` with it when 起点 has not set
    /// one yet, and the throw landed in the rule's own catch → no 段评, no message.
    func replaceCookie(_ url: String, _ cookie: String) {
        CookieStore.shared.set(url: url, cookie: cookie)
    }

    func remove(_ url: String) {
        CookieStore.shared.remove(url: url)
    }

    func removeCookie(_ url: String) {
        CookieStore.shared.remove(url: url)
    }
}

// MARK: - Bridge Implementation

/// Concrete implementation of the `java` bridge object injected into JSContext.
@objc class LegadoJSBridge: NSObject, LegadoJSBridgeExport {

    /// Delegate for variable storage (wired to RuleDataInterface).
    var getData: ((String) -> String?)?
    var putData: ((String, String) -> Void)?

    /// Delegate for network requests.
    var networkHandler: SourceScriptTransport?

    /// Presents a page for `java.startBrowser` / `java.startBrowserAwait` (and two-argument
    /// `showBrowser`). The completion receives the page's HTML once the user confirms it, nil
    /// when the page was dismissed. For `startBrowserAwait` the bridge blocks jsQueue via
    /// DispatchSemaphore until completion is called.
    ///
    /// Set only where a runtime presents its pages itself (the login menu, 段評 capture);
    /// everywhere else `startBrowser` / `startBrowserAwait` use `sharedBrowserPresenter`.
    var browserPresentHandler: ((SourceBrowserRequest, @escaping @Sendable (String?) -> Void) -> Void)?

    typealias BrowserPresenter = (SourceBrowserRequest, @escaping @Sendable (String?) -> Void) -> Void

    /// How any source runtime opens a page — search, a chapter, 書源驗證 — the way Legado's
    /// `SourceVerificationHelp` starts its browser from wherever the script runs. The app
    /// installs it once at launch.
    static var sharedBrowserPresenter: BrowserPresenter? {
        get {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            return _sharedBrowserPresenter
        }
        set {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            _sharedBrowserPresenter = newValue
        }
    }
    nonisolated(unsafe) private static var _sharedBrowserPresenter: BrowserPresenter?
    private static let sharedBrowserPresenterLock = NSLock()

    private var browserPresenter: BrowserPresenter? {
        browserPresentHandler ?? Self.sharedBrowserPresenter
    }

    /// What a video episode's content script handed over rather than returned: legado-E plays
    /// `java.openVideoPlayer`'s link and opens `java.startBrowser`'s page the moment the script
    /// asks, but for the episode the video player is fetching they are the episode itself.
    struct VideoEpisodeHandover: Equatable {
        var stream: String?
        var page: String?
    }

    /// Non-nil only while the content rule of the episode being played runs
    /// (`JSCoreEngine.handingOverVideoEpisode`); the script runs on this bridge's one queue.
    var videoEpisodeHandover: VideoEpisodeHandover?

    /// Presents the captcha for `java.getVerificationCode`; the completion receives the code
    /// the user entered, nil when they dismissed it. Unset, `sharedCaptchaPresenter` does.
    var captchaPresentHandler: ((SourceCaptchaRequest, @escaping @Sendable (String?) -> Void) -> Void)?

    typealias CaptchaPresenter = (SourceCaptchaRequest, @escaping @Sendable (String?) -> Void) -> Void

    /// Installed at launch next to `sharedBrowserPresenter`.
    static var sharedCaptchaPresenter: CaptchaPresenter? {
        get {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            return _sharedCaptchaPresenter
        }
        set {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            _sharedCaptchaPresenter = newValue
        }
    }
    nonisolated(unsafe) private static var _sharedCaptchaPresenter: CaptchaPresenter?

    /// Asks the reader whether to open a source's link — legado-E `java.openUrl` and its
    /// `OpenUrlConfirmActivity`. Installed at launch next to `sharedBrowserPresenter`.
    typealias OpenURLPresenter = @Sendable (SourceOpenURLRequest) -> Void

    static var sharedOpenURLPresenter: OpenURLPresenter? {
        get {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            return _sharedOpenURLPresenter
        }
        set {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            _sharedOpenURLPresenter = newValue
        }
    }
    nonisolated(unsafe) private static var _sharedOpenURLPresenter: OpenURLPresenter?

    /// Plays a source's video in the native full-screen player — legado-E
    /// `java.openVideoPlayer(url, title)`. The request already carries the URL's `,{headers}`
    /// option, the source's header map and its cookies (`sourceBrowserRequest`), which is what
    /// the video CDN checks. Installed at launch next to `sharedBrowserPresenter`.
    typealias VideoPresenter = (URLRequest, String) -> Void

    static var sharedVideoPresenter: VideoPresenter? {
        get {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            return _sharedVideoPresenter
        }
        set {
            sharedBrowserPresenterLock.lock()
            defer { sharedBrowserPresenterLock.unlock() }
            _sharedVideoPresenter = newValue
        }
    }
    nonisolated(unsafe) private static var _sharedVideoPresenter: VideoPresenter?

    /// The attached source's name and URL, for the captcha sheet (which can 停用 or 刪除 it).
    var sourceIdentityProvider: (() -> (name: String, url: String))?

    /// This runtime's scripts parked waiting for the user — on a `startBrowserAwait` page or a
    /// captcha — see `LegadoScriptWaits`.
    private let readerWaits = LegadoScriptWaits()

    /// This runtime's scripts blocked on the network — see `LegadoScriptWaits`.
    let networkWaits = LegadoScriptWaits()

    /// Whether a script is waiting on the network or the reader right now.
    var isWaiting: Bool { networkWaits.isWaiting || readerWaits.isWaiting }

    /// The time this runtime's scripts have spent waiting on the network or the reader. A script
    /// waits for one at a time, so the two add up without overlapping.
    var waitedSeconds: TimeInterval { networkWaits.waitedSeconds + readerWaits.waitedSeconds }

    /// Where this runtime's waits for the user can be ended from outside — the source's
    /// session hands it in (`BookSourceSession.userWaits`). Nil: nothing outside ends them.
    var userWaits: LegadoUserWaitRegistry?

    /// Blocks this script until `present` reports back, however long the user takes — or
    /// until the session ends the wait (`LegadoUserWaitRegistry.cancelAll`), which answers
    /// it as a dismissal.
    private func waitForUser(
        withdrawal: SourceWaitWithdrawal? = nil,
        _ present: (@escaping @Sendable (String?) -> Void) -> Void
    ) -> String? {
        let sem = DispatchSemaphore(value: 0)
        // First answer wins: the user's, or the session's cancellation.
        let answer = OSAllocatedUnfairLock<(done: Bool, value: String?)>(initialState: (false, nil))
        let finish: @Sendable (String?) -> Void = { value in
            let first = answer.withLock { state -> Bool in
                guard !state.done else { return false }
                state = (true, value)
                return true
            }
            if first { sem.signal() }
        }
        readerWaits.during {
            let token = userWaits?.register {
                finish(nil)
                withdrawal?.withdraw()
            }
            present(finish)
            sem.wait()
            if let token { userWaits?.unregister(token) }
        }
        return answer.withLock { $0.value }
    }

    /// Called for source-authored HTML browser pages. Unlike the two-argument browser API,
    /// the second argument is page HTML (not a title), and the injected script wires the
    /// page back to the source runtime for calls such as paragraph-review pagination.
    var browserPagePresentHandler: ((LegadoBrowserPageRequest) -> Void)?

    /// Called when JS invokes `java.toast(msg)` / `java.longToast(msg)`.
    var toastHandler: (@Sendable (String) -> Void)?

    /// Called when JS invokes `java.reLoginView()` — the source asks the host to re-render its
    /// custom login menu (e.g. after `changeMenu(tag)` switches `menuTag`). Lets multi-page
    /// source menus (起点's 评论设置/气泡模版 submenus) navigate instead of staying on page 1.
    var reLoginViewHandler: (() -> Void)?

    /// Called when JS invokes `java.upLoginData(map)` — persist a map of setting key/values into
    /// the source's login data (read back via `source.getLoginInfoMap()`).
    var upLoginDataHandler: ((JSValue) -> Void)?

    /// Called when JS invokes `java.refreshBookInfo()` / `java.refreshBookToc()` — Legado's
    /// `SourceLoginJsExtensions` posts `REFRESH_BOOK_INFO` / `REFRESH_BOOK_TOC`, and the
    /// open book detail page reloads. Set only while a detail page runs one of its scripts.
    var refreshBookInfoHandler: (() -> Void)?
    var refreshBookTocHandler: (() -> Void)?
    /// Called when JS invokes `java.refreshExplore()` — Legado's explore page reloads the
    /// source's categories. Set only while a source's page runs one of its explore
    /// buttons, inputs or toggles.
    var refreshExploreHandler: (() -> Void)?

    /// Delegate for rule evaluation (connected later).
    var getStringHandler: ((String) -> String?)?
    var getStringListHandler: ((String) -> [String]?)?
    var setContentHandler: ((Any?, String?) -> Void)?
    var getElementsHandler: ((String) -> Any?)?
    var getElementHandler: ((String) -> Any?)?
    var getStringWithContentHandler: ((String, Any?) -> String?)?
    /// Makes the rule reader a script's `AnalyzeRule()` holds (`ModernParserBridge`).
    var analyzeRuleFactory: (() -> ModernRuleEngine?)?
    /// The pages this context's scripts were handed elements of (`LegadoScriptTrees`).
    let scriptTrees = LegadoScriptTrees()

    /// Called when JS invokes `java.setResponseBase64(data, mimeType)` — stores decoded audio data.
    /// Used by TTS `loginCheckJs` to extract base64 audio from JSON API responses.
    var setResponseBase64Handler: ((Data, String) -> Void)?

    /// Book source headers (for JS network requests to use correct User-Agent etc.).
    ///
    /// Supplied by the owning engine rather than stored, because a `@js:` header
    /// rule can only be evaluated once `jsLib` exists — snapshotting it when the
    /// source is attached resolved 书山聚合's rule too early and left every
    /// `java.get`/`java.post` without the token its server requires.
    var sourceHeadersProvider: (() -> [String: String])?

    /// Whether this source opted into an Android device identity
    /// (`BookSource.presentsAndroidIdentity`). Supplied by the owning engine
    /// because the bridge is per-source but the flag lives on the model.
    var presentsAndroidIdentityProvider: (() -> Bool)?
    /// Whether the script's `source` keeps a cookie jar (`enabledCookieJar`): Legado's
    /// `java.get`/`head`/`post` then mark their request `CookieJar: 1`
    /// (`performJsoupRequest`). Read live, on the JS thread.
    var keepsCookieJarProvider: (() -> Bool)?
    /// The source's `cache`: `cacheFile` (and `importScript(http…)`, which is `cacheFile`)
    /// keeps its downloads' paths there under `md5Encode16(url)`, as Legado does.
    var importScriptCacheProvider: (() -> LegadoCacheBridge?)?
    var sourceHeaders: [String: String] { sourceHeadersProvider?() ?? [:] }

    /// Timeout for `java.*` requests a script gives none of its own: Legado's OkHttp client's
    /// (`WebFetcher.sourceRequestTimeout`). A source's `respondTime` is not one in Legado — it
    /// is the search's measured response time — and deriving 8–30 s from it cut off slow sites
    /// Legado reads.
    let requestTimeoutSeconds: TimeInterval = WebFetcher.sourceRequestTimeout

    /// AnalyzeUrl-based request handler. When set, `java.ajax()` routes URLs containing `,{json}`
    /// through AnalyzeUrl rather than treating the entire string as a simple URL. Called on the JS
    /// thread; `nil` when it built no request.
    var analyzeUrlHandler: ((String) -> PreparedSourceRequest?)?

    // MARK: - JS network attribution
    //
    // Wall-time the JS thread spent blocked on `java.*` network during the current parse.
    // 段評 sources fetch per-paragraph review counts from inside the content rule JS, so that
    // network lands inside `chapter.parse` and is invisible to `chapter.network`. Accumulate it
    // here (ajaxAll adds its BATCH wall time — it runs 6-wide, so summing items would over-count)
    // and let ModernParserBridge emit `⏱ chapter.jsNet` to split a slow parse into network vs CPU.
    private let networkMsLock = NSLock()
    private var accumulatedNetworkMs: Double = 0
    func resetNetworkMs() { networkMsLock.lock(); accumulatedNetworkMs = 0; networkMsLock.unlock() }
    func takeNetworkMs() -> Double { networkMsLock.lock(); defer { networkMsLock.unlock() }; return accumulatedNetworkMs }
    private func recordBlockingNetwork(_ ms: Double) {
        networkMsLock.lock(); accumulatedNetworkMs += ms; networkMsLock.unlock()
    }

    // MARK: - Dedicated java.* session
    //
    // iOS caps `URLSession.shared` at 6 connections per host. 段評 sources fan out ONE
    // review-count request PER PARAGRAPH (50–150) to a single host, so that cap — doubled by
    // the old `ajaxAll` throttle of 6 — serialized them into multi-second batches (measured
    // `⏱ chapter.jsNet` ≈ 1.7–6.2s, ≈ the whole chapter.parse). Legado runs these at its user
    // "线程数" (threadCount, default 16) over an OkHttp pool, which is why the SAME 段評 chapter
    // opens ~3× faster there. Match Legado's default 16 per host; the user confirmed Legado's 16
    // doesn't trip these 段評 servers, so 16 is a validated (not speculative) concurrency.
    //
    // NOT private: the online reader routes java.* network through ModernParserBridge's
    // `networkHandler` (always set; its `analyzeUrlHandler` sends through it too), so that
    // handler must use THIS pool too — otherwise it falls back to URLSession.shared's 6/host and
    // the 16-wide ajaxAll just queues behind 6 connections (the reason raising the throttle alone
    // did nothing).
    static let requestSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = WebFetcher.sourceRequestTimeout
        config.timeoutIntervalForResource = WebFetcher.sourceRequestTimeout
        // No URL cache, as in `WebFetcher.defaultSessionConfiguration`: responses are read
        // once, and `URLCache.shared` wrote every cacheable one to its Cache.db.
        config.urlCache = nil
        return URLSession.sourceSites(config)
    }()

    // MARK: Networking

    func ajax(_ urlStr: String) -> String {
        let started = Date()
        let body = performRequest(urlStr)
        recordBlockingNetwork(Date().timeIntervalSince(started) * 1000)
        // ⟐ ajax — reveal WHY 起点 content comes back empty: log the response of the
        // auth/content/review API calls (get_my_token / content.php / review.php …).
        //
        // The path allowlist below only ever covered ONE source's endpoints, which
        // left every other source's API failures invisible on device: 书山聚合 POSTs
        // its chapter body to `{host}/content` and matches none of them, so when its
        // 正文 stopped arriving there was nothing in Console to say whether the server
        // refused, answered an error envelope, or was never reached. A short reply is
        // never a chapter body — those run to kilobytes — so treat it as a control or
        // error envelope and record it regardless of path.
        if Self.shouldLogReviewNetwork(urlStr) || body.utf8.count <= 1024 {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLogger.parse("⟐ ajax", context: [
                "kind": Self.reviewNetworkKind(urlStr),
                "path": Self.requestPathPreview(urlStr),
                "query": Self.redactedQueryPreview(urlStr),
                "ms": ms,
                "len": body.count,
                "json": Self.responseShape(body),
                "head": String(body.prefix(160))
            ])
        }
        return body
    }

    func axja(_ urlStr: String) -> String {
        let body = performRequest(urlStr)
        return Self.aaDecode(body)
    }

    /// Decode aaencode (源阅 obfuscation) — maps Unicode-encoded characters
    /// back to their ASCII equivalents. Mirrors Legado's `StringUtils.aaDecode`.
    static func aaDecode(_ str: String) -> String {
        guard !str.isEmpty else { return str }
        // Per Unicode scalar, as Legado's per-character replace works. Swift compares
        // `String`s by grapheme cluster, so a mapped character followed by a combining mark
        // (Ｈ + U+0E31) formed one cluster that `replacingOccurrences(of: "Ｈ")` never
        // matched, and the obfuscated text came back half decoded.
        var decoded = String.UnicodeScalarView()
        for scalar in str.unicodeScalars {
            if let replacement = aaDecodeTable[scalar] {
                decoded.append(contentsOf: replacement.unicodeScalars)
            } else {
                decoded.append(scalar)
            }
        }
        return String(decoded)
    }

    private static let aaDecodeTable: [Unicode.Scalar: String] = Dictionary(
        [
            ("\u{203F}", "_"), ("\u{2040}", " "),
            ("\u{00A1}", "!"), ("\u{00A6}", "|"),
            ("\u{15AD}", "("), ("\u{15AE}", ")"),
            ("\u{20A9}", "\\"), ("\u{4DC0}", "||"),
            ("\u{20B4}", "$"), ("\u{0C8C}", "="),
            ("\u{0C98}", ">"), ("\u{0C95}", "<"),
            ("\u{14A6}", "}"), ("\u{14A5}", "{"),
            ("\u{0E50}", "0"), ("\u{0E51}", "1"),
            ("\u{0E52}", "2"), ("\u{0E53}", "3"),
            ("\u{0E54}", "4"), ("\u{0E55}", "5"),
            ("\u{0E56}", "6"), ("\u{0E57}", "7"),
            ("\u{0E58}", "8"), ("\u{0E59}", "9"),
            ("\u{2010}", "-"), ("\u{2011}", "-"),
            ("\u{2012}", "-"), ("\u{2013}", "-"),
            ("\u{2014}", "--"), ("\u{2015}", "--"),
            ("\u{2215}", "/"), ("\u{FF0F}", "/"),
            ("\u{FF3A}", "Z"), ("\u{FF5A}", "z"),
            ("\u{FF21}", "A"), ("\u{FF41}", "a"),
            ("\u{FF22}", "B"), ("\u{FF42}", "b"),
            ("\u{FF23}", "C"), ("\u{FF43}", "c"),
            ("\u{FF24}", "D"), ("\u{FF44}", "d"),
            ("\u{FF25}", "E"), ("\u{FF45}", "e"),
            ("\u{FF26}", "F"), ("\u{FF46}", "f"),
            ("\u{FF27}", "G"), ("\u{FF47}", "g"),
            ("\u{FF28}", "H"), ("\u{FF48}", "h"),
            ("\u{FF29}", "I"), ("\u{FF49}", "i"),
            ("\u{FF2A}", "J"), ("\u{FF4A}", "j"),
            ("\u{FF2B}", "K"), ("\u{FF4B}", "k"),
            ("\u{FF2C}", "L"), ("\u{FF4C}", "l"),
            ("\u{FF2D}", "M"), ("\u{FF4D}", "m"),
            ("\u{FF2E}", "N"), ("\u{FF4E}", "n"),
            ("\u{FF2F}", "O"), ("\u{FF4F}", "o"),
            ("\u{FF30}", "P"), ("\u{FF50}", "p"),
            ("\u{FF31}", "Q"), ("\u{FF51}", "q"),
            ("\u{FF32}", "R"), ("\u{FF52}", "r"),
            ("\u{FF33}", "S"), ("\u{FF53}", "s"),
            ("\u{FF34}", "T"), ("\u{FF54}", "t"),
            ("\u{FF35}", "U"), ("\u{FF55}", "u"),
            ("\u{FF36}", "V"), ("\u{FF56}", "v"),
            ("\u{FF37}", "W"), ("\u{FF57}", "w"),
            ("\u{FF38}", "X"), ("\u{FF58}", "x"),
            ("\u{FF39}", "Y"), ("\u{FF59}", "y"),
            ("\u{FF10}", "0"), ("\u{FF11}", "1"),
            ("\u{FF12}", "2"), ("\u{FF13}", "3"),
            ("\u{FF14}", "4"), ("\u{FF15}", "5"),
            ("\u{FF16}", "6"), ("\u{FF17}", "7"),
            ("\u{FF18}", "8"), ("\u{FF19}", "9"),
            ("\u{02C8}", "'"),
        ],
        uniquingKeysWith: { first, _ in first }
    )

    func ajaxAll(_ urlArray: JSValue) -> [LegadoStrResponse] {
        runAjaxBatch(Self.ajaxURLList(urlArray, call: "ajaxAll"), test: nil)
    }

    /// The URL strings of `java.ajaxAll`/`java.ajaxTestAll`'s list, as Rhino gives Legado's
    /// `Array<String>` parameter: each element through JS ToString, so an object answers
    /// `"[object Object]"` (or its own `toString()`), a number its digits, `null` `"null"` — one
    /// request, and one response, per element, in order. Every fork (legado-E, Sigma, MD3)
    /// declares `Array<String>` and none reads a `url` field. A coerced element is logged: it is
    /// almost always a broken URL, and the source that sent it is worth finding.
    static func ajaxURLList(_ list: JSValue, call: String) -> [String] {
        guard list.isArray else {
            // Rhino throws converting a non-array to `Array<String>`; answering no responses
            // keeps the script running, and every source indexes the answer by its own list.
            AppLogger.parse("⟐ \(call) list is not an array", context: [
                "type": Self.jsTypeName(list),
                "value": String((list.toString() ?? "").prefix(120))
            ])
            return []
        }
        let count = Int(list.forProperty("length")?.toInt32() ?? 0)
        return (0..<count).map { index in
            guard let element = list.atIndex(index) else { return "undefined" }
            if element.isString { return element.toString() ?? "" }
            let coerced = element.toString() ?? ""
            AppLogger.parse("⟐ \(call) element is not a string", context: [
                "i": index,
                "type": Self.jsTypeName(element),
                "coerced": String(coerced.prefix(120))
            ])
            return coerced
        }
    }

    private static func jsTypeName(_ value: JSValue) -> String {
        if value.isUndefined { return "undefined" }
        if value.isNull { return "null" }
        if value.isNumber { return "number" }
        if value.isBoolean { return "boolean" }
        if value.isString { return "string" }
        if value.isArray { return "array" }
        return "object"
    }

    /// Legado-E `java.ajaxTestAll(urls, timeout[, skipRateLimit])`: `ajaxAll` as a speed test.
    /// Each request has `timeout` milliseconds; one that fails answers a response whose body is
    /// the error and whose `callTime()` is Legado's error code (`AnalyzeUrl.executeStrRequest`
    /// with `isTest`), one that succeeds answers its time. `skipRateLimit` is accepted for
    /// parity: this runtime applies no per-source rate limit to `java.*` requests.
    func ajaxTestAll(_ urlArray: JSValue, _ timeout: Double, _ skipRateLimit: JSValue) -> [LegadoStrResponse] {
        runAjaxBatch(Self.ajaxURLList(urlArray, call: "ajaxTestAll"), test: AjaxTestOptions(timeoutSeconds: max(0.1, timeout / 1000)))
    }

    private struct AjaxTestOptions {
        let timeoutSeconds: TimeInterval
    }

    /// Legado's `ajaxTestAll` error codes for a request that got no response.
    static func ajaxTestErrorCode(_ error: (any Error)?) -> Int {
        guard let urlError = error as? URLError else { return -7 }
        switch urlError.code {
        case .timedOut: return -2
        case .cannotFindHost, .dnsLookupFailed: return -3
        case .cannotConnectToHost: return -4
        case .networkConnectionLost, .notConnectedToInternet: return -5
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return -6
        default: return -7
        }
    }

    /// `ajaxAll` and `ajaxTestAll`: the requests 16 at a time, each answered in order.
    private func runAjaxBatch(_ urlArray: [String], test: AjaxTestOptions?) -> [LegadoStrResponse] {
        guard !urlArray.isEmpty else { return [] }
        // Legado's `java.ajaxAll` returns `StrResponse[]`; sources ALWAYS call `.body()` on
        // each element (起点 段评: `cmtData[0].body()`; 番茄 bookshelf: `r.body()`). Returning
        // plain `[String]` made `.body()` throw → callers' try/catch swallowed it → e.g. 段评
        // bubbles silently never injected (review.php fetched fine, just unused). Wrap each
        // body in LegadoStrResponse so `.body()` works.
        let throttle = DispatchSemaphore(value: 16) // match Legado threadCount (16); paired with requestSession httpMaximumConnectionsPerHost=16
        // What each worker brought back; `nil` until it does — and, after the timeout, for good.
        let collected = OSAllocatedUnfairLock(
            initialState: Array<AjaxAllOutcome?>(repeating: nil, count: urlArray.count)
        )
        // Each worker's own time, which `ajaxTestAll` reports and judges its timeout by.
        let elapsedMs = OSAllocatedUnfairLock(
            initialState: Array<Int?>(repeating: nil, count: urlArray.count)
        )
        let group = DispatchGroup()

        // ⟐ ajaxAll — 段评 review.php is fetched here; log entry/exit + elapsed so a hang
        // (the suspected 段评-on infinite-loading) is visible on device.
        let _start = Date()
        let firstHost = URL(string: urlArray[0].components(separatedBy: ",").first ?? "")?.host ?? "?"
        AppLogger.parse("⟐ ajaxAll start", context: [
            "count": urlArray.count,
            "host": firstHost,
            "sample": urlArray.prefix(6).map { Self.requestPathPreview($0) }
        ])

        // The workers get what a request needs, not the bridge: after the 30 s timeout below the
        // stragglers keep running while this thread goes back to the script. Unlike every other
        // `JSConfined` hop, up to 16 workers call these handlers at once — as they always have
        // (each used to call `self.performRequestResult`); the handlers must stay thread-safe.
        // Nothing a worker does may need the JS queue, which this thread holds until the batch
        // ends — a worker that did would wait out the timeout below. So every JS a request runs
        // runs here: the source headers once, each AnalyzeUrl-route request's own JS as it is
        // built (`PreparedSourceRequest`), and its `bodyJs` after the batch. The workers get the
        // network alone.
        var context = requestContext(for: urlArray)
        if let test {
            context = RequestContext(
                analyzeUrlHandler: context.analyzeUrlHandler,
                networkHandler: context.networkHandler,
                sourceHeaders: context.sourceHeaders,
                timeoutSeconds: test.timeoutSeconds,
                networkWaits: context.networkWaits
            )
        }
        var routes: [AnalyzeUrlRoute?] = []
        routes.reserveCapacity(urlArray.count)
        var buildMs = 0.0
        for (index, urlStr) in urlArray.enumerated() {
            // Built before its slot is taken, so it overlaps the requests already in flight.
            let buildStart = Date()
            let route = Self.analyzeUrlRoute(urlStr, in: context)
            buildMs += Date().timeIntervalSince(buildStart) * 1000
            routes.append(route)
            let job = JSConfined(route.map { AjaxAllJob.analyzeUrl($0.request) } ?? .plain(context))
            context.networkWaits.during { throttle.wait() } // block until a concurrency slot is free
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let itemStart = Date()
                let outcome: AjaxAllOutcome
                switch job.value {
                case .plain(let context):
                    outcome = .plain(Self.performPlainRequest(urlStr, in: context))
                case .analyzeUrl(let request):
                    outcome = .fetched(request?.fetch())
                }
                let body = outcome.body
                let itemMs = Int(Date().timeIntervalSince(itemStart) * 1000)
                collected.withLock { $0[index] = outcome }
                elapsedMs.withLock { $0[index] = itemMs }
                if index < 16 || Self.shouldLogReviewNetwork(urlStr) {
                    AppLogger.parse("⟐ ajaxAll item", context: [
                        "i": index,
                        "kind": Self.reviewNetworkKind(urlStr),
                        "path": Self.requestPathPreview(urlStr),
                        "query": Self.redactedQueryPreview(urlStr),
                        "ms": itemMs,
                        "len": body.count,
                        "json": Self.responseShape(body),
                        "head": String(body.prefix(120))
                    ])
                }
                throttle.signal()
                group.leave()
            }
        }

        // Bounded wait: every request still in flight started no earlier than the last slot
        // freed, and each is capped at its own timeout, so the batch ends within one timeout of
        // here. Never block the JS thread forever. A speed test is judged the same way: every
        // earlier request by its own time below.
        let waited = context.networkWaits.during {
            group.wait(timeout: .now() + context.timeoutSeconds + 0.5)
        }
        // After a timeout the stragglers are still writing; read one snapshot.
        let outcomes = collected.withLock { $0 }
        let times = elapsedMs.withLock { $0 }
        let _ms = Int(Date().timeIntervalSince(_start) * 1000)
        // Batch wall time = how long the JS thread was actually blocked (requests ran up to
        // 16-wide over requestSession's 16 connections/host — matches Legado threadCount).
        // It includes building the AnalyzeUrl-route requests, which overlaps the network.
        recordBlockingNetwork(Date().timeIntervalSince(_start) * 1000)
        // Back on the JS thread: each AnalyzeUrl-route response's `bodyJs` runs here, in order.
        // A response that lands after the timeout is never read, so a straggler runs no JS.
        let finishStart = Date()
        let results: [LegadoHTTPResult?] = zip(routes, outcomes).map { route, outcome in
            switch outcome {
            case nil: return nil
            case .plain(let result): return result
            case .fetched(let response): return route?.result(for: response)
            }
        }
        let finishMs = Date().timeIntervalSince(finishStart) * 1000
        AppLogger.parse("⟐ ajaxAll done", context: [
            "ms": _ms,
            "buildMs": Int(buildMs),
            "finishMs": Int(finishMs),
            "timedOut": waited == .timedOut,
            "empty": results.filter { ($0?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            "lens": results.map { $0?.body.count ?? 0 }
        ])
        if let test {
            let timeoutMs = Int(test.timeoutSeconds * 1000)
            return urlArray.indices.map { index in
                let url = urlArray[index].components(separatedBy: ",{").first ?? urlArray[index]
                guard let result = results[index], let ms = times[index], ms <= timeoutMs else {
                    let response = LegadoStrResponse(url: url, body: "timeout")
                    response.callTimeMillis = -1
                    return response
                }
                if result.data == nil, result.transportError != nil || result.body.isEmpty {
                    let response = LegadoStrResponse(
                        url: url, body: result.transportError?.localizedDescription ?? ""
                    )
                    response.callTimeMillis = Self.ajaxTestErrorCode(result.transportError)
                    return response
                }
                return LegadoStrResponse(result: result, callTime: ms)
            }
        }
        // Wrap into StrResponse objects so JS `.body()` works (Legado contract).
        return zip(urlArray, results).map { url, result in
            if let result { return LegadoStrResponse(result: result) }
            return LegadoStrResponse(url: url.components(separatedBy: ",{").first ?? url, body: "")
        }
    }

    private static func shouldLogReviewNetwork(_ urlStr: String) -> Bool {
        let lower = urlStr.lowercased()
        return lower.contains("content.php")
            || lower.contains("api_user")
            || lower.contains("review.php")
            || lower.contains("chaxun")
            || lower.contains("/qdapi/")
            || lower.contains("list.php")
            || lower.contains("comment")
            || lower.contains("cmt")
    }

    private static func reviewNetworkKind(_ urlStr: String) -> String {
        let lower = urlStr.lowercased()
        if lower.contains("content.php") { return "content" }
        if lower.contains("api_user") { return "auth" }
        if lower.contains("review.php") || lower.contains("comment") || lower.contains("cmt") {
            return "review"
        }
        if lower.contains("list.php") { return "list" }
        return "other"
    }

    private static func requestPathPreview(_ urlStr: String) -> String {
        let rawURL = urlStr.components(separatedBy: ",{").first ?? urlStr
        guard let components = URLComponents(string: rawURL) else {
            return String(rawURL.prefix(96))
        }
        let host = components.host ?? ""
        let path = components.path.isEmpty ? "/" : components.path
        return String((host + path).suffix(96))
    }

    private static func redactedQueryPreview(_ urlStr: String) -> String {
        let rawURL = urlStr.components(separatedBy: ",{").first ?? urlStr
        guard let components = URLComponents(string: rawURL),
              let items = components.queryItems,
              !items.isEmpty else { return "" }
        // Credential-shaped parameter names. Sources carry secrets in the query far
        // beyond `token`: 晴天起点 sends `&key=…&dttoken=…`, 书山聚合 sends
        // `?session=…`. Over-redacting a harmless name costs nothing; under-redacting
        // writes a live credential into a log the user may hand to someone else. Only
        // whether the value is present is ever recorded, which is all a diagnosis needs.
        let secretNameFragments = [
            "token", "cookie", "password", "key", "secret", "session", "sign", "auth",
        ]
        let preview = items.prefix(8).map { item -> String in
            let lower = item.name.lowercased()
            if secretNameFragments.contains(where: { lower.contains($0) }) {
                return "\(item.name)=<redacted:\((item.value ?? "").isEmpty ? "empty" : "set")>"
            }
            return "\(item.name)=\(item.value ?? "")"
        }.joined(separator: "&")
        return String(preview.prefix(180))
    }

    private static func responseShape(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        let lower = trimmed.lowercased()
        var flags: [String] = []
        if trimmed.hasPrefix("{") { flags.append("jsonObject") }
        if trimmed.hasPrefix("[") { flags.append("jsonArray") }
        if lower.contains(#""success":false"#) { flags.append("success=false") }
        if lower.contains(#""success":true"#) { flags.append("success=true") }
        if lower.contains(#""message""#) { flags.append("message") }
        if lower.contains(#""content""#) { flags.append("content") }
        if lower.contains(#""count""#) { flags.append("count") }
        if lower.contains("token") { flags.append("token") }
        if lower.contains("请先登录") || lower.contains("\\u8bf7\\u5148\\u767b\\u5f55") {
            flags.append("login-required")
        }
        return flags.isEmpty ? "text" : flags.joined(separator: "|")
    }

    func connect(_ urlStr: String) -> LegadoStrResponse {
        let started = Date()
        let result = performRequestResult(urlStr)
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: result, callTime: Int(elapsed))
    }

    /// Header/timeout overload used by Legado-E and MD3. A JavaScript dispatcher
    /// installed by `JSCoreEngine` preserves the one-argument original contract.
    func connectWithOptions(
        _ urlStr: String,
        _ headers: JSValue,
        _ timeout: JSValue
    ) -> LegadoStrResponse {
        let started = Date()
        let timeoutSeconds = Self.timeoutSeconds(from: timeout)
        let result = performGet(
            urlStr,
            headers: Self.headerDict(from: headers),
            timeoutOverride: timeoutSeconds,
            followRedirects: true
        )
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: result, callTime: Int(elapsed))
    }

    /// Legado `java.head(url, headers)` — a response-shaped HEAD request.
    func head(_ urlStr: String, _ headers: JSValue) -> LegadoStrResponse {
        headWithOptions(urlStr, headers, JSValue(undefinedIn: headers.context))
    }

    func headWithOptions(
        _ urlStr: String,
        _ headers: JSValue,
        _ timeout: JSValue
    ) -> LegadoStrResponse {
        let started = Date()
        let result = performJsoupRequest(
            method: "HEAD",
            urlStr,
            body: nil,
            headers: Self.headerDict(from: headers),
            timeoutOverride: Self.timeoutSeconds(from: timeout)
        )
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: result, callTime: Int(elapsed))
    }

    /// Legado `java.post(url, body, headers)` — jsoup's POST (`performJsoupRequest`) returning
    /// its response (`.body()`, `.header(name)`). `body` is sent verbatim; `headers` is a JS
    /// object.
    func post(_ urlStr: String, _ body: String, _ headers: JSValue) -> LegadoStrResponse {
        postWithOptions(urlStr, body, headers, JSValue(undefinedIn: headers.context))
    }

    func postWithOptions(
        _ urlStr: String,
        _ body: String,
        _ headers: JSValue,
        _ timeout: JSValue
    ) -> LegadoStrResponse {
        let started = Date()
        let result = performJsoupRequest(
            method: "POST",
            urlStr,
            body: body,
            headers: Self.headerDict(from: headers),
            timeoutOverride: Self.timeoutSeconds(from: timeout)
        )
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: result, callTime: Int(elapsed))
    }

    /// Native execution primitive for the bounded okhttp3 compatibility surface.
    func httpExecute(
        _ method: String,
        _ urlStr: String,
        _ body: String,
        _ headers: JSValue
    ) -> LegadoStrResponse {
        let started = Date()
        let normalizedMethod = method.uppercased()
        let result = performSimpleRequest(
            method: normalizedMethod,
            urlStr: urlStr,
            body: normalizedMethod == "GET" || normalizedMethod == "HEAD" ? nil : Data(body.utf8),
            headers: Self.headerDict(from: headers),
            timeoutOverride: nil,
            followRedirects: true
        )
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: result, callTime: Int(elapsed))
    }

    /// `java.net.HttpURLConnection` as the interop runtime writes it: the body is bytes (a
    /// source posts gzip or its own binary framing), and so is the response it reads back.
    /// Java's connection follows redirects within a scheme by default.
    func httpExecuteBytes(_ method: String, _ urlStr: String, _ bodyHex: String, _ headers: JSValue) -> LegadoStrResponse {
        let started = Date()
        let normalizedMethod = method.uppercased()
        guard let body = Self.bytesFromHex(bodyHex) else {
            _ = throwIntoScript("java.io.IOException: malformed request body")
            return LegadoStrResponse(url: urlStr, body: "")
        }
        let result = performSimpleRequest(
            method: normalizedMethod,
            urlStr: urlStr,
            body: normalizedMethod == "GET" || normalizedMethod == "HEAD" || body.isEmpty ? nil : Data(body),
            headers: Self.headerDict(from: headers),
            timeoutOverride: nil,
            followRedirects: true
        )
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: result, callTime: Int(elapsed))
    }

    /// Legado `java.importScript(path)` — a remote JS library's text (`http…`, cached by
    /// `cacheFile`'s MD5 key) or a source file's (`readTxtFile`). Sources wrap it in `eval(...)`.
    /// Legado throws when the text is blank (「内容获取失败或者为空」), so a failed library
    /// stops the script there instead of leaving its functions undefined further on.
    func importScript(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if trimmed.hasPrefix("http") {
            text = importRemoteScript(trimmed)
        } else {
            text = readSourceText(trimmed, charset: nil)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return throwIntoScript("\(trimmed) 内容获取失败或者为空")
        }
        return text
    }

    /// Legado `SharedJsScope`'s download of a JSON-object jsLib's library: the bare
    /// `okHttpClient`, whose interceptor adds `AppConfig.userAgent` — no source headers, no
    /// AnalyzeUrl options. Runs no JS, so any thread may call it.
    func downloadSharedLibrary(_ url: String) -> LegadoHTTPResult {
        Self.performPlainRequest(url, in: RequestContext(
            analyzeUrlHandler: nil,
            networkHandler: networkHandler,
            sourceHeaders: ["User-Agent": BookSource.legadoDefaultUserAgent],
            timeoutSeconds: requestTimeoutSeconds,
            networkWaits: networkWaits
        ))
    }

    /// Legado's `importScript(http…)` is `cacheFile(url)`.
    private func importRemoteScript(_ url: String) -> String {
        cacheFile(url, JSValue(undefinedIn: JSContext.current()))
    }

    // MARK: Source files

    /// Where `java.readFile` / `downloadFile` / … keep a source's files: Legado's
    /// `externalCache`, one directory every source shares. Sources keep the relative paths
    /// these calls answer (`source.put`) and read them back later, so the root is fixed.
    static let sourceFilesRoot: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LegadoSourceFiles", isDirectory: true)

    /// Legado `JsExtensions.getFile(path)`: `path` under the files root, `/` or not. A path
    /// that leaves the root throws into the script (Legado's 「非法路径」) and answers nil.
    /// Legado allows the root's parent too (the app's whole external directory); here a
    /// source reaches only its files root.
    private func sourceFile(_ path: String) -> URL? {
        let root = Self.sourceFilesRoot.standardizedFileURL
        let relative = path.drop(while: { $0 == "/" })
        let file = relative.isEmpty ? root : root.appendingPathComponent(String(relative)).standardizedFileURL
        guard file.path == root.path || file.path.hasPrefix(root.path + "/") else {
            _ = throwIntoScript("非法路径: \(path)")
            return nil
        }
        return file
    }

    /// The path a written file is answered as: relative to the files root, with a leading `/`,
    /// as Legado's `path.substring(cachePath.length)`.
    private static func sourceFilePath(_ file: URL) -> String {
        let root = sourceFilesRoot.standardizedFileURL.path
        return String(file.standardizedFileURL.path.dropFirst(root.count))
    }

    /// Legado `java.readFile(path)`: the file's bytes, `null` when there is none. A directory
    /// throws, as `File.readBytes` does.
    func readFile(_ path: String) -> JSValue {
        let null = JSValue(nullIn: JSContext.current())!
        guard let file = sourceFile(path) else { return null }
        guard let data = readSourceFileData(file) else { return null }
        return JSValue(object: data.map(Int.init), in: JSContext.current())
    }

    /// Legado `java.readTxtFile(path[, charsetName])`: the file's text, `""` when there is
    /// none. Without a charset the page decoder's detection reads it (Legado's `EncodingDetect`).
    func readTxtFile(_ path: String, _ charset: JSValue) -> String {
        readSourceText(path, charset: Self.optionalString(charset))
    }

    private func readSourceText(_ path: String, charset: String?) -> String {
        guard let file = sourceFile(path), let data = readSourceFileData(file) else { return "" }
        if let name = charset, !name.isEmpty {
            return String(data: data, encoding: Self.stringEncoding(name)) ?? ""
        }
        return HTMLResponseDecoder.decode(data: data, response: nil, declaredCharset: nil) ?? ""
    }

    /// nil when there is no file; a directory or an unreadable file throws into the script.
    private func readSourceFileData(_ file: URL) -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            _ = throwIntoScript("\(file.path) (Is a directory)")
            return nil
        }
        do {
            return try Data(contentsOf: file)
        } catch {
            _ = throwIntoScript("\(file.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Legado `java.deleteFile(path)`: the file, or the directory with all it holds. `false`
    /// when there was nothing to delete.
    func deleteFile(_ path: String) -> Bool {
        guard let file = sourceFile(path),
              FileManager.default.fileExists(atPath: file.path) else { return false }
        do {
            try FileManager.default.removeItem(at: file)
            return true
        } catch {
            AppLogger.parse("java.deleteFile failed", context: [
                "path": String(path.prefix(200)), "error": error.localizedDescription,
            ])
            return false
        }
    }

    /// Legado `java.downloadFile(url)`: the response's bytes saved under the files root as
    /// `md5_16(url).<type>` — the URL's `type` option, else its suffix — answered as that
    /// file's path. `java.downloadFile(hex, url)` (deprecated in Legado) saves the hex's bytes
    /// instead, and answers "" when the URL has no `type` option.
    func downloadFile(_ first: String, _ second: JSValue) -> String {
        if let url = Self.optionalString(second) {
            return saveHexFile(hex: first, url: url)
        }
        let url = first
        let context = requestContext(for: [url])
        let data: Data?
        let type: String?
        if let route = Self.analyzeUrlRoute(url, in: context) {
            let response = networkWaits.during { route.request?.fetch() }
            data = response?.data
            type = route.request?.type
        } else {
            data = Self.performPlainRequest(url, in: context).data
            type = nil
        }
        guard let data else {
            return throwIntoScript("downloadFile: no response from \(AnalyzeUrl.stripOptions(from: url).prefix(200))")
        }
        return writeSourceFile(data, url: url, type: type ?? Self.urlSuffix(url))
    }

    /// Legado `java.cacheFile(url[, saveTime])`: the text of `url`, downloaded once. The
    /// download's path is kept in the source's cache under `md5_16(url)` for `saveTime` seconds
    /// (0 or none: for good), and while it is there and the file exists, the file is read
    /// instead of the network — as `readTxtFile`, so its charset is detected. 拷贝轻说
    /// (YCK1331) reads every chapter's text this way.
    ///
    /// Unlike Legado, a download that reads blank or as a Cloudflare challenge is not kept:
    /// Legado keeps whatever came back, and a source whose first fetch hit the challenge read
    /// that page in place of its library for good.
    func cacheFile(_ url: String, _ saveTime: JSValue) -> String {
        let key = md5Encode16(url)
        let cache = importScriptCacheProvider?()
        if let path = cache?.get(key), existingSourceFile(path) != nil {
            return readSourceText(path, charset: nil)
        }
        let path = downloadFile(url, JSValue(undefinedIn: JSContext.current()))
        // `downloadFile` threw into the script; there is no file to keep or read.
        guard !path.isEmpty else { return "" }
        log("首次下载 \(url) >> \(path)")
        let text = readSourceText(path, charset: nil)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.isCloudflareChallengedBody(text) {
            let seconds = saveTime.isUndefined || saveTime.isNull ? 0 : Int(saveTime.toInt32())
            cache?.put(key, path, saveTime: seconds)
        }
        return text
    }

    /// The file a kept `cacheFile` path names, while it is there; `nil`, without throwing, for
    /// any other value. Before `importScript` read through `cacheFile`, it kept the library's
    /// text under the same key — such a value names no file, and the next call downloads again.
    private func existingSourceFile(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\n") else { return nil }
        let root = Self.sourceFilesRoot.standardizedFileURL
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return file
    }

    private func saveHexFile(hex: String, url: String) -> String {
        // Only an AnalyzeUrl-route request has a `type`, and that route resolves its own headers.
        guard let type = Self.analyzeUrlRoute(url, in: requestContext(for: []))?.request?.type else { return "" }
        guard let bytes = Self.bytesFromHex(hex) else {
            return throwIntoScript("downloadFile: content is not hex")
        }
        return writeSourceFile(Data(bytes), url: url, type: type)
    }

    private func writeSourceFile(_ data: Data, url: String, type: String) -> String {
        let file = Self.sourceFilesRoot.appendingPathComponent("\(md5Encode16(url)).\(type)")
        do {
            try FileManager.default.createDirectory(
                at: Self.sourceFilesRoot, withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
        } catch {
            return throwIntoScript("downloadFile: \(error.localizedDescription)")
        }
        return Self.sourceFilePath(file)
    }

    /// Legado `UrlUtil.getSuffix(url)`: the last path segment's extension when it is 1–5
    /// letters or digits, else `ext`.
    static func urlSuffix(_ url: String) -> String {
        let address = AnalyzeUrl.stripOptions(from: url)
        let segment = address.split(separator: "/").last.map(String.init) ?? ""
        let name = segment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let bare = name.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        guard let dot = bare.lastIndex(of: ".") else { return "ext" }
        let suffix = bare[bare.index(after: dot)...]
        guard !suffix.isEmpty, suffix.count <= 5,
              suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return "ext" }
        return String(suffix)
    }

    // MARK: Cookie Helpers

    func getCookie(_ url: String) -> String {
        return CookieStore.shared.get(url: url)
    }

    func getCookie(_ url: String, _ key: String) -> String {
        getCookieValue(url, key)
    }

    func getCookieValue(_ url: String, _ key: String) -> String {
        let cookie = CookieStore.shared.get(url: url)
        guard !key.isEmpty else { return cookie }
        return cookie
            .split(separator: ";")
            .compactMap { part -> String? in
                let pieces = part.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard pieces.count == 2, pieces[0] == key else { return nil }
                return pieces[1]
            }
            .first ?? ""
    }

    /// Legado `java.removeCookie(url)` — clears cookies for the host of `url`.
    /// (The `cookie.removeCookie` bridge has the same effect; some sources call it via `java`.)
    func removeCookie(_ url: String) {
        CookieStore.shared.remove(url: url)
    }

    /// Legado: `WebSettings.getDefaultUserAgent` — the phone browser's own identity, not the
    /// desktop `AppConfig.userAgent` requests default to. Sources put it in their header rule
    /// for a site's mobile pages; ours is the identity the app's WebViews present. It was a
    /// truncated `… AppleWebKit/605.1.15`, without the `Mobile/… Safari/…` tail sites test for.
    func getWebViewUA() -> String {
        SourceWebIdentity.phoneUserAgent
    }

    // MARK: Variable Storage

    @discardableResult func put(_ key: String, _ value: String) -> String {
        putData?(key, value)
        return value
    }

    func get(_ key: String) -> String {
        return getData?(key) ?? ""
    }

    /// Legado's `java.get(urlStr, headers)` — an HTTP GET returning a response the
    /// source calls `.body()` on. Legado overloads by arity (Rhino dispatches on
    /// argument count); JSExport cannot, so the JS shim in `installJavaGetOverload`
    /// routes the two-argument call here and leaves the one-argument variable getter
    /// above alone.
    ///
    /// This uses a typed request path so the response URL, status, headers, and
    /// cookies survive alongside the body.
    func httpGet(_ urlStr: String, _ headers: JSValue) -> LegadoStrResponse {
        let started = Date()
        let headerMap = headers.isUndefined || headers.isNull
            ? [:] : Self.headerDict(from: headers)
        // Legado-E `java.get(url, headers)`: jsoup with `followRedirects(false)`.
        let response = performJsoupRequest(method: "GET", urlStr, body: nil, headers: headerMap, timeoutOverride: nil)
        let elapsed = Date().timeIntervalSince(started) * 1000
        recordBlockingNetwork(elapsed)
        return LegadoStrResponse(result: response, callTime: Int(elapsed))
    }

    // MARK: Rule Evaluation (placeholder)

    /// `java.getString(rule)` evaluates against the response currently being parsed;
    /// `java.getString(rule, obj)` evaluates against `obj` instead (Legado's `mContent`).
    /// Sources that fetch a JSON body themselves and then pull a field out of it rely on the
    /// two-argument form — e.g. 番茄酱's `to.js` does
    /// `java.getString("$..content", java.ajax(...))`. Ignoring the second argument silently
    /// evaluated the rule against the wrong document and returned "".
    func getString(_ ruleStr: String, _ mContent: JSValue) -> String {
        if let content = Self.ruleInput(from: mContent) {
            guard let handler = getStringWithContentHandler else {
                AppLogger.parse(
                    "java.getString(rule, mContent) called with no rule engine attached",
                    context: ["rule": String(ruleStr.prefix(60))]
                )
                return ""
            }
            return handler(ruleStr, content) ?? ""
        }
        return _evaluateString(ruleStr)
    }

    /// Converts an optional JS `mContent` argument into rule-engine input.
    /// `undefined`/`null` mean "not supplied" — fall back to the current parse content.
    static func ruleInput(from value: JSValue) -> Any? {
        guard !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        // A jsoup Element the script holds is read as that element, as Legado reads it.
        if let element = LegadoJsoupElement.ruleValue(from: value) { return element }
        return value.toObject()
    }

    func getStringList(_ ruleStr: String) -> [String] {
        return getStringListHandler?(ruleStr) ?? []
    }

    /// Legado `AnalyzeRule.setContent(content, baseUrl)` on the `AnalyzeRule` that is `java`
    /// in the running rule step: what every later read of that reader sees — `java.getString`,
    /// the step's next rules, the item's next fields — until it is given its next content
    /// (`BookList`'s `setContent(item)` for each row). It used to be kept here and read by
    /// every one-argument `java.getString` after it, in every later step, row and parse of the
    /// context: 爱发电 (YCK1331) sets its posts page in the discover list script, and each
    /// row's URL script then read that page instead of the row (`album_id=` empty).
    @discardableResult
    func setContent(_ content: JSValue, _ baseUrl: JSValue) -> String {
        guard let input = Self.ruleInput(from: content) else {
            // Kotlin's `AssertionError`, which the script sees as an exception.
            if let context = JSContext.current() {
                context.exception = JSValue(newErrorFromMessage: "内容不可空（Content cannot be null）", in: context)
            }
            return ""
        }
        guard let setContentHandler else {
            AppLogger.parse("java.setContent called outside a rule step (no rule reader)", level: .anomaly)
            return ""
        }
        // `setBaseUrl(null)` keeps the base the reader had.
        setContentHandler(input, baseUrl.isString ? baseUrl.toString() : nil)
        return ""
    }

    func getElements(_ ruleStr: String) -> Any {
        let value = getElementsHandler?(ruleStr) ?? [Any]()
        if value is JsoupSelection { return LegadoJsoupElement.bridged(value, trees: scriptTrees) }
        return (value as? [Any] ?? []).map { LegadoJsoupElement.bridged($0, trees: scriptTrees) }
    }

    func getElementValue(_ ruleStr: String) -> Any? {
        getElementHandler?(ruleStr).map { LegadoJsoupElement.bridged($0, trees: scriptTrees) }
    }

    func newAnalyzeRule() -> LegadoAnalyzeRule? {
        guard let engine = analyzeRuleFactory?() else {
            AppLogger.parse("AnalyzeRule() called with no rule reader (no factory, or its parser is gone)", level: .anomaly)
            return nil
        }
        return LegadoAnalyzeRule(engine: engine, trees: scriptTrees)
    }

    func digestBytes(_ bytes: JSValue, _ algorithm: String) -> [Int] {
        Self.digestData(Data(Self.byteArray(from: bytes)), algorithm: algorithm)?.map(Int.init) ?? []
    }

    func sleepMillis(_ millis: Double) {
        guard millis.isFinite, millis > 0 else { return }
        // Sources pace their requests with this (八叉书库, 兽人小说站, 晋江). It runs on the
        // script's own serial queue, which the rule's watchdog still bounds.
        Thread.sleep(forTimeInterval: min(millis, 30_000) / 1000)
    }

    func makeStrResponse(_ url: String, _ body: String) -> LegadoStrResponse {
        LegadoStrResponse(url: url, body: body)
    }

    /// Legado `AnalyzeUrl.getUserAgent`: the source's User-Agent, else `AppConfig.userAgent`.
    func getUserAgent() -> String {
        sourceHeaders.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
            ?? BookSource.legadoDefaultUserAgent
    }

    private func _evaluateString(_ ruleStr: String) -> String {
        getStringHandler?(ruleStr) ?? ""
    }

    // MARK: Browser & Toast (Legado java.startBrowser / startBrowserAwait / toast)

    /// Opens a page without waiting for it — Legado `SourceVerificationHelp.startBrowser`
    /// with `saveResult = false`.
    func startBrowser(_ url: String, _ title: String) {
        startBrowser(url, title, nil)
    }

    /// Legado `java.startBrowser(url, title, html)`: `html` is shown with `url` as its base.
    /// While a video episode is being fetched, a page of the source's (no `html`) is where that
    /// episode plays (`videoEpisodeHandover`).
    func startBrowser(_ url: String, _ title: String, _ html: String?) {
        if videoEpisodeHandover != nil, html == nil {
            if videoEpisodeHandover?.page == nil { videoEpisodeHandover?.page = url }
            return
        }
        browserPresenter?(browserRequest(url: url, title: title, awaitsResult: false, html: html)) { _ in }
    }

    /// Legado `java.startBrowserAwait(url, title)`: `refetchAfterSuccess` defaults to true.
    func startBrowserAwait(_ url: String, _ title: String) -> LegadoStrResponse {
        startBrowserAwait(url, title, true)
    }

    /// Opens a page and blocks the JS thread until the user is done with it — Legado's
    /// `SourceVerificationHelp.getVerificationResult`, which both Legado-E and MD3 run from
    /// any script: search, a chapter, 書源驗證.
    ///
    /// When the page is confirmed (✓, or a Cloudflare challenge on it clearing),
    /// `refetchAfterSuccess` requests `url` again through the source's own requests — now
    /// carrying the cookies the page earned — and returns that response; otherwise the
    /// page's HTML comes back. That is how a source gets the JSON API behind a challenge
    /// rather than the challenge page's markup.
    ///
    /// Waits for the actual dismissal — no deadline. A settings page (光遇's 书源设置,
    /// where the user ticks 默认搜索网站) is easily open for minutes; the old 60s cap
    /// resumed the JS with an empty body, and source JS reads its `<span>` values out of
    /// that body, so it saved every setting as "" and search silently fell back to 全部.
    /// Dismissal is guaranteed to be signalled by the presenter (see `BrowserAwaitBox`).
    ///
    /// A cancelled browser (no body: ✕, swipe-away, or nothing to present) throws into JS
    /// exactly like Legado does, instead of handing back an empty page: source JS wraps
    /// this call in try/catch precisely so it can skip saving when the user didn't confirm.
    func startBrowserAwait(_ url: String, _ title: String, _ refetchAfterSuccess: Bool) -> LegadoStrResponse {
        startBrowserAwait(url, title, refetchAfterSuccess, nil)
    }

    /// Legado `java.startBrowserAwait(url, title, refetchAfterSuccess, html)`: the page shows
    /// `html` with `url` as its base. `refetchAfterSuccess` still requests `url` — the
    /// original Legado and MD3 refetch whenever it is set; only Legado-E hands `html` back.
    func startBrowserAwait(
        _ url: String, _ title: String, _ refetchAfterSuccess: Bool, _ html: String?
    ) -> LegadoStrResponse {
        guard let presenter = browserPresenter else {
            return throwBrowserCancelled(url: url)
        }
        // The page is presented on the main thread, so waiting for it there could never
        // end. Legado refuses the same way (`check(!isMainThread)`).
        guard !Thread.isMainThread else {
            AppLogger.parse("startBrowserAwait called on the main thread", context: ["url": String(url.prefix(200))])
            return throwBrowserCancelled(url: url)
        }
        var request = browserRequest(url: url, title: title, awaitsResult: true, html: html)
        let withdrawal = SourceWaitWithdrawal()
        request.withdrawal = withdrawal
        guard let body = waitForUser(withdrawal: withdrawal, { presenter(request, $0) }) else {
            return throwBrowserCancelled(url: url)
        }
        guard refetchAfterSuccess else {
            return LegadoStrResponse(url: url, body: body)
        }
        return LegadoStrResponse(result: performRequestResult(url))
    }

    private func browserRequest(
        url: String, title: String, awaitsResult: Bool, html: String? = nil
    ) -> SourceBrowserRequest {
        SourceBrowserRequest(
            url: url,
            title: title,
            urlRequest: sourceBrowserRequest(urlString: url),
            awaitsResult: awaitsResult,
            html: html
        )
    }

    /// Legado `java.getVerificationCode(imageUrl)` — `SourceVerificationHelp
    /// .getVerificationResult(useBrowser = false)`: shows the image with a text field and
    /// blocks the script until the user answers. Legado throws when nothing came back
    /// (`验证结果为空`), so a dismissed sheet or an empty answer throws here too.
    func getVerificationCode(_ imageUrl: String) -> String {
        guard let presenter = captchaPresentHandler ?? Self.sharedCaptchaPresenter else {
            return throwIntoScript("getVerificationCode: no captcha presenter")
        }
        guard !Thread.isMainThread else {
            AppLogger.parse("getVerificationCode called on the main thread", context: ["url": String(imageUrl.prefix(200))])
            return throwIntoScript("getVerificationCode: called on the main thread")
        }
        let identity = sourceIdentityProvider?() ?? (name: "", url: "")
        let withdrawal = SourceWaitWithdrawal()
        let request = SourceCaptchaRequest(
            imageURL: imageUrl,
            headers: sourceBrowserRequest(urlString: imageUrl)?.allHTTPHeaderFields ?? [:],
            sourceName: identity.name,
            sourceURL: identity.url,
            withdrawal: withdrawal
        )
        guard let code = waitForUser(withdrawal: withdrawal, { presenter(request, $0) }), !code.isEmpty else {
            return throwIntoScript("getVerificationCode: no code entered")
        }
        return code
    }

    /// The request a source's page opens with, as Legado's `WebViewModel` builds it: the
    /// URL's own `,{"headers":…}` options, then the source's headers and login headers (the
    /// same set `java.ajax` sends), then the cookie jar. nil for anything but http(s).
    func sourceBrowserRequest(urlString: String) -> URLRequest? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = AnalyzeUrl.stripOptions(from: trimmed)
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        var request = URLRequest(url: url)
        if address.count < trimmed.count {
            for (key, value) in Self.optionHeaders(String(trimmed.dropFirst(address.count))) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        for (key, value) in sourceHeaders where request.value(forHTTPHeaderField: key) == nil {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "Cookie") == nil {
            let jar = CookieStore.shared.get(url: url.absoluteString)
            if !jar.isEmpty { request.setValue(jar, forHTTPHeaderField: "Cookie") }
        }
        return request
    }

    /// The `headers` of a Legado URL option block (`,{"headers":{…}}`): a map, or the same
    /// map as a JSON string.
    private static func optionHeaders(_ optionSuffix: String) -> [String: String] {
        guard let start = optionSuffix.firstIndex(of: "{"),
              let options = AnalyzeUrl.parseOptionDictionary(String(optionSuffix[start...])) else {
            return [:]
        }
        let raw: Any?
        if let text = options["headers"] as? String {
            raw = AnalyzeUrl.parseOptionDictionary(text)
        } else {
            raw = options["headers"]
        }
        guard let headers = raw as? [String: Any] else { return [:] }
        return headers.reduce(into: [:]) { result, entry in
            result[entry.key] = "\(entry.value)"
        }
    }

    /// Raise a JS exception at the `java.startBrowserAwait(...)` call site. The returned
    /// value is never consumed: the exception propagates as soon as the bridge call returns.
    private func throwBrowserCancelled(url: String) -> LegadoStrResponse {
        _ = throwIntoScript("startBrowserAwait: dismissed without confirmation")
        return LegadoStrResponse(url: url, body: "")
    }

    /// Raises `message` as a JS exception at the current bridge call site.
    private func throwIntoScript(_ message: String) -> String {
        if let context = JSContext.current() {
            context.exception = JSValue(newErrorFromMessage: message, in: context)
        }
        return ""
    }

    /// Show a short toast. Delegates to `toastHandler` on MainThread.
    ///
    /// The handler is the one installed when the script called `toast`, not whichever is
    /// installed by the time the main queue runs: a host that installs its own for one
    /// evaluation (a detail page's 簡介 button) restores the previous one as soon as the
    /// script returns, usually before this delivery.
    func toast(_ msg: String) {
        #if DEBUG
        print("[JSBridge toast] \(msg)")
        #endif
        let handler = toastHandler
        DispatchQueue.main.async { handler?(msg) }
    }

    func longToast(_ msg: String) { toast(msg) }

    // MARK: Search hand-off

    /// `java.searchBook(key, source)` — a discover page's own search box handing a
    /// keyword back to the app (洋柿子's 發現頁 search field). The `source` argument is
    /// accepted for signature parity and ignored: the search screen already searches
    /// every enabled source, and narrowing it would silently change what the user
    /// asked for. `java.open('search', key)` is the source's fallback for the same
    /// thing, so both land here.
    func searchBook(_ key: String, _ source: JSValue?) {
        requestAppSearch(keyword: key)
    }

    /// `java.open(target, argument)`. Only `search` is meaningful to this app; any
    /// other target is logged rather than silently swallowed, so a source asking for
    /// something we do not route shows up in the device log instead of looking dead.
    func open(_ target: String, _ argument: JSValue?) {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = argument?.isUndefined == false ? (argument?.toString() ?? "") : ""
        guard name == "search" else {
            AppLogger.parse("⟐ java.open unrouted", context: ["target": target, "arg": value])
            return
        }
        requestAppSearch(keyword: value)
    }

    /// Single funnel for both entry points. Broadcast rather than wired per engine:
    /// the request can come from the discover session's bridge, a login sheet, or a
    /// background parse, none of which own a screen to navigate.
    private func requestAppSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppLogger.parse("⟐ java.searchBook empty keyword", context: [:])
            return
        }
        AppLogger.parse("⟐ java.searchBook", context: ["keyword": String(trimmed.prefix(60))])
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .bookSourceRequestedSearch,
                object: nil,
                userInfo: ["keyword": trimmed]
            )
        }
    }

    // MARK: Logging

    /// `java.log(...)` — the source author's own diagnostic channel (「请求共享接口
    /// /novel/chap 异常：…」). It used to be DEBUG-only `print`, i.e. invisible in the
    /// exact situation it exists for: a rule failing on a real device.
    @discardableResult
    func log(_ msg: String) -> String {
        AppLogger.parse("⟐ source log", context: [
            "msg": String(msg.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        ])
        return msg
    }

    func logType(_ msg: String) {
        #if DEBUG
        print("[JSBridge logType] \(type(of: msg)): \(msg)")
        #endif
    }

    func setResponseBase64(_ data: String, _ mimeType: String) {
        guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
            log("setResponseBase64: invalid base64 data (\(data.count) chars)")
            return
        }
        setResponseBase64Handler?(decoded, mimeType)
    }

    // MARK: Utilities

    func timeFormat(_ timestamp: JSValue) -> String {
        let ms: Double
        if timestamp.isNumber {
            ms = timestamp.toDouble()
        } else if let str = timestamp.toString(), let parsed = Double(str) {
            ms = parsed
        } else {
            return ""
        }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    /// hutool's `Base64.decodeStr` (`LegadoBase64.hutoolDecode`), its bytes read as UTF-8 the way
    /// Java's `String(bytes, UTF_8)` reads them: a malformed sequence becomes U+FFFD.
    func base64Decode(_ str: String) -> String {
        String(decoding: LegadoBase64.hutoolDecode(str), as: UTF8.self)
    }

    func base64Encode(_ str: String) -> String {
        guard let data = str.data(using: .utf8) else { return "" }
        return data.base64EncodedString()
    }

    func HMacBase64(_ content: String, _ algorithm: String, _ key: String) -> String {
        guard let mac = Self.hmac(Data(content.utf8), key: Data(key.utf8), algorithm: algorithm) else {
            AppLogger.parse(
                "Legado bridge rejected unsupported HMAC algorithm",
                context: ["algorithm": algorithm]
            )
            return ""
        }
        return mac.base64EncodedString()
    }

    /// `javax.crypto.Mac.doFinal`: bytes in, bytes out. An algorithm Java would not know
    /// throws its NoSuchAlgorithmException into the script.
    func hmacBytes(_ data: JSValue, _ algorithm: String, _ key: JSValue) -> [Int] {
        guard let mac = Self.hmac(Data(Self.byteArray(from: data)), key: Data(Self.byteArray(from: key)), algorithm: algorithm) else {
            _ = throwIntoScript("java.security.NoSuchAlgorithmException: Algorithm \(algorithm) not available")
            return []
        }
        return mac.map(Int.init)
    }

    /// HMAC by Java's algorithm name (`HmacSHA256`; the bare digest name also reads).
    private static func hmac(_ message: Data, key: Data, algorithm: String) -> Data? {
        let normalized = algorithm.uppercased().filter { $0.isLetter || $0.isNumber }
        let symmetricKey = SymmetricKey(data: key)
        switch normalized {
        case "HMACMD5", "MD5":
            return Data(HMAC<Insecure.MD5>.authenticationCode(for: message, using: symmetricKey))
        case "HMACSHA1", "SHA1":
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
        case "HMACSHA224", "SHA224":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            key.withUnsafeBytes { keyBuffer in
                message.withUnsafeBytes { messageBuffer in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA224),
                        keyBuffer.baseAddress,
                        keyBuffer.count,
                        messageBuffer.baseAddress,
                        messageBuffer.count,
                        &digest
                    )
                }
            }
            return Data(digest)
        case "HMACSHA256", "SHA256":
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
        case "HMACSHA384", "SHA384":
            return Data(HMAC<SHA384>.authenticationCode(for: message, using: symmetricKey))
        case "HMACSHA512", "SHA512":
            return Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
        default:
            return nil
        }
    }

    func HMacHex(_ content: String, _ algorithm: String, _ key: String) -> String {
        guard let data = Data(base64Encoded: HMacBase64(content, algorithm, key)) else { return "" }
        return Self.hexString(data)
    }

    func digestHex(_ content: String, _ algorithm: String) -> String {
        Self.digestData(Data(content.utf8), algorithm: algorithm).map { Self.hexString($0) } ?? ""
    }

    func digestBase64Str(_ content: String, _ algorithm: String) -> String {
        Self.digestData(Data(content.utf8), algorithm: algorithm)?.base64EncodedString() ?? ""
    }

    func strToBytes(_ str: String, _ charset: JSValue) -> [Int] {
        let encoding = Self.stringEncoding(Self.optionalString(charset) ?? "UTF-8")
        return (str.data(using: encoding, allowLossyConversion: false) ?? Data()).map(Int.init)
    }

    func bytesToStr(_ bytes: JSValue, _ charset: JSValue) -> String {
        let data = Data(Self.byteArray(from: bytes))
        return String(
            data: data,
            encoding: Self.stringEncoding(Self.optionalString(charset) ?? "UTF-8")
        ) ?? ""
    }

    /// `android.util.Base64.decode(str, DEFAULT)` (`LegadoBase64.androidDecode`). Text it calls
    /// "bad base-64" throws into the script, as the `IllegalArgumentException` does there.
    func base64DecodeToByteArray(_ str: String) -> [Int] {
        guard let data = LegadoBase64.androidDecode(str) else {
            AppLogger.parse("Legado bridge rejected invalid Base64 byte-array input", context: [
                "length": "\(str.utf16.count)", "head": String(str.prefix(40)),
            ])
            _ = throwIntoScript("bad base-64")
            return []
        }
        return data.map(Int.init)
    }

    func hexDecodeToByteArray(_ hex: String) -> [Int] {
        Self.bytesFromHex(hex)?.map(Int.init) ?? []
    }

    func md5Encode(_ str: String) -> String {
        guard let data = str.data(using: .utf8) else { return "" }
        let hash = Insecure.MD5.hash(data: data)
        return Self.hexString(hash)
    }

    func md5Encode16(_ str: String) -> String {
        let full = md5Encode(str)
        guard full.count == 32 else { return full }
        let start = full.index(full.startIndex, offsetBy: 8)
        let end = full.index(start, offsetBy: 16)
        return String(full[start..<end])
    }

    // MARK: - Hex Encoding

    /// Decode a hex string to a UTF-8 string. Example: `"48656c6c6f"` → `"Hello"`.
    func hexDecodeToString(_ hex: String) -> String {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return "" }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return "" }
            bytes.append(byte)
            idx = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Encode a string to lowercase hex. Example: `"Hello"` → `"48656c6c6f"`.
    func hexEncodeToString(_ str: String) -> String {
        Self.hexString(str.utf8)
    }

    private static func digestData(_ data: Data, algorithm: String) -> Data? {
        switch algorithm.uppercased().filter({ $0.isLetter || $0.isNumber }) {
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        case "SHA1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA224":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { buffer in
                _ = CC_SHA224(buffer.baseAddress, CC_LONG(data.count), &digest)
            }
            return Data(digest)
        case "SHA256": return Data(SHA256.hash(data: data))
        case "SHA384": return Data(SHA384.hash(data: data))
        case "SHA512": return Data(SHA512.hash(data: data))
        default:
            AppLogger.parse("Legado bridge rejected unsupported digest algorithm", context: [
                "algorithm": algorithm
            ])
            return nil
        }
    }

    /// A charset name as a source passes it — IANA or Java (`ISO8859_1`) — read by the one
    /// resolver the page decoder uses. An unknown name is UTF-8, logged.
    private static func stringEncoding(_ charset: String) -> String.Encoding {
        if let encoding = HTMLResponseDecoder.encoding(forIANA: charset) { return encoding }
        AppLogger.parse("Legado bridge read an unknown charset as UTF-8", context: ["charset": charset])
        return .utf8
    }

    private static func byteArray(from value: JSValue) -> [UInt8] {
        if value.isString {
            return Array((value.toString() ?? "").utf8)
        }
        return (value.toArray() ?? []).compactMap { item in
            if let number = item as? NSNumber { return UInt8(truncating: number) }
            if let int = item as? Int { return UInt8(truncatingIfNeeded: int) }
            return nil
        }
    }

    // MARK: - Symmetric Crypto

    /// Symmetric decrypt. Inputs/output are lowercase hex; `""` on failure.
    /// `transformation` is a Java-style spec like `AES/CBC/PKCS5Padding`.
    /// Backs the `javax.crypto.Cipher` / hutool `SymmetricCrypto` JS shims so Legado
    /// sources that decrypt chapter content via raw Java crypto work under
    /// JavaScriptCore (七猫-明月: AES; 书山聚合: `DES/CBC/PKCS5Padding`).
    /// Name kept as `aes…` because it is the JS-visible bridge API Legado defines.
    func aesDecryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String {
        return Self.symmetricCrypt(encrypt: false, transformation: transformation, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
    }

    /// Symmetric encrypt. Inputs/output are lowercase hex; `""` on failure.
    func aesEncryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String {
        return Self.symmetricCrypt(encrypt: true, transformation: transformation, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
    }

    func rsaCryptHex(
        _ transformation: String, _ keyHex: String, _ usePublicKey: Bool, _ encrypt: Bool, _ dataHex: String
    ) -> String {
        guard let key = Self.bytesFromHex(keyHex), let data = Self.bytesFromHex(dataHex) else {
            return throwIntoScript("createAsymmetricCrypto: malformed key or data")
        }
        do {
            let output = try LegadoAsymmetricCrypto.crypt(
                transformation: transformation, key: key, usePublicKey: usePublicKey,
                encrypt: encrypt, data: data
            )
            return Self.hexString(output)
        } catch {
            return throwIntoScript("createAsymmetricCrypto: \(error)")
        }
    }

    /// Hex string → bytes (nil on malformed input).
    /// The bytes of `hex`, whitespace skipped; `nil` for anything else that is not a hex digit or
    /// an odd count of them. Read scalar by scalar, not as `Character` pairs: 番茄听书 (YCK1330)
    /// saves a chapter's audio as 16 million hex digits, which took 1.6 s that way (11-09).
    private static func bytesFromHex(_ hex: String) -> [UInt8]? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for scalar in hex.unicodeScalars {
            let nibble: UInt8
            switch scalar.value {
            case 0x30...0x39: nibble = UInt8(scalar.value - 0x30)
            case 0x61...0x66: nibble = UInt8(scalar.value - 0x61 + 10)
            case 0x41...0x46: nibble = UInt8(scalar.value - 0x41 + 10)
            default:
                guard scalar.properties.isWhitespace else { return nil }
                continue
            }
            if let first = high {
                bytes.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? bytes : nil
    }

    /// Lowercase hex of `bytes`, as Hutool's `HexUtil.encodeHexStr` writes it — every hex the
    /// bridge hands a script. From a table, not `String(format: "%02x")` a byte: 番茄听书
    /// (YCK1330) fetches a chapter's audio as hex (`url,{"type":"hex"}`) and decrypts it one
    /// sample at a time through `Cipher.doFinal`, and formatting 8 MB that way took 5 s of the
    /// 30 a script has (11-09).
    static func hexString(_ bytes: some Sequence<UInt8>) -> String {
        var utf8 = [UInt8]()
        utf8.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            utf8.append(hexDigits[Int(byte >> 4)])
            utf8.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// `LegadoSymmetricCipher` over hex; "" on failure, logged (a script tests for it: 书山聚合
    /// falls back to Base64 when `decryptStr` gives nothing).
    private static func symmetricCrypt(encrypt: Bool, transformation: String, keyHex: String, ivHex: String, dataHex: String) -> String {
        guard let key = bytesFromHex(keyHex), let data = bytesFromHex(dataHex) else { return "" }
        // A decrypt of nothing is nothing; an encrypt of nothing is still a padded block.
        guard encrypt || !data.isEmpty else { return "" }
        let iv = bytesFromHex(ivHex) ?? []
        do {
            let output = try LegadoSymmetricCipher.crypt(
                encrypt: encrypt, transformation: transformation, key: key, iv: iv, data: data
            )
            return Self.hexString(output)
        } catch {
            AppLogger.parse("⟐ crypto failed", context: [
                "transformation": transformation,
                "error": "\(error)",
                "keyBytes": key.count,
                "ivBytes": iv.count,
                "dataBytes": data.count,
            ])
            return ""
        }
    }

    // MARK: - URL Encoding

    /// Legado's `java.encodeURI(str)` and `java.encodeURI(str, enc)`: Java's
    /// `URLEncoder.encode(str, enc ?: "UTF-8")`, a form encoder (a space is `+`; `/ ? : & = +`
    /// are encoded), in the named charset; "" for a charset Java rejects, as Legado catches the
    /// exception. The JS-`encodeURI`-style encoder before it kept `/?:&=+` and ignored the
    /// charset, so 民间故事's `{{java.encodeURI(key,'gb2312')}}` sent UTF-8 to a GB2312 site.
    func encodeURI(_ str: String, _ enc: JSValue) -> String {
        let charset = enc.isUndefined || enc.isNull ? "UTF-8" : (enc.toString() ?? "UTF-8")
        guard let encoded = AnalyzeUrl.javaURLEncode(str, charsetName: charset) else {
            AppLogger.parse("java.encodeURI: unknown charset", context: ["charset": charset], level: .warning)
            return ""
        }
        return encoded
    }

    /// Mirrors Legado's `java.encodeURIComponent(str)`. Encodes all characters except unreserved ones.
    func encodeURIComponent(_ str: String) -> String {
        str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }

    func randomUUID() -> String {
        UUID().uuidString.lowercased()
    }

    func toNumChapter(_ title: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"第(.+?)章"#),
              let match = regex.firstMatch(
                in: title,
                range: NSRange(title.startIndex..<title.endIndex, in: title)
              ),
              let numberRange = Range(match.range(at: 1), in: title)
        else { return title }
        let rawNumber = String(title[numberRange])
        guard let number = Self.chapterNumber(rawNumber) else { return title }
        var result = title
        result.replaceSubrange(numberRange, with: String(number))
        return result
    }

    func urlParts(_ url: String, _ baseURL: JSValue) -> NSDictionary {
        let base = Self.optionalString(baseURL).flatMap(URL.init(string:))
        guard let resolved = URL(string: url, relativeTo: base)?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: true),
              let scheme = components.scheme,
              let host = components.host else { return [:] }
        let origin = scheme + "://" + host + (components.port.map { ":\($0)" } ?? "")
        let query = (components.queryItems ?? []).reduce(into: [String: String]()) {
            $0[$1.name] = $1.value ?? ""
        }
        return [
            "host": host,
            "origin": origin,
            "pathname": components.path,
            "searchParams": query,
        ]
    }

    func gzipBytes(_ value: JSValue) -> [Int] {
        Self.gzip(Data(Self.byteArray(from: value))).map(Int.init)
    }

    func inflateBytes(_ value: JSValue, _ windowBits: Int) -> NSDictionary {
        let input = Data(Self.byteArray(from: value))
        do {
            let result = try Self.inflate(input, windowBits: Int32(windowBits))
            return [
                "bytes": result.output.map(Int.init),
                "finished": result.finished,
                "consumed": result.consumed,
            ]
        } catch {
            // GZIPInputStream reads its header itself and says so; Inflater reports zlib's text.
            let message = windowBits > 15 && input.prefix(2) != Data([0x1f, 0x8b])
                ? "java.util.zip.ZipException: Not in GZIP format"
                : "java.util.zip.DataFormatException: \(error)"
            _ = throwIntoScript(message)
            return ["bytes": [Int](), "finished": false, "consumed": 0]
        }
    }

    func secureRandomBytes(_ count: Int) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(0, count)).map { _ in Int(UInt8.random(in: .min ... .max, using: &generator)) }
    }

    /// `Cipher.getInstance("AES/GCM/NoPadding")` with a `GCMParameterSpec`
    /// (`LegadoSymmetricCipher.gcm`).
    func aesGcmHex(
        _ encrypt: Bool, _ keyHex: String, _ ivHex: String, _ aadHex: String, _ tagBits: Int, _ dataHex: String
    ) -> String {
        guard let key = Self.bytesFromHex(keyHex), let iv = Self.bytesFromHex(ivHex),
              let aad = Self.bytesFromHex(aadHex), let data = Self.bytesFromHex(dataHex) else {
            return throwIntoScript("javax.crypto.IllegalBlockSizeException: malformed GCM input")
        }
        guard tagBits == 128 else {
            return throwIntoScript("java.security.InvalidAlgorithmParameterException: GCM tag of \(tagBits) bits is not supported")
        }
        do {
            let output = try LegadoSymmetricCipher.gcm(encrypt: encrypt, key: key, iv: iv, aad: aad, data: data)
            return Self.hexString(output)
        } catch {
            return throwIntoScript("javax.crypto.AEADBadTagException: \(error)")
        }
    }

    /// Java's `Cipher.getBlockSize()` for RSA is computed from this: the modulus in bytes.
    func rsaKeySizeBytes(_ keyHex: String, _ isPublic: Bool) -> Int {
        guard let key = Self.bytesFromHex(keyHex) else {
            _ = throwIntoScript("java.security.InvalidKeyException: malformed key")
            return 0
        }
        do {
            return try LegadoAsymmetricCrypto.modulusBytes(der: key, isPublic: isPublic)
        } catch {
            _ = throwIntoScript("java.security.InvalidKeyException: \(error)")
            return 0
        }
    }

    func rsaSignHex(_ algorithm: String, _ keyHex: String, _ dataHex: String) -> String {
        guard let key = Self.bytesFromHex(keyHex), let data = Self.bytesFromHex(dataHex) else {
            return throwIntoScript("java.security.SignatureException: malformed key or data")
        }
        do {
            return Self.hexString(try LegadoAsymmetricCrypto.sign(algorithm: algorithm, privateKey: key, message: data))
        } catch {
            return throwIntoScript("java.security.SignatureException: \(error)")
        }
    }

    func rsaVerify(_ algorithm: String, _ keyHex: String, _ dataHex: String, _ signatureHex: String) -> Bool {
        guard let key = Self.bytesFromHex(keyHex), let data = Self.bytesFromHex(dataHex),
              let signature = Self.bytesFromHex(signatureHex) else {
            _ = throwIntoScript("java.security.SignatureException: malformed key, data or signature")
            return false
        }
        do {
            return try LegadoAsymmetricCrypto.verify(
                algorithm: algorithm, publicKey: key, message: data, signature: signature
            )
        } catch {
            _ = throwIntoScript("java.security.SignatureException: \(error)")
            return false
        }
    }

    func absoluteURL(_ spec: String, _ base: String) -> String {
        AnalyzeUrl.javaAbsoluteURL(spec, base: base) ?? ""
    }

    /// `java.net.Socket.connect(address, timeout)`: sources time mirrors with it and pick the
    /// fastest. Java's timeout 0 waits forever; here it is the request timeout.
    func tcpConnectMillis(_ host: String, _ port: Int, _ timeoutMillis: Int) -> Int {
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            return -1
        }
        let timeout = timeoutMillis > 0 ? TimeInterval(timeoutMillis) / 1000 : requestTimeoutSeconds
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let outcome = BlockingResult<Bool>()
        let delivered = OSAllocatedUnfairLock(initialState: false)
        connection.stateUpdateHandler = { state in
            let connected: Bool
            switch state {
            case .ready: connected = true
            case .failed, .waiting, .cancelled: connected = false
            default: return
            }
            let first = delivered.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { outcome.deliver(connected) }
        }
        let started = Date()
        connection.start(queue: .global(qos: .utility))
        let connected = networkWaits.during { outcome.wait(timeout: .now() + timeout) } ?? false
        let elapsed = Date().timeIntervalSince(started) * 1000
        connection.cancel()
        recordBlockingNetwork(elapsed)
        return connected ? Int(elapsed) : -1
    }

    /// Matches Android `JsExtensions.getThemeMode()` rather than returning the
    /// currently resolved trait: sources use `0` to distinguish follow-system
    /// from a user-pinned light/dark appearance.
    func getThemeMode() -> String {
        let defaults = UserDefaults.standard
        let followsSystemKey = "yd_appearance_follows_system"
        let followsSystem = defaults.object(forKey: followsSystemKey) == nil
            ? true
            : defaults.bool(forKey: followsSystemKey)
        guard !followsSystem else { return "0" }
        return defaults.string(forKey: "yd_appearance_pinned_color_scheme") == "dark"
            ? "2"
            : "1"
    }

    /// Android returns its durable ThemeConfig as JSON. iOS has a different
    /// theme model, so expose the equivalent resolved background fields that
    /// source rules consume while preserving Android's JSON shape.
    func getThemeConfig() -> String {
        let values = resolvedThemeConfigValues()
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// JavaScriptCore does not give a Swift Dictionary Java's `.get()` method.
    /// Return the same Java Map-shaped wrapper used by response headers/cookies.
    func getThemeConfigMap() -> LegadoJavaMap {
        LegadoJavaMap(resolvedThemeConfigValues())
    }

    private func resolvedThemeConfigValues() -> [String: String] {
        let defaults = UserDefaults.standard
        let followsSystemKey = "yd_appearance_follows_system"
        let followsSystem = defaults.object(forKey: followsSystemKey) == nil
            ? true
            : defaults.bool(forKey: followsSystemKey)

        let isDark: Bool
        if !followsSystem {
            isDark = defaults.string(forKey: "yd_appearance_pinned_color_scheme") == "dark"
        } else if UITraitCollection.current.userInterfaceStyle != .unspecified {
            isDark = UITraitCollection.current.userInterfaceStyle == .dark
        } else {
            // This process preference is readable from the source JS queue. Avoid
            // a synchronous main-thread hop here: callers can already be blocking
            // the main thread while they wait for a rule evaluation to finish.
            isDark = defaults.string(forKey: "AppleInterfaceStyle") == "Dark"
        }

        let background = isDark ? "#000000" : "#FFFFFF"
        return [
            "bgColor": background,
            "backgroundColor": background,
            "readBgColor": background,
            "contentBgColor": background,
            "pageBgColor": background,
        ]
    }

    private static func chapterNumber(_ input: String) -> Int? {
        let halfWidth = String(input.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0xFF10...0xFF19:
                return Character(UnicodeScalar(scalar.value - 0xFEE0)!)
            case 0x3000:
                return " "
            default:
                return Character(scalar)
            }
        }).filter { !$0.isWhitespace }
        if let value = Int(halfWidth) { return value }

        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "壹": 1, "二": 2, "两": 2, "兩": 2,
            "贰": 2, "貳": 2, "三": 3, "叁": 3, "參": 3, "四": 4, "肆": 4,
            "五": 5, "伍": 5, "六": 6, "陆": 6, "陸": 6, "七": 7, "柒": 7,
            "八": 8, "捌": 8, "九": 9, "玖": 9,
        ]
        let units: [Character: Int] = [
            "十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1_000, "仟": 1_000,
            "万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000,
        ]
        guard !halfWidth.isEmpty,
              halfWidth.allSatisfy({ digits[$0] != nil || units[$0] != nil }) else { return nil }
        if halfWidth.count > 1, halfWidth.allSatisfy({ digits[$0] != nil }) {
            return halfWidth.reduce(0) { $0 * 10 + (digits[$1] ?? 0) }
        }
        var total = 0
        var section = 0
        var currentDigit = 0
        for character in halfWidth {
            if let digit = digits[character] {
                currentDigit = digit
                continue
            }
            guard let unit = units[character] else { return nil }
            if unit < 10_000 {
                section += max(1, currentDigit) * unit
            } else {
                section += currentDigit
                total += max(1, section) * unit
                section = 0
            }
            currentDigit = 0
        }
        return total + section + currentDigit
    }

    struct InflateFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The whole of `data` through zlib's inflate. Input that stops before the stream's end
    /// gives what it held and `finished == false`, as Java's Inflater does (its streams then
    /// throw EOFException).
    static func inflate(_ data: Data, windowBits: Int32) throws -> (output: Data, finished: Bool, consumed: Int) {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw InflateFailure(description: "inflateInit2 failed")
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 32_768
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK
        try data.withUnsafeBytes { rawBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: rawBuffer.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(data.count)
            while status != Z_STREAM_END {
                let produced = chunk.withUnsafeMutableBytes { chunkBuffer -> Int in
                    stream.next_out = chunkBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk.prefix(produced)) }
                if status == Z_BUF_ERROR, stream.avail_in == 0 { break }
                guard status == Z_OK || status == Z_STREAM_END else {
                    let reason = stream.msg.map { String(cString: $0) } ?? "zlib status \(status)"
                    throw InflateFailure(description: reason)
                }
            }
        }
        return (output, status == Z_STREAM_END, Int(stream.total_in))
    }

    /// hutool `ZipUtil.gzip` and `GZIPOutputStream`: Java deflates with zlib at its default
    /// level and memory level 8, so the same settings give a source the same bytes it would
    /// sign or send on Android.
    private static func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16_384
        data.withUnsafeBytes { rawBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: rawBuffer.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(data.count)
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced = chunk.withUnsafeMutableBytes { chunkBuffer -> Int in
                    stream.next_out = chunkBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    _ = deflate(&stream, Z_FINISH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk.prefix(produced)) }
            } while stream.avail_out == 0
        }
        return output
    }

    // MARK: - HTML Formatting

    /// Decode common HTML entities to plain text.
    /// Mirrors Legado's `java.htmlFormat(str)`.
    func htmlFormat(_ str: String) -> String {
        var result = str
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", "\u{00A0}"), ("&ensp;", "\u{2002}"),
            ("&emsp;", "\u{2003}"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode numeric entities like &#1234; and &#x4e2d;
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);|&#([0-9]+);") {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                if match.range(at: 1).location != NSNotFound {
                    let hexStr = ns.substring(with: match.range(at: 1))
                    if let scalar = UInt32(hexStr, radix: 16), let u = Unicode.Scalar(scalar) {
                        result.replaceSubrange(Range(match.range, in: result)!, with: String(u))
                    }
                } else if match.range(at: 2).location != NSNotFound {
                    let decStr = ns.substring(with: match.range(at: 2))
                    if let scalar = UInt32(decStr), let u = Unicode.Scalar(scalar) {
                        result.replaceSubrange(Range(match.range, in: result)!, with: String(u))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Chinese Character Conversion

    /// Traditional Chinese → Simplified Chinese. Mirrors Legado's `java.t2s(text)`.
    func t2s(_ text: String) -> String {
        text.applyingTransform(.init("Traditional-Simplified"), reverse: false) ?? text
    }

    /// Simplified Chinese → Traditional Chinese. Mirrors Legado's `java.s2t(text)`.
    func s2t(_ text: String) -> String {
        text.applyingTransform(.init("Traditional-Simplified"), reverse: true) ?? text
    }

    // MARK: - Action Stubs (Legado UI actions)

    func refreshExplore() {
        #if DEBUG
        print("[JSBridge] refreshExplore() called")
        #endif
        refreshExploreHandler?()
    }

    func reLoginView() {
        #if DEBUG
        print("[JSBridge] reLoginView() called")
        #endif
        reLoginViewHandler?()
    }

    func refreshBookInfo() {
        #if DEBUG
        print("[JSBridge] refreshBookInfo() called")
        #endif
        refreshBookInfoHandler?()
    }

    func refreshBookToc() {
        #if DEBUG
        print("[JSBridge] refreshBookToc() called")
        #endif
        refreshBookTocHandler?()
    }

    func refreshContent() {
        #if DEBUG
        print("[JSBridge] refreshContent() called")
        #endif
    }

    /// Opens a URL in browser without returning body. Only a runtime that presents its own
    /// pages (段評 capture) shows it; it does not fall back to `sharedBrowserPresenter`.
    func showBrowser(_ url: String, _ title: String) {
        browserPresentHandler?(browserRequest(url: url, title: title, awaitsResult: false)) { _ in }
    }

    func showReadingBrowser(_ url: String, _ title: String) {
        showBrowser(url, title)
    }

    func startBrowserDp(_ url: String, _ title: String) {
        startBrowser(url, title)
    }

    /// Legado `java.copyText`: UIKit owns the system pasteboard, so marshal the
    /// write to the main actor even when source JS is running on its serial queue.
    func copyText(_ text: String) {
        Task { @MainActor in
            UIPasteboard.general.string = text
        }
    }

    /// Returns a device identifier. Used by sources like 光遇 for `checkEnv()`. The vendor id,
    /// captured on main at launch (`DeviceIdentity`) — this runs on the JS queue.
    func deviceID() -> String {
        DeviceIdentity.vendorID
    }

    /// Legado `java.androidId()` — Android's `Settings.Secure.ANDROID_ID`, which is
    /// **16 lowercase hex characters** (`9774d56d682e549c`).
    ///
    /// This used to return `deviceID()`, i.e. `identifierForVendor` — a 36-character
    /// UPPERCASE UUID with dashes. Sources send it to their own backends as a device
    /// key and validate the shape; 知秋番茄's author states uppercase ids are rejected,
    /// and it is what its `x-android-id` header and `/user/temp` registration carry.
    ///
    /// Derived from the vendor id so it stays constant for this install (and changes
    /// only when `identifierForVendor` itself does, which is the same lifetime an
    /// ANDROID_ID has). `deviceID()` is left alone — 光遇's `checkEnv()` wants the
    /// real vendor UUID.
    func androidId() -> String {
        // Answered by default, as upstream does — see `presentsAndroidIdentity`
        // for why the opt-out exists and why it defaults ON. Empty (rather than a
        // thrown error) when a source is opted OUT, because a platform probe reads
        // `if (id && id !== '')` and falls through cleanly, while 知秋's
        // `requestApiUrl` calls this bare and a throw would take the whole request
        // down with it.
        guard presentsAndroidIdentityProvider?() == true else { return "" }
        let digest = SHA256.hash(data: Data(deviceID().utf8))
        return Self.hexString(digest.prefix(8))
    }

    /// True for the 36-character uppercase vendor UUID `androidId()` used to hand out.
    /// Sources cache whatever it returned (知秋番茄 does `source.put('androidId', …)`),
    /// so the bad value outlives the fix unless it is cleared — see
    /// `BookSourceRuntimeStateStore.purgeLegacyAndroidIds`. Delete both once no
    /// install can still be carrying a value written before this change.
    static func isLegacyVendorUUIDAndroidId(_ value: String) -> Bool {
        value.count == 36
            && value == value.uppercased()
            && UUID(uuidString: value) != nil
    }

    /// legado-E `java.openVideoPlayer(url, title[, isFloat])`: the native full-screen player.
    /// legado-E's floating-window variant (`isFloat`) has no counterpart here; a third argument
    /// is ignored and the video opens full screen. While a video episode is being fetched the
    /// link is that episode's instead (`videoEpisodeHandover`).
    /// legado-E `java.openUrl(url[, mimeType])`: an app link or a web page, opened after the
    /// reader agrees (`OpenUrlConfirmActivity`). An import link (`legado://` / `yuedu://`)
    /// goes to the app's own import, which asks first itself. The script does not wait.
    func openUrl(_ url: String, _ mimeType: JSValue) {
        guard url.utf16.count < 64 * 1024 else {
            _ = throwIntoScript("openUrl parameter url too long")
            return
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = URL(string: trimmed), target.scheme?.isEmpty == false else {
            AppLogger.parse("⟐ openUrl: not a URL", context: ["url": String(trimmed.prefix(160))])
            return
        }
        guard let presenter = Self.sharedOpenURLPresenter else {
            AppLogger.parse("⟐ openUrl: no presenter installed", context: [:])
            return
        }
        presenter(SourceOpenURLRequest(
            url: target,
            mimeType: Self.optionalString(mimeType),
            sourceName: sourceIdentityProvider?().name ?? ""
        ))
    }

    func getTag() -> String? {
        sourceIdentityProvider?().name
    }

    @objc(getTag) func jsGetTag() -> JSValue { LegadoJavaNull.value(getTag()) }

    func openVideoPlayer(_ url: String, _ title: String) {
        if videoEpisodeHandover != nil {
            if videoEpisodeHandover?.stream == nil { videoEpisodeHandover?.stream = url }
            return
        }
        guard let request = sourceBrowserRequest(urlString: url) else {
            AppLogger.parse("⟐ openVideoPlayer: not an http(s) video URL", context: ["url": String(url.prefix(160))])
            return
        }
        guard let presenter = Self.sharedVideoPresenter else {
            AppLogger.parse("⟐ openVideoPlayer: no video presenter installed", context: [:])
            return
        }
        presenter(request, title)
    }

    /// Legado `java.upLoginData(map)` — merge the given map into the source's stored login data
    /// (read back by source menus via `source.getLoginInfoMap()` / `getConfigValue`). Used by
    /// custom setting menus (起点/光遇 段评颜色·气泡模版) to persist their values.
    func upLoginData(_ data: JSValue) {
        #if DEBUG
        print("[JSBridge] upLoginData() called")
        #endif
        upLoginDataHandler?(data)
    }

    /// `java.getAppVariant()`, which an aggregate source probes for legado-E's video support:
    /// 光遇聚合 then declares 短剧 a video (`book.type = 4`) and returns its stream as the
    /// content, instead of a note and a browser page (maintainer, 2026-11-01). Only the
    /// function's presence is read; the value names a release build, as legado's `AppVariant`.
    func getAppVariant() -> String {
        "OFFICIAL"
    }

    /// Legado `java.qread()` — no-op stub (kept on purpose; see note in LegadoJSBridgeExports).
    /// Lets 起点 content JS set `dev='android-轻阅读'` → createSvg uses the 轻阅读 段评 bubble variant.
    func qread() {
        #if DEBUG
        print("[JSBridge] qread() called")
        #endif
    }

    // MARK: Headless WebView (Legado java.webView)

    /// Legado `java.webView(html, url, js)` — load `url` (or raw `html`) in an offscreen
    /// WebView, run `js` after the page finishes loading, and return the string result.
    /// Cookies acquired during the load are copied into `HTTPCookieStorage` so later
    /// `java.ajax`/`cookie.getCookie` calls see them. Blocks the JS serial queue (not main).
    func webView(_ html: JSValue, _ url: JSValue, _ js: JSValue) -> String {
        // No script is Legado's `javaScript == null`: the runner reads the page's outerHTML
        // after giving it Legado's 900 ms to render.
        runHeadlessWebView(html: html, url: url, js: js, sourceRegex: nil, overrideURLRegex: nil)
    }

    /// Legado `BackstageWebView`'s `timeout ?: 60000L`, which no `java.webView*` call sets. A
    /// variable only so a test can give a page that never answers a short deadline.
    var webViewTimeoutSeconds: TimeInterval = WebFetcher.sourceRequestTimeout

    func webViewGetSource(
        _ html: JSValue,
        _ url: JSValue,
        _ js: JSValue,
        _ sourceRegex: String
    ) -> String {
        runHeadlessWebView(
            html: html,
            url: url,
            js: js,
            sourceRegex: sourceRegex,
            overrideURLRegex: nil
        )
    }

    func webViewGetOverrideUrl(
        _ html: JSValue,
        _ url: JSValue,
        _ js: JSValue,
        _ overrideUrlRegex: String
    ) -> String {
        runHeadlessWebView(
            html: html,
            url: url,
            js: js,
            sourceRegex: nil,
            overrideURLRegex: overrideUrlRegex
        )
    }

    private func runHeadlessWebView(
        html: JSValue,
        url: JSValue,
        js: JSValue,
        sourceRegex: String?,
        overrideURLRegex: String?
    ) -> String {
        let htmlArg = Self.optionalString(html)
        let urlArg = Self.optionalString(url)
        let jsArg = Self.optionalString(js)
        // Legado `BackstageWebView`: the source map's User-Agent, else `AppConfig.userAgent`.
        let ua = getUserAgent()
        let timeout = webViewTimeoutSeconds
        let sem = DispatchSemaphore(value: 0)
        // Nil until the runner answers: written on the main actor, read here on the JS thread,
        // possibly after this thread stopped waiting.
        let answer = OSAllocatedUnfairLock<(body: String, failure: LegadoHeadlessWebView.Failure?)?>(
            initialState: nil
        )
        Task { @MainActor in
            let page = await LegadoHeadlessWebView.run(
                html: htmlArg,
                url: urlArg,
                js: jsArg,
                userAgent: ua,
                timeout: timeout,
                sourceRegex: sourceRegex,
                overrideURLRegex: overrideURLRegex
            )
            answer.withLock { $0 = page }
            sem.signal()
        }
        _ = networkWaits.during { sem.wait(timeout: .now() + timeout + 5) }
        // The runner keeps its own deadline; not answering by this wait's is that deadline
        // passing too, with the main actor too busy to say so.
        let page = answer.withLock { $0 } ?? (
            "", .timedOut(milliseconds: Int((timeout * 1000).rounded()))
        )
        if let failure = page.failure, failure.isLegadoError {
            // Legado's `runBlocking` rethrows it: the script sees an exception, not a page.
            return throwIntoScript(failure.message)
        }
        return page.body
    }

    /// Extract a non-empty String from a JS argument, treating undefined/null/"null" as nil.
    private static func optionalString(_ value: JSValue) -> String? {
        guard !value.isUndefined, !value.isNull else { return nil }
        guard let s = value.toString(), s != "null", s != "undefined", !s.isEmpty else { return nil }
        return s
    }

    /// Convert a JS headers object into a `[String: String]` dictionary.
    private static func headerDict(from value: JSValue) -> [String: String] {
        if value.isString,
           let raw = value.toString()?.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            return dict.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        }
        guard !value.isUndefined, !value.isNull, value.isObject,
              let dict = value.toDictionary() as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, val) in dict {
            if let str = val as? String { result[key] = str }
            else if let num = val as? NSNumber { result[key] = num.stringValue }
            else { result[key] = "\(val)" }
        }
        return result
    }

    private static func timeoutSeconds(from value: JSValue) -> TimeInterval? {
        guard !value.isUndefined, !value.isNull else { return nil }
        let milliseconds = value.isNumber
            ? value.toDouble()
            : Double(value.toString() ?? "")
        guard let milliseconds, milliseconds > 0 else { return nil }
        return min(120, max(1, milliseconds / 1000))
    }

    // MARK: - UTC Time Formatting

    /// Format a Unix millisecond timestamp in UTC with a timezone offset.
    /// Mirrors Legado's `java.timeFormatUTC(time, format, sh)`.
    /// - Parameters:
    ///   - time: Unix timestamp in milliseconds.
    ///   - format: Java-style date format string (e.g. `"yyyy-MM-dd HH:mm:ss"`).
    ///   - sh: Hour offset from UTC (e.g. `8` for UTC+8).
    func timeFormatUTC(_ time: Double, _ format: String, _ sh: Int) -> String {
        let date = Date(timeIntervalSince1970: time / 1000)
        let fmt = DateFormatter()
        // Convert Java format → DateFormatter format
        let fmtStr = format
            .replacingOccurrences(of: "yyyy", with: "yyyy")
            .replacingOccurrences(of: "MM",   with: "MM")
            .replacingOccurrences(of: "dd",   with: "dd")
            .replacingOccurrences(of: "HH",   with: "HH")
            .replacingOccurrences(of: "mm",   with: "mm")
            .replacingOccurrences(of: "ss",   with: "ss")
        fmt.dateFormat = fmtStr
        fmt.timeZone = TimeZone(secondsFromGMT: sh * 3600) ?? .current
        return fmt.string(from: date)
    }

    /// Typed GET path for Rhino's `java.get(url, headers)` overload.
    ///
    /// Do not encode the headers as AnalyzeUrl options here: that path returns only
    /// a transformed body string, which discards the metadata required by Legado's
    /// `StrResponse` contract.
    private func performGet(
        _ urlStr: String,
        headers: [String: String],
        timeoutOverride: TimeInterval? = nil,
        followRedirects: Bool
    ) -> LegadoHTTPResult {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackURL = URL(string: "about:blank")!
        guard let url = URL(string: trimmed) else {
            AppLogger.parse("⟐ js net bad URL", context: ["url": String(trimmed.prefix(200))])
            return .bodyOnly(request: URLRequest(url: fallbackURL), body: "")
        }

        let timeoutSeconds = timeoutOverride ?? requestTimeoutSeconds
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "GET"
        // Legado's OkHttp interceptor: a request with no User-Agent of its own (no source, or
        // the source's header rule fetching itself) sends `AppConfig.userAgent`.
        request.setValue(BookSource.legadoDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if !followRedirects { request = LegadoRedirectPolicy.refusingRedirects(request) }

        if let handler = networkHandler {
            return networkWaits.during { handler(request, nil) } ?? .bodyOnly(request: request, body: "")
        }

        let pending = BlockingResult<LegadoHTTPResult>()
        let task = Self.requestSession.legadoDataTask(with: request) { [request] data, response, error in
            pending.deliver(LegadoHTTPResult.make(request: request, data: data, response: response, error: error))
        }
        task.resume()
        let responseResult = networkWaits.during { pending.wait(timeout: .now() + timeoutSeconds) }
        if responseResult == nil {
            task.cancel()
        }
        return responseResult ?? .bodyOnly(request: request, body: "")
    }

    private func performSimpleRequest(
        method: String,
        urlStr: String,
        body: Data?,
        headers: [String: String],
        timeoutOverride: TimeInterval?,
        followRedirects: Bool
    ) -> LegadoHTTPResult {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackURL = URL(string: "about:blank")!
        guard let url = URL(string: trimmed) else {
            AppLogger.parse("⟐ js net bad URL", context: ["url": String(trimmed.prefix(200))])
            return .bodyOnly(request: URLRequest(url: fallbackURL), body: "")
        }
        let timeoutSeconds = timeoutOverride ?? requestTimeoutSeconds
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = method
        request.httpBody = body
        // Legado's OkHttp interceptor: a request with no User-Agent of its own (no source, or
        // the source's header rule fetching itself) sends `AppConfig.userAgent`.
        request.setValue(BookSource.legadoDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if !followRedirects { request = LegadoRedirectPolicy.refusingRedirects(request) }

        if let handler = networkHandler {
            return networkWaits.during { handler(request, nil) } ?? .bodyOnly(request: request, body: "")
        }

        let pending = BlockingResult<LegadoHTTPResult>()
        let task = Self.requestSession.legadoDataTask(with: request) { [request] data, response, error in
            pending.deliver(LegadoHTTPResult.make(request: request, data: data, response: response, error: error))
        }
        task.resume()
        let responseResult = networkWaits.during { pending.wait(timeout: .now() + timeoutSeconds) }
        if responseResult == nil {
            task.cancel()
        }
        return responseResult ?? .bodyOnly(request: request, body: "")
    }

    /// Synchronous HTTP POST used by `java.post`. Blocks the calling (JS serial queue) thread.
    /// jsoup 1.16.2's `HttpConnection.DEFAULT_UA` — the jsoup legado-E and MD3 pin
    /// (`gradle/libs.versions.toml`): the User-Agent of a `java.get`/`head`/`post` whose script
    /// gives none.
    static let jsoupDefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36"

    /// Legado-E's and MD3's `java.get(url, headers)`, `java.head` and `java.post`
    /// (`JsExtensions`): `Jsoup.connect(url).headers(headers).followRedirects(false)`. A jsoup
    /// request, not an AnalyzeUrl, so none of OkHttp's interceptors touch it:
    /// - the script's headers over jsoup's defaults — its desktop User-Agent and, for a body,
    ///   `Content-Type: application/x-www-form-urlencoded; charset=UTF-8` — and none of the
    ///   source's header rule, which only an AnalyzeUrl request (`java.ajax`, `java.connect`)
    ///   carries;
    /// - `CookieJar: 1` when the source keeps a cookie jar: the marker Legado's interceptor reads
    ///   and strips from an OkHttp request, which here reaches the server as written;
    /// - no stored cookie goes out and the response's are not kept: jsoup keeps a connection's
    ///   cookies in a jar of its own, and Legado sets no `CookieHandler`. A script reads them
    ///   off the response (`cookies()`, `header("Set-Cookie")`).
    ///
    /// 八零电子书 (YCK1330 #744) posts its search form with `java.post(url, body, {})` and reads
    /// the redirect's `Location`. Sent with its source's header rule and the shared jar, it was
    /// answered a cookie challenge.
    private func performJsoupRequest(
        method: String,
        _ urlStr: String,
        body: String?,
        headers: [String: String],
        timeoutOverride: TimeInterval?
    ) -> LegadoHTTPResult {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            AppLogger.parse("⟐ js net bad URL", context: ["url": String(trimmed.prefix(200))])
            return .bodyOnly(request: URLRequest(url: URL(string: "about:blank")!), body: "")
        }
        let timeoutSeconds = timeoutOverride ?? requestTimeoutSeconds
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(Self.jsoupDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if keepsCookieJarProvider?() == true {
            request.setValue("1", forHTTPHeaderField: "CookieJar")
        }
        if let body {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }
        }
        request = LegadoRedirectPolicy.refusingRedirects(request)
        request = LegadoOutgoingHeaders.markingJsoup(request)

        if let handler = networkHandler {
            return networkWaits.during { handler(request, nil) } ?? .bodyOnly(request: request, body: "")
        }

        let pending = BlockingResult<LegadoHTTPResult>()
        let task = Self.requestSession.legadoDataTask(with: request) { [request] data, response, error in
            pending.deliver(LegadoHTTPResult.make(request: request, data: data, response: response, error: error))
        }
        task.resume()
        let responseResult = networkWaits.during { pending.wait(timeout: .now() + timeoutSeconds) }
        if responseResult == nil {
            task.cancel()
        }
        return responseResult ?? .bodyOnly(request: request, body: "")
    }

    private func performRequest(_ urlStr: String) -> String {
        performRequestResult(urlStr).body
    }

    /// What one `java.*` request reads from the bridge. The handlers are the ones the bridge was
    /// configured with; `ajaxAll` captures this so its workers never touch the bridge itself.
    private struct RequestContext {
        let analyzeUrlHandler: ((String) -> PreparedSourceRequest?)?
        let networkHandler: SourceScriptTransport?
        /// Resolved when the context is built, on the JS thread. Resolving them can evaluate the
        /// header rule on the engine's JS queue, which `ajaxAll` occupies while its workers run.
        /// `[:]` when no request in it takes the plain route: the AnalyzeUrl handler evaluates
        /// the rule itself, once per request, and an evaluation here as well ran it twice.
        let sourceHeaders: [String: String]
        let timeoutSeconds: TimeInterval
        let networkWaits: LegadoScriptWaits
    }

    /// Built on the JS thread only: every `java.*` request runs there, and `ajaxAll` builds it
    /// before it fans out. The source headers are resolved when one of `urls` takes the plain
    /// route — the one that sends them from here.
    private func requestContext(for urls: [String]) -> RequestContext {
        let sendsSourceHeaders = urls.contains {
            !Self.takesAnalyzeUrlRoute($0, handler: analyzeUrlHandler)
        }
        return RequestContext(
            analyzeUrlHandler: analyzeUrlHandler,
            networkHandler: networkHandler,
            sourceHeaders: sendsSourceHeaders ? sourceHeaders : [:],
            timeoutSeconds: requestTimeoutSeconds,
            networkWaits: networkWaits
        )
    }

    private func performRequestResult(_ urlStr: String) -> LegadoHTTPResult {
        Self.performRequest(urlStr, in: requestContext(for: [urlStr]))
    }

    /// A request bound for the AnalyzeUrl handler, built on the JS thread.
    private struct AnalyzeUrlRoute {
        /// `nil` when the handler built no request; the body is then empty.
        let request: PreparedSourceRequest?
        /// What the result reports as its request: the URL without its options.
        let placeholder: URLRequest

        /// JS thread only: `finish` runs the response's `bodyJs`.
        ///
        /// Legado's `connect(url,{…})` answers `AnalyzeUrl.getStrResponseAwait()`: the okhttp
        /// response, so `raw().request().url()` is where a redirect landed and `code()` /
        /// `headers()` are the server's. Rebuilt from the URL asked for, 言情小说 (YCK1330 #652)
        /// read `index.php` back instead of its `result/?searchid=…` and searched an error page.
        func result(for response: PreparedSourceRequest.Response?) -> LegadoHTTPResult {
            let body = response.flatMap { request?.finish($0) } ?? ""
            var result: LegadoHTTPResult
            if let http = response?.http {
                result = LegadoHTTPResult(
                    finalURL: http.finalURL, statusCode: http.statusCode,
                    statusMessage: http.statusMessage, headers: http.headers,
                    cookies: http.cookies, body: body, requestedURL: http.requestedURL
                )
            } else {
                result = LegadoHTTPResult.bodyOnly(request: placeholder, body: body)
            }
            result.data = response?.data
            result.transportError = response?.transportError
            return result
        }
    }

    /// What an `ajaxAll` worker runs: either half is free of JS.
    private enum AjaxAllJob {
        case plain(RequestContext)
        case analyzeUrl(PreparedSourceRequest?)
    }

    /// What an `ajaxAll` worker brings back.
    private enum AjaxAllOutcome: Sendable {
        case plain(LegadoHTTPResult)
        /// Not yet finished: `bodyJs` runs on the JS thread after the batch.
        case fetched(PreparedSourceRequest.Response?)

        var body: String {
            switch self {
            case .plain(let result): result.body
            case .fetched(let response): response?.body ?? ""
            }
        }
    }

    /// Whether `urlStr` is built by the AnalyzeUrl handler: a `data:` URI, or a URL with options.
    private static func takesAnalyzeUrlRoute(
        _ urlStr: String, handler: ((String) -> PreparedSourceRequest?)?
    ) -> Bool {
        guard handler != nil else { return false }
        let trimmedUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUrl.hasPrefix("data:")
            || trimmedUrl.contains(",{")
            || trimmedUrl.contains("{\"method\"")
    }

    /// JS thread only — building the request runs the URL's JS. `nil` for a plain URL.
    private static func analyzeUrlRoute(_ urlStr: String, in context: RequestContext) -> AnalyzeUrlRoute? {
        guard let prepare = context.analyzeUrlHandler,
              takesAnalyzeUrlRoute(urlStr, handler: prepare)
        else { return nil }
        let trimmedUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: trimmedUrl.components(separatedBy: ",{").first ?? trimmedUrl)
            ?? URL(string: "about:blank")!
        return AnalyzeUrlRoute(request: prepare(urlStr), placeholder: URLRequest(url: baseURL))
    }

    /// JS thread only.
    private static func performRequest(_ urlStr: String, in context: RequestContext) -> LegadoHTTPResult {
        if let route = analyzeUrlRoute(urlStr, in: context) {
            return route.result(for: context.networkWaits.during { route.request?.fetch() })
        }
        return performPlainRequest(urlStr, in: context)
    }

    /// A URL without AnalyzeUrl options runs no JS, so this is safe on any thread.
    private static func performPlainRequest(_ urlStr: String, in context: RequestContext) -> LegadoHTTPResult {
        let trimmedUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: trimmedUrl.components(separatedBy: ",{").first ?? trimmedUrl)
            ?? URL(string: "about:blank")!

        // Delegate to external handler if provided
        if let handler = context.networkHandler {
            guard let url = AnalyzeUrl.requestURL(trimmedUrl) else {
                // Silently returning "" here made the rule's `JSON.parse("")` throw
                // three retries later with no trace of the real cause. Rule JS builds
                // URLs by string concatenation, so unencoded CJK / spaces / stray
                // template leftovers land here.
                AppLogger.parse("⟐ js net bad URL", context: ["url": String(trimmedUrl.prefix(200))])
                return .bodyOnly(request: URLRequest(url: baseURL), body: "")
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: context.timeoutSeconds)
            context.sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            return context.networkWaits.during { handler(request, nil) } ?? .bodyOnly(request: request, body: "")
        }

        // Fallback: synchronous URLSession request with charset-aware decoding
        guard let url = AnalyzeUrl.requestURL(trimmedUrl) else {
            AppLogger.parse("⟐ js net bad URL", context: ["url": String(trimmedUrl.prefix(200))])
            return .bodyOnly(request: URLRequest(url: baseURL), body: "")
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: context.timeoutSeconds)
        // Legado's OkHttp interceptor: a request with no User-Agent of its own (no source, or
        // the source's header rule fetching itself) sends `AppConfig.userAgent`.
        request.setValue(BookSource.legadoDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        // No `Accept` of our own, as `WebFetcher.buildRequest`: OkHttp sends none, and a
        // browser's `text/html` turns a Django REST framework API's JSON into its HTML page.
        // The rest of okhttp's headers are added on the way out (`legadoDataTask`).
        // Apply book source headers (may override User-Agent)
        context.sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let pending = BlockingResult<LegadoHTTPResult?>()

        // The response goes back to the source as it came — a Cloudflare challenge page
        // included, as in Legado. A source whose site is protected checks the body itself
        // and calls `java.startBrowserAwait`; blanking the page here hid it from that check.
        let task = requestSession.legadoDataTask(with: request) { [request] data, response, error in
            pending.deliver(LegadoHTTPResult.make(request: request, data: data, response: response, error: error))
        }
        task.resume()
        let responseResult = context.networkWaits.during {
            pending.wait(timeout: .now() + context.timeoutSeconds)
        } ?? nil
        return responseResult ?? .bodyOnly(request: request, body: "")
    }

    /// Charset-aware string decoding for `java.ajax` / `java.post` responses.
    ///
    /// Delegates to `HTMLResponseDecoder` so a source's JS sees exactly what the rule engine sees.
    /// This used to be a second, weaker implementation: it trusted `textEncodingName` outright and
    /// ended in an `?? String(data:encoding:.isoLatin1)` catch-all — two different ways to turn a
    /// mislabeled UTF-8 body into mojibake, on the path many sources use to fetch chapter text.
    /// `declaredCharset` is the AnalyzeUrl `charset` option; it decides when present, as in Legado.
    static func decodeData(_ data: Data, response: URLResponse?, declaredCharset: String? = nil) -> String {
        HTMLResponseDecoder.decode(data: data, response: response, declaredCharset: declaredCharset) ?? ""
    }

    /// Returns true when the body alone (regardless of HTTP status) looks like a CF page.
    /// Nothing opens a challenge because of it — Legado never does — it only keeps such a
    /// page from being cached as a script or taken for a rendered page.
    static func isCloudflareChallengedBody(_ body: String) -> Bool {
        // Use only unambiguous, CF-specific fingerprints to minimise false positives.
        let specificMarkers = [
            "cf-browser-verification",
            "cf_chl_prog",
            "_cf_chl_",
            "cf-challenge-running",
        ]
        let lower = body.lowercased()
        return specificMarkers.contains(where: { lower.contains($0) })
    }
}

// MARK: - Java collection and connection response contracts

@objc protocol LegadoJavaMapExport: JSExport {
    /// `java.util.Map.get` / `put`: `null` for a missing key or no previous value
    /// (`LegadoJavaNull`). Swift callers use the `String?` twins.
    @objc(get:) func jsGet(_ key: String) -> JSValue
    @objc(put::) func jsPut(_ key: String, _ value: String) -> JSValue
    func containsKey(_ key: String) -> Bool
    func keySet() -> [String]
    func size() -> Int
    func isEmpty() -> Bool
    func stableString() -> String
    func toString() -> String
}

/// Small Java Map-shaped object used at the JS boundary. Header lookup is
/// case-insensitive; cookie lookup remains case-sensitive like `java.net.HttpCookie`.
@objc class LegadoJavaMap: NSObject, LegadoJavaMapExport {
    private var values: [String: String]
    private let caseInsensitive: Bool

    init(_ values: [String: String], caseInsensitive: Bool = false) {
        self.values = values
        self.caseInsensitive = caseInsensitive
        super.init()
    }

    func get(_ key: String) -> String? {
        if let exact = values[key] { return exact }
        guard caseInsensitive else { return nil }
        return values.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    func put(_ key: String, _ value: String) -> String? {
        let previous = get(key)
        if caseInsensitive,
           let existing = values.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            values[existing] = value
        } else {
            values[key] = value
        }
        return previous
    }

    @objc(get:) func jsGet(_ key: String) -> JSValue { LegadoJavaNull.value(get(key)) }
    @objc(put::) func jsPut(_ key: String, _ value: String) -> JSValue {
        LegadoJavaNull.value(put(key, value))
    }

    func containsKey(_ key: String) -> Bool { get(key) != nil }
    func keySet() -> [String] { values.keys.sorted() }
    func size() -> Int { values.count }
    func isEmpty() -> Bool { values.isEmpty }
    func stableString() -> String {
        "{" + keySet().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: ", ") + "}"
    }
    func toString() -> String { stableString() }
    override var description: String { stableString() }
}

/// JS-callable response object returned by `java.startBrowserAwait()`.
/// Mirrors Legado's `StrResponse(url, body)`.
///
/// `url` is a method, as in every Legado fork's `StrResponse` (`fun url()`): in Rhino the
/// method shadows the Kotlin `val url` bean property, so `result.url()` is the call sources
/// make (搜笔趣阁, 手打书, 哔哩小说 and 飞库文学网 in `loginCheckJs`).
@objc protocol LegadoStrResponseExport: JSExport {
    /// okhttp's `Response` in Legado (`StrResponse.raw()`); this object answers the same calls
    /// (`code()`, `message()`, `headers()`, `header(name)`, `request().url()`).
    func raw() -> LegadoStrResponse
    /// Milliseconds the request took (`StrResponse.callTime()`); 0 for a constructed response.
    func callTime() -> Int
    func request() -> LegadoHTTPRequestInfo
    /// One header, case-insensitive; `null` when absent (okhttp `header` / jsoup `header`).
    func header(_ name: String) -> JSValue
    func hasHeader(_ name: String) -> Bool
    func cookie(_ name: String) -> JSValue
    func contentType() -> JSValue
    func isRedirect() -> Bool
    /// okhttp's `priorResponse()`: the redirect that led here, with no body, and through its own
    /// `priorResponse()` the one before it; `null` when no redirect led here.
    func priorResponse() -> JSValue
    func body() -> String
    /// The response's bytes as they arrived (okhttp `ResponseBody.bytes()`); the body text's
    /// UTF-8 for a response built from text.
    func bodyBytes() -> [Int]
    func cookies() -> LegadoJavaMap
    /// okhttp's and jsoup's `headers()` — every header, case-insensitive — and, given a name,
    /// their `headers(name)`: that header's values, a list. 精品小说 (YCK1331) reads the
    /// redirect its search POST answers with `java.post(…).headers("location")[0]`; with the
    /// name ignored that was the whole map, `[0]` nothing, and the search went to `/e/search/`.
    @objc(headers:) func jsHeaders(_ name: JSValue) -> JSValue
    func code() -> Int
    func message() -> String
    func statusCode() -> Int
    func statusMessage() -> String
    func url() -> String
    func urlString() -> String
    func isSuccessful() -> Bool
    func toString() -> String
}

@objc class LegadoStrResponse: NSObject, LegadoStrResponseExport {
    /// The final URL, after redirects.
    let finalURLString: String
    private let result: LegadoHTTPResult

    init(url: String, body: String) {
        let parsedURL = URL(string: url) ?? URL(string: "about:blank")!
        self.result = LegadoHTTPResult(
            finalURL: parsedURL,
            statusCode: 200,
            statusMessage: "OK",
            headers: [:],
            cookies: [:],
            body: body
        )
        self.finalURLString = url
        super.init()
    }

    init(result: LegadoHTTPResult, callTime: Int = 0) {
        self.result = result
        self.finalURLString = result.urlString
        self.callTimeMillis = callTime
        super.init()
    }

    /// Set once by the call that made the request, before the object reaches JS.
    var callTimeMillis = 0

    func raw() -> LegadoStrResponse { self }
    func callTime() -> Int { callTimeMillis }
    /// okhttp's `Response.request()` is the request the response answers — after a redirect,
    /// the redirect's. 全本同人小说网 (YCK1330) reads its search id from the URL its POST lands
    /// on with `java.connect(…).raw().request().url()`; the URL asked for sent the search to a
    /// GET of the form's address, which answers an error page.
    func request() -> LegadoHTTPRequestInfo { LegadoHTTPRequestInfo(url: finalURLString) }
    func header(_ name: String) -> JSValue { LegadoJavaNull.value(headerValue(name)) }
    func hasHeader(_ name: String) -> Bool { headerValue(name) != nil }
    func cookie(_ name: String) -> JSValue { LegadoJavaNull.value(result.cookies[name]) }
    func contentType() -> JSValue { LegadoJavaNull.value(headerValue("Content-Type")) }

    private func headerValue(_ name: String) -> String? {
        result.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    func isRedirect() -> Bool { [300, 301, 302, 303, 307, 308].contains(result.statusCode) }
    /// 八叉书库 (YCK 1330 #23) learns its mirror has moved in its `loginCheckJs`:
    /// `result.raw().priorResponse()`, and when that `isRedirect()`, the URL it landed on. Every
    /// stage threw a TypeError there without it.
    func priorResponse() -> JSValue {
        let context = JSContext.current()
        guard var prior = result.redirects.last else { return JSValue(nullIn: context) }
        prior.redirects = Array(result.redirects.dropLast())
        return JSValue(object: LegadoStrResponse(result: prior), in: context)
    }
    func body() -> String { result.body }
    func bodyBytes() -> [Int] { (result.data ?? Data(result.body.utf8)).map(Int.init) }
    func cookies() -> LegadoJavaMap { LegadoJavaMap(result.cookies) }
    func headers() -> LegadoJavaMap { LegadoJavaMap(result.headers, caseInsensitive: true) }
    func jsHeaders(_ name: JSValue) -> JSValue {
        let context = JSContext.current()
        guard !name.isUndefined, !name.isNull else { return JSValue(object: headers(), in: context) }
        // A JS array stands for the Java `List<String>`, as `getHeaderFields` hands one out.
        return JSValue(object: headerValue(name.toString()).map { [$0] } ?? [], in: context)
    }
    func code() -> Int { result.statusCode }
    func message() -> String { result.statusMessage }
    func statusCode() -> Int { result.statusCode }
    func statusMessage() -> String { result.statusMessage }
    func url() -> String { finalURLString }
    func urlString() -> String { finalURLString }
    func isSuccessful() -> Bool { (200..<300).contains(result.statusCode) }
    func toString() -> String { "Response{code=\(result.statusCode), url=\(finalURLString)}" }
    override var description: String { toString() }
}

/// okhttp `Request` as `StrResponse.raw().request()` hands it out: sources read its URL.
@objc protocol LegadoHTTPRequestInfoExport: JSExport {
    func url() -> String
    func toString() -> String
}

@objc final class LegadoHTTPRequestInfo: NSObject, LegadoHTTPRequestInfoExport {
    private let urlString: String
    init(url: String) {
        self.urlString = url
        super.init()
    }
    func url() -> String { urlString }
    func toString() -> String { urlString }
    override var description: String { urlString }
}

// MARK: - Browser Await Completion

/// One-shot completion for `java.startBrowserAwait`. The JS thread blocks on it with no
/// deadline, so it must fire exactly once on every way the browser can go away. The two
/// toolbar buttons call `finish` explicitly; `deinit` covers the paths that have no
/// callback at all — a sheet swiped away, or a host controller released before the user
/// decided — by reporting cancellation, which the bridge turns into a JS exception.
///
/// Create and use it on the main thread (it is not internally synchronized).
final class BrowserAwaitBox {
    private var completion: ((String?) -> Void)?

    init(_ completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func finish(_ body: String?) {
        guard let completion else { return }
        self.completion = nil
        completion(body)
    }

    deinit { finish(nil) }
}
