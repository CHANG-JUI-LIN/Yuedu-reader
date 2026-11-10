import Foundation

/// Legado's `retry` URL option (`url,{"retry":2}`), as `OkHttpUtils.newCallResponse` runs it
/// (legado-E, MD3 and upstream agree): the request goes out, and again — `retry` more times at
/// most — while its answer is not a 2xx; the last answer is the result, whatever its status.
/// A request that gets no answer at all (a timeout, a refused connection) throws out of that
/// loop: it is not retried.
///
/// Every attempt passes OkHttp's network interceptor, which for a source with a cookie jar loads
/// the jar into the request (`CookieManager.loadRequest`), so a cookie one answer set goes out
/// with the next attempt. 顶点小说 (YCK1330) opens its home page through a 403 that sets a
/// cookie and answers 200 once the cookie comes back; its search reads the form off that page.
///
/// Only a rule URL's options carry `retry`, so only the runtime's two HTTP exits run it: a
/// stage's request (`ModernParserBridge.fetch`) and a script's (`java.ajax`, `java.connect`,
/// `java.ajaxAll` through the AnalyzeUrl handler), the HTTP half of a WebView POST included.
/// Legado's WebView GET loads once, and so does this one.
enum LegadoRequestRetry {
    /// Whether attempt `attempt` (0 is the first) answered `statusCode` is sent again: its answer
    /// is not a 2xx (okhttp's `Response.isSuccessful`) and `retry` allows another. A response
    /// that is not HTTP has no status and is not retried.
    static func retries(after statusCode: Int, attempt: Int, retry: Int) -> Bool {
        attempt < retry && !(200...299).contains(statusCode)
    }

    /// The request attempt `attempt` sends. The first goes as it was built; a later one, for a
    /// source with a cookie jar, carries the jar's cookies for its URL over its own `Cookie`.
    /// Without a jar Legado sends every attempt as built, and so does this.
    static func request(_ request: URLRequest, attempt: Int, cookieJar: Bool) -> URLRequest {
        guard attempt > 0, cookieJar, let url = request.url?.absoluteString else { return request }
        var next = request
        next.setValue(
            CookieStore.shared.loadingJar(into: request.value(forHTTPHeaderField: "Cookie"), url: url),
            forHTTPHeaderField: "Cookie"
        )
        return next
    }

    /// One line for each attempt sent again, so a device log and a diagnostic dump show it.
    static func logRetry(after statusCode: Int, attempt: Int, retry: Int, url: URL?, source: String) {
        AppLogger.network("request answered an error status; its retry option sends it again", context: [
            "source": source,
            "url": String((url?.absoluteString ?? "-").prefix(160)),
            "statusCode": statusCode,
            "retry": "\(attempt + 1)/\(retry)",
        ])
        WebCrawlerDebugger.logInfo("retry \(attempt + 1)/\(retry) after HTTP \(statusCode)", url: url?.absoluteString)
    }
}
