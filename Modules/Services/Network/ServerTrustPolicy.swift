import Foundation
import os
import Security

/// Every server certificate is accepted, as Legado accepts it.
///
/// Legado's one HTTP client (`HttpHelper.okHttpClient` in legado-E and MD3) trusts any
/// certificate (`SSLHelper.unsafeTrustManager`), accepts any host name
/// (`SSLHelper.unsafeHostnameVerifier`, `{ _, _ -> true }`) and still speaks TLS 1.0 and 1.1
/// (`ConnectionSpec.COMPATIBLE_TLS`). Every one of its WebViews answers `onReceivedSslError`
/// with `handler.proceed()` (`BackstageWebView`, `WebViewActivity`, `ReadRssActivity`,
/// `WebViewLoginFragment`, `BottomWebViewDialog`). Sources are written against that. A site
/// whose certificate has expired, names another host, or chains to a root iOS does not carry
/// reads fine in Legado, and failed here with `NSURLErrorServerCertificate…` (1329#16 and
/// 1330 爱优漫 in the 2026-11-07 audit). The maintainer chose on 2026-11-08 to accept these
/// across the whole app, not only for sources, as Legado does.
///
/// What this gives up: a network that can intercept a connection can read and change it,
/// including a request that carries an account token, an AI provider key or WebDAV
/// credentials. To keep the cost visible, each host whose certificate system validation would
/// have rejected is logged once per launch.
///
/// Not covered, because there is no hook to answer the challenge:
/// - `AsyncImage` before iOS 27 (it cannot take a session);
/// - the Firebase and GoogleSignIn SDKs' own sessions;
/// - CloudKit and other system services;
/// - media an `AVURLAsset` plays straight from an https URL (video sources, audiobooks).
///   AVFoundation does not ask its resource loader about server trust: measured 2026-11-08, a
///   self-signed host failed with -1202 and `shouldWaitForResponseTo` was never called.
///   Covering it would mean proxying every media byte through a custom-scheme loader, as
///   `AudioStreamResourceLoader` already does for TTS streams (which are covered);
/// - the fixed-layout EPUB page view (`FixedLayoutPageViewController`), which loads local
///   files only.
///
/// WebViews keep WebKit's refusal of TLS 1.0 and 1.1, because Legado's Chromium WebView
/// refuses them too.
enum ServerTrustPolicy {
    /// The answer to any authentication challenge a session or web view receives. A server-trust
    /// challenge is accepted with the certificate the server presented. Any other challenge
    /// (HTTP Basic or Digest, client certificates) is left to the system.
    static func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        auditOnce(trust, host: space.host)
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Lowers `configuration`'s TLS floor to 1.0 (0x0301), the floor Legado's `COMPATIBLE_TLS`
    /// keeps. The default floor is TLS 1.2 (measured 0x0303 on the 2026 SDKs). The value is
    /// written out because its name, `.TLSv10`, is deprecated and would warn on every build.
    static func allowLegacyTLS(_ configuration: URLSessionConfiguration) {
        if let floor = tls_protocol_version_t(rawValue: 0x0301) {
            configuration.tlsMinimumSupportedProtocolVersion = floor
        }
    }

    /// Caps `configuration` at TLS 1.2: the sessions that carry a source's own requests
    /// (`URLSession.sourceSites`).
    ///
    /// Since iOS 26 every TLS 1.3 ClientHello offers a post-quantum key share (X25519MLKEM768,
    /// `pqtls(true)` in the boringssl log), about 1.2 KB, so the ClientHello no longer fits one
    /// TCP segment. Some servers read only the first segment. Measured 2026-11-09 over the app's
    /// own request path (YCK1330): sou78, yuzhaiwuvip, po18as, powenwu1, haitang4 and xyushuwu7,
    /// Microsoft-IIS sites, accepted the TCP connection, never answered the ClientHello
    /// ("read_server_hello … waiting for data to read"), and the request timed out after 60 s;
    /// at other moments the same request was answered with TLS 1.3 over X25519 in 0.3 s. curl
    /// (8.7.1 on macOS, LibreSSL 3.3.6), which speaks TLS 1.3 without a post-quantum key share,
    /// was answered every time. Apple documents the cause ("an incorrect TLS implementation that fails to read large
    /// ClientHello messages", support.apple.com/122756) and gives apps no switch to leave the
    /// key share out. A TLS 1.2 ClientHello carries no key share at all.
    ///
    /// Same day, same eight sites, both configurations side by side twice: TLS 1.3, 4 of 24
    /// requests waited out 60 s with the ClientHello unanswered; TLS 1.2, 28 of 28 answered.
    /// TLS 1.2 also keeps these sessions off HTTP/3, which needs TLS 1.3. After xyyuedu.com
    /// advertised `Alt-Svc: h3`, its next request went over QUIC, and once that connection
    /// failed (`sec_framer_open_aesgcm` -4308, reset by peer) the request waited out 60 s on it;
    /// capped, every request stayed on HTTP/2. Legado's OkHttp speaks HTTP/1.1 and HTTP/2 only.
    ///
    /// A source site that accepts TLS 1.3 only refuses the capped handshake; its request is sent
    /// once more over TLS 1.3 (`SourceTLSFallback`). The maintainer chose the cap on 2026-11-09,
    /// for source requests only; the app's own servers, AI providers, WebDAV and everything else
    /// keep TLS 1.3.
    ///
    /// Not covered: a web view. WKWebView has no TLS version setting, so a source page rendered
    /// in one still loads its scripts and styles over TLS 1.3 — 1330 PO文屋's search page waited
    /// out 60 s on an unanswered ClientHello for `/web/css` and `/web/js` (WebKit networking log,
    /// 11-09).
    static func capAtTLS12(_ configuration: URLSessionConfiguration) {
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv12
    }

    private static let auditedHosts = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Logs, once per host per launch, a certificate that system validation rejects. The check
    /// runs on a copy of the chain, off the challenge's queue. A session's delegate queue is
    /// serial and a web view's challenge arrives on the main thread, and evaluation can wait on
    /// the network for missing intermediates or revocation.
    private static func auditOnce(_ trust: SecTrust, host: String) {
        guard auditedHosts.withLock({ $0.insert(host).inserted }),
              let chain = SecTrustCopyCertificateChain(trust) else { return }
        // Certificates are immutable once made; the copy is only read on the other queue.
        nonisolated(unsafe) let certificates = chain
        DispatchQueue.global(qos: .utility).async {
            var copy: SecTrust?
            let status = SecTrustCreateWithCertificates(
                certificates, SecPolicyCreateSSL(true, host as CFString), &copy
            )
            guard status == errSecSuccess, let copy else {
                AppLogger.network("TLS: could not copy a server's certificate chain to check it", context: [
                    "host": host, "status": Int(status),
                ], level: .warning)
                return
            }
            var error: CFError?
            guard !SecTrustEvaluateWithError(copy, &error) else { return }
            AppLogger.network("TLS: accepted a certificate that system validation rejects", context: [
                "host": host,
                "reason": error.map { CFErrorCopyDescription($0) as String } ?? "-",
            ], level: .warning)
        }
    }
}

/// The delegate of every session `URLSession.trusting` makes. It has no state, so one serves them
/// all.
final class ServerTrustSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    static let shared = ServerTrustSessionDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = ServerTrustPolicy.answer(challenge)
        completionHandler(disposition, credential)
    }
}

extension URLSession {
    /// Stands in for `URLSession.shared`, which takes no delegate and so cannot accept a
    /// certificate (`ServerTrustPolicy`). Built on the default configuration, it shares the shared
    /// session's cookie store, URL cache and credential store.
    static let trusting = trusting(.default)

    /// A session on `configuration` that accepts every server certificate and TLS 1.0 and up
    /// (`ServerTrustPolicy`). It sets `configuration`'s minimum TLS version.
    static func trusting(_ configuration: URLSessionConfiguration) -> URLSession {
        ServerTrustPolicy.allowLegacyTLS(configuration)
        return URLSession(configuration: configuration, delegate: ServerTrustSessionDelegate.shared, delegateQueue: nil)
    }

    /// `trusting` for a source's own requests, at TLS 1.0 to 1.2 (`ServerTrustPolicy.capAtTLS12`):
    /// a source's login, its chapter images. Rule pages (`WebFetcher`), `java.*` requests
    /// (`LegadoJSBridge.requestSession`) and saved downloads (`savedDownloads`) have sessions of
    /// their own, made with `sourceSites(_:)`.
    static let sourceSites = sourceSites(.default)

    /// A `trusting` session on `configuration`, capped at TLS 1.2 (`ServerTrustPolicy.capAtTLS12`).
    static func sourceSites(_ configuration: URLSessionConfiguration) -> URLSession {
        ServerTrustPolicy.capAtTLS12(configuration)
        return trusting(configuration)
    }
}
