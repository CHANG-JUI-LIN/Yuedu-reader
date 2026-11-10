import Foundation
import Security
import Testing
@testable import yuedu_app

/// Every server certificate is accepted, as Legado accepts it (`ServerTrustPolicy`).
///
/// These check the answer the app gives a challenge and how its sessions are set up. Whether
/// URLSession honours the answer was measured outside the app against badssl.com
/// (2026-11-08): with the system's answer, expired, self-signed, wrong-host, untrusted-root,
/// TLS 1.0 and TLS 1.1 hosts all failed (-1202 / -1200); with this policy all six loaded.
@Suite("Server trust policy")
struct ServerTrustPolicyTests {
    /// `CN=self-signed.yuedu.invalid`, self-signed, generated for this test with
    /// `openssl req -x509 -newkey rsa:2048 -days 3650`.
    private static let selfSignedDER = """
        MIICxDCCAawCCQCxJy3ZZLvBJjANBgkqhkiG9w0BAQsFADAkMSIwIAYDVQQDDBlzZWxmLXNpZ25lZC55dWVkdS5pbnZhbGlk
        MB4XDTI2MTEwODA3MDEwMVoXDTM2MTEwNTA3MDEwMVowJDEiMCAGA1UEAwwZc2VsZi1zaWduZWQueXVlZHUuaW52YWxpZDCC
        ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAPRf6/E2rOqdsQVjBxejyXt+hArC1swv1/O495sJcjvvMFcNKO8+a3nY
        e4QMHrjsCXhyA+s3rPvAguJXBwVLH4SHura3SFtkzTJ7CPn9YeyB/j6OOrE6wB5CrAzEdHXQ7JePsRP4/C17726s9hpUhqBT
        TXi5ZdoW+aDyn+emS1liyr2mOdu1mBkP3Jcrpn9G0yoV2+sOU6p5UrApmEozDDoeBV0XczPRQsH1tgkMZuyLJTsoqUBazbiv
        6qtgIleffz8YgTWdbEVgRpaPO/U8eQxF2QSwm6W8tIL/KDPHQpFGbEkAJDs92878ewSeDS5+GKMyYsC9C1LdZQRb2CY6USEC
        AwEAATANBgkqhkiG9w0BAQsFAAOCAQEADgC8icB+QpQcYdZr/gYLdGOnkcXYWiipxaL7vvZSCKEqFJDoG9oIHrgkqG12yYmM
        6xNZqZ11vJqP/CLfA5qQpl51F2ozIE8lZaKhJnAhvDEdfFpjcqvTFZuxy7F+NjMzZNbTrb4r2DDJpoyPaX/s9Fdjw/UUb//s
        w77l0Q55I/SATUI/9wGbXEYkenrqvZvt1xASScOW3pW4e7nVVwQ/c/LK2qrxZB842WHHnqiAyAUteszik8i8316kqn6smh3u
        /0erVmztNJY0N45oAXHuUsPz6SZEXAWvO9B2JQ/T2PkRuIhQUsg4fpEojQbPi9j3i1V+cspj/w4/BbqiJUIF1g==
        """.filter { !$0.isWhitespace }

    private func selfSignedTrust(host: String) throws -> SecTrust {
        let der = try #require(Data(base64Encoded: Self.selfSignedDER))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    private func challenge(_ space: URLProtectionSpace) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: IgnoringSender()
        )
    }

    @Test("a certificate the system rejects is accepted with the trust the server presented")
    func selfSignedCertificateIsAccepted() throws {
        let host = "self-signed.yuedu.invalid"
        let trust = try selfSignedTrust(host: host)
        var error: CFError?
        // The premise: system validation rejects this chain.
        #expect(!SecTrustEvaluateWithError(trust, &error))

        let (disposition, credential) = ServerTrustPolicy.answer(challenge(TrustSpace(host: host, trust: trust)))
        #expect(disposition == .useCredential)
        #expect(credential != nil)
    }

    @Test("HTTP Basic and other challenges are left to the system")
    func otherChallengesUseDefaultHandling() {
        let space = URLProtectionSpace(
            host: "webdav.yuedu.invalid", port: 443, protocol: NSURLProtectionSpaceHTTPS,
            realm: "dav", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let (disposition, credential) = ServerTrustPolicy.answer(challenge(space))
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("the app's sessions accept TLS 1.0 and answer challenges with the policy")
    func trustingSessionsAreConfigured() {
        // 0x0301 is TLS 1.0, the floor Legado's `COMPATIBLE_TLS` keeps.
        #expect(URLSession.trusting.configuration.tlsMinimumSupportedProtocolVersion.rawValue == 0x0301)
        #expect(URLSession.trusting.delegate is ServerTrustSessionDelegate)
        let custom = URLSession.trusting(.ephemeral)
        #expect(custom.configuration.tlsMinimumSupportedProtocolVersion.rawValue == 0x0301)
        #expect(custom.delegate is ServerTrustSessionDelegate)
    }

    /// iOS 26's TLS 1.3 ClientHello is too large for some source sites to read
    /// (`ServerTrustPolicy.capAtTLS12`); the app's own sessions keep TLS 1.3.
    @Test("a source's sessions stop at TLS 1.2; the app's own keep TLS 1.3")
    func sourceSessionsStopAtTLS12() {
        for session in [URLSession.sourceSites, LegadoJSBridge.requestSession, URLSession.savedDownloads] {
            #expect(session.configuration.tlsMaximumSupportedProtocolVersion == .TLSv12)
            #expect(session.configuration.tlsMinimumSupportedProtocolVersion.rawValue == 0x0301)
            #expect(session.delegate is ServerTrustSessionDelegate)
        }
        #expect(URLSession.sourceSites(.ephemeral).configuration.tlsMaximumSupportedProtocolVersion == .TLSv12)
        #expect(URLSession.trusting.configuration.tlsMaximumSupportedProtocolVersion != .TLSv12)
    }

    /// What URLSession reports when a server refuses the handshake: -1200 with the failing URL
    /// (zh.virtualtaboo.live answered the capped one with -9836 protocol_version, r15).
    private func refusedHandshake(_ url: URL, streamError: Int = -9836) -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, userInfo: [
            NSURLErrorFailingURLErrorKey: url, "_kCFStreamErrorCodeKey": streamError,
        ])
    }

    @Test("a host that refuses TLS 1.2 is sent again over TLS 1.3, and stays there")
    func refusedTLS12IsResentOverTLS13() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 37
        let capped = URLSession.sourceSites(configuration)
        let url = try #require(URL(string: "https://tls13-only.yuedu.invalid/search?q=1"))
        let request = URLRequest(url: url)

        // Before any refusal the host goes out on the capped session.
        #expect(SourceTLSFallback.session(capped, for: url) === capped)

        let twin = try #require(SourceTLSFallback.retrySession(
            after: refusedHandshake(url), on: capped, request: request
        ))
        #expect(twin !== capped)
        #expect(twin.configuration.tlsMaximumSupportedProtocolVersion == .TLSv13)
        #expect(twin.configuration.tlsMinimumSupportedProtocolVersion.rawValue == 0x0301)
        #expect(twin.configuration.timeoutIntervalForRequest == 37)
        #expect(twin.delegate is ServerTrustSessionDelegate)

        // The host now goes straight to the same twin; another host stays capped.
        let later = try #require(URL(string: "https://TLS13-only.yuedu.invalid/book/1"))
        #expect(SourceTLSFallback.session(capped, for: later) === twin)
        let other = try #require(URL(string: "https://tls12-fine.yuedu.invalid/"))
        #expect(SourceTLSFallback.session(capped, for: other) === capped)
        // The twin is never sent again: it is not capped.
        #expect(SourceTLSFallback.retrySession(after: refusedHandshake(url), on: twin, request: request) == nil)
    }

    @Test("a timeout or an uncapped session is not sent again")
    func onlyRefusedHandshakesOnCappedSessionsAreResent() throws {
        let capped = URLSession.sourceSites(.ephemeral)
        let url = try #require(URL(string: "https://silent-hello.yuedu.invalid/"))
        let request = URLRequest(url: url)
        // A server that never answers the ClientHello: what the cap is for.
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
        ])
        #expect(SourceTLSFallback.retrySession(after: timedOut, on: capped, request: request) == nil)
        #expect(SourceTLSFallback.session(capped, for: url) === capped)

        let uncapped = URLSession.trusting(.ephemeral)
        let refusedElsewhere = try #require(URL(string: "https://app-server.yuedu.invalid/"))
        #expect(SourceTLSFallback.retrySession(
            after: refusedHandshake(refusedElsewhere), on: uncapped, request: URLRequest(url: refusedElsewhere)
        ) == nil)
    }
}

/// A server-trust protection space holding a trust built in the test. The system sets
/// `serverTrust` only on spaces it makes during a TLS handshake.
private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust) {
        self.trust = trust
        super.init(
            host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS,
            realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

private final class IgnoringSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
