import Foundation
import os

/// A source's request sent once more over TLS 1.3 when its server refuses TLS 1.2.
///
/// A source's sessions stop at TLS 1.2 (`ServerTrustPolicy.capAtTLS12`) because some servers never
/// answer iOS 26's TLS 1.3 ClientHello. Other servers accept TLS 1.3 only and refuse the capped
/// handshake at once. In the 2026-11-09 audit (r15), two sources that had passed over TLS 1.3 the
/// round before failed this way: zh.virtualtaboo.live (1330 VirtalTaboo直播, -9836
/// protocol_version) and www.yydsmh.com (1331 永远漫画, -9816). openssl `-tls1_2` gets a
/// protocol_version alert from both. www.kelexs.com (-9824 handshake_failure, because its TLS 1.2
/// offers only RC4) and special.rhky.com (-9860 inappropriate_fallback) refused it once as well.
/// Legado's OkHttp offers TLS 1.3, so those sites read there.
///
/// This is a fallback; the maintainer chose it on 2026-11-09.
/// - Trigger: `NSURLErrorSecureConnectionFailed` (-1200: the handshake failed) from a session
///   capped at TLS 1.2. A server that never answers the ClientHello fails with a timeout (-1001)
///   instead, so the hosts the cap is for never come here.
/// - Effect: the request is sent once more on the session's TLS 1.3 twin, and the failing host
///   stays on the twin for the rest of the launch.
/// - Removal: delete this together with `capAtTLS12` once Apple lets an app leave the
///   post-quantum key share out, or once those servers read a two-segment ClientHello.
///
/// Every source request reaches it: pages and `java.*` requests through `BoundedResponseLoader`,
/// everything else through `URLSession.sourceData(for:)` / `sourceDataTask(with:)`.
enum SourceTLSFallback {
    private struct State {
        var tls13Hosts = Set<String>()
        /// Keyed by the capped session, which the entry keeps alive so that its identifier is
        /// never reused for another session.
        var twins: [ObjectIdentifier: (capped: URLSession, twin: URLSession)] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// `session`, or its TLS 1.3 twin when `url`'s host refused TLS 1.2 earlier in this launch.
    static func session(_ session: URLSession, for url: URL?) -> URLSession {
        guard let host = url?.host?.lowercased(),
              state.withLock({ $0.tls13Hosts.contains(host) }),
              isCapped(session) else { return session }
        return twin(of: session)
    }

    /// The session to send `request` on once more after `error` on `session`: its TLS 1.3 twin
    /// when `error` is a refused handshake on a session capped at TLS 1.2, nil otherwise. A
    /// refusal puts the failing host (a redirect's target, when that is where it failed) on the
    /// twin for the rest of the launch.
    static func retrySession(after error: any Error, on session: URLSession, request: URLRequest) -> URLSession? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              nsError.code == NSURLErrorSecureConnectionFailed,
              isCapped(session) else { return nil }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? request.url
        guard let host = failingURL?.host?.lowercased() else { return nil }
        state.withLock { _ = $0.tls13Hosts.insert(host) }
        AppLogger.network("TLS: a source host refused TLS 1.2; sending again over TLS 1.3", context: [
            "host": host,
            "streamError": (nsError.userInfo["_kCFStreamErrorCodeKey"] as? Int) ?? 0,
        ], level: .warning)
        return twin(of: session)
    }

    private static func isCapped(_ session: URLSession) -> Bool {
        session.configuration.tlsMaximumSupportedProtocolVersion == .TLSv12
    }

    private static func twin(of session: URLSession) -> URLSession {
        let key = ObjectIdentifier(session)
        return state.withLock { state in
            if let entry = state.twins[key] { return entry.twin }
            // `configuration` is a copy: the twin keeps the session's timeouts, cookie storage,
            // connection limit and cache, and lifts only the cap.
            let configuration = session.configuration
            configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
            let twin = URLSession.trusting(configuration)
            state.twins[key] = (session, twin)
            return twin
        }
    }
}

extension URLSession {
    /// `data(for:)` for a source's request: sent once more over TLS 1.3 when the host refuses
    /// TLS 1.2 (`SourceTLSFallback`).
    func sourceData(for request: URLRequest) async throws -> (Data, URLResponse) {
        // A cleartext request with a body goes out in one write (`SingleWriteHTTPExchange`).
        if SingleWriteHTTPExchange.handles(request, on: self) {
            return try await SingleWriteHTTPExchange.load(
                request, session: self, limit: .max, redirect: nil, transport: "sourceData"
            )
        }
        let first = SourceTLSFallback.session(self, for: request.url)
        do {
            return try await first.data(for: request)
        } catch {
            guard let twin = SourceTLSFallback.retrySession(after: error, on: first, request: request) else {
                throw error
            }
            return try await twin.data(for: request)
        }
    }

    /// `dataTask(with:completionHandler:)` for a source's request (`SourceTLSFallback`). The
    /// second send after a refused handshake is a task of its own, which cancelling the returned
    /// task does not reach.
    func sourceDataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> any SourceRequestTask {
        if SingleWriteHTTPExchange.handles(request, on: self) {
            return SingleWriteHTTPExchange.dataTask(
                with: request, session: self, limit: .max, redirect: nil, transport: "sourceData",
                completionHandler: completionHandler
            )
        }
        let first = SourceTLSFallback.session(self, for: request.url)
        return first.dataTask(with: request) { data, response, error in
            if let error, let twin = SourceTLSFallback.retrySession(after: error, on: first, request: request) {
                twin.dataTask(with: request, completionHandler: completionHandler).resume()
                return
            }
            completionHandler(data, response, error)
        }
    }
}
