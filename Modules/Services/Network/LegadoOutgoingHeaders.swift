import Foundation

/// The headers Legado's HTTP clients add to a source's request on its way out, after the
/// request's own. Sources are written against exactly these, so every request a source makes
/// leaves through `prepared(_:as:)`: native rule pages (`WebFetcher`, `client: .okHttp`), the
/// runtime's rule URLs (`ModernParserBridge.performRequest`), every `java.*` request
/// (`URLSession.legadoDataTask`), the 段評 prefetch, and the login URL and login form requests.
/// A WebView is a browser and keeps its own; covers, chapter images and media keep theirs.
///
/// - okhttp — rule URLs, AnalyzeUrl, `java.ajax`/`connect`: HttpHelper's interceptor adds
///   `AppConfig.userAgent` when the request names no User-Agent, then `Keep-Alive: 300`,
///   `Connection: Keep-Alive` and `Cache-Control: no-cache` (legado-E HttpHelper.kt:71–81);
///   `DecompressInterceptor` adds `Accept-Encoding: gzip, deflate` when the request has none.
/// - jsoup — `java.get`/`head`/`post`: the script's headers and nothing else.
///
/// Neither adds a Referer or an Accept-Language. Native pages sent `Referer: <source URL>`,
/// `Accept-Language: zh-TW,…` and `Accept-Encoding: gzip, deflate, br` until 11-09, and the
/// script bridge `Accept-Language: zh-CN,…`.
///
/// Where CFNetwork cannot follow (measured 11-09 against a local echo server):
/// - a request without an Accept-Language goes out with the device's, and an empty value goes
///   out as an empty header. Empty is what is sent: the nearest to none, and the same on every
///   device (maintainer's choice, 11-09).
/// - `Connection: keep-alive` is CFNetwork's own on HTTP/1.1. `Keep-Alive` is not added: it is
///   a hop-by-hop header, which HTTP/2 forbids.
/// - a source's own Cache-Control is kept as it is; okhttp's `addHeader` would send ours too.
enum LegadoOutgoingHeaders {
    enum Client: Sendable {
        case okHttp
        case jsoup
    }

    static func prepared(_ request: URLRequest, as client: Client) -> URLRequest {
        var request = request
        func setIfAbsent(_ value: String, _ field: String) {
            if request.value(forHTTPHeaderField: field) == nil {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        if client == .okHttp {
            setIfAbsent(BookSource.legadoDefaultUserAgent, "User-Agent")
            setIfAbsent("gzip, deflate", "Accept-Encoding")
            setIfAbsent("no-cache", "Cache-Control")
        }
        setIfAbsent("", "Accept-Language")
        return request
    }

    private static let jsoupKey = "YueduLegadoJsoupRequest"

    /// A `java.get`/`head`/`post` request: it may reach the runtime's transport, which sends it
    /// as `client(of:)` says, so the flag rides on the request as `LegadoRedirectPolicy`'s does.
    static func markingJsoup(_ request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.setProperty(true, forKey: jsoupKey, in: mutable)
        return mutable as URLRequest
    }

    static func client(of request: URLRequest) -> Client {
        (URLProtocol.property(forKey: jsoupKey, in: request) as? Bool) == true ? .jsoup : .okHttp
    }
}
