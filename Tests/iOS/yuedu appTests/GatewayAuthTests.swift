import Foundation
import Testing
@testable import yuedu_app

@Suite("Auth route policy")
struct AuthRoutePolicyTests {
    @Test("forced modes win over memory and region")
    func forcedModesWin() {
        let memory = AuthRoute.gateway
        #expect(AuthRoutePolicy.decide(
            mode: .direct,
            gatewayConfigured: true,
            lastSuccessfulRoute: memory,
            regionHintIsMainland: true
        ).route == .direct)
        #expect(AuthRoutePolicy.decide(
            mode: .gateway,
            gatewayConfigured: true,
            lastSuccessfulRoute: .direct,
            regionHintIsMainland: false
        ).route == .gateway)
    }

    @Test("gateway mode falls back to direct when no gateway URL is configured")
    func gatewayUnavailableFallsBack() {
        let decision = AuthRoutePolicy.decide(
            mode: .gateway,
            gatewayConfigured: false,
            lastSuccessfulRoute: nil,
            regionHintIsMainland: true
        )
        #expect(decision.route == .direct)
        #expect(decision.decision == .unavailableGatewayFallback)
    }

    @Test("automatic remembers the last successful route before hinting")
    func automaticPrefersMemory() {
        let decision = AuthRoutePolicy.decide(
            mode: .automatic,
            gatewayConfigured: true,
            lastSuccessfulRoute: .direct,
            regionHintIsMainland: true
        )
        #expect(decision.route == .direct)
        #expect(decision.decision == .remembered(.direct))
    }

    @Test("a remembered gateway route never wins when this build has no relay entry")
    func rememberedGatewayUnavailable() {
        let decision = AuthRoutePolicy.decide(
            mode: .automatic,
            gatewayConfigured: false,
            lastSuccessfulRoute: .gateway,
            regionHintIsMainland: true
        )
        #expect(decision.route == .direct)
        #expect(decision.decision == .unavailableGatewayFallback)
    }

    @Test("automatic without memory uses the region only as a hint")
    func automaticUsesRegionHint() {
        #expect(AuthRoutePolicy.decide(
            mode: .automatic,
            gatewayConfigured: true,
            lastSuccessfulRoute: nil,
            regionHintIsMainland: true
        ).route == .gateway)
        #expect(AuthRoutePolicy.decide(
            mode: .automatic,
            gatewayConfigured: true,
            lastSuccessfulRoute: nil,
            regionHintIsMainland: false
        ).route == .direct)
    }

    @Test("sign-in may switch routes after connectivity failure, side effects may not")
    func fallbackPolicy() {
        #expect(AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .signInWithEmail))
        #expect(AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .signInWithApple))
        #expect(AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .signInWithGoogle))
        #expect(!AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .signUpWithEmail))
        #expect(!AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .link))
        #expect(!AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .deleteAccount))
        #expect(!AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: .bindPurchase))
    }
}

@Suite("Gateway API error classification")
struct GatewayAPIErrorTests {
    @Test("transport and upstream failures are connectivity, not credential, errors")
    func connectivityClassification() {
        #expect(GatewayAPIError.transport(URLError(.notConnectedToInternet)).isConnectivityFailure)
        #expect(!GatewayAPIError.transport(URLError(.notConnectedToInternet)).isSessionInvalid)
        let upstream = GatewayAPIError.server(
            code: "upstream-unavailable",
            message: "down",
            status: 503,
            details: [:]
        )
        #expect(upstream.isConnectivityFailure)
        #expect(!upstream.isSessionInvalid)
    }

    @Test("revoked and disabled sessions are invalid, not connectivity")
    func invalidSessionClassification() {
        for code in ["unauthenticated", "user-disabled", "user-not-found"] {
            let error = GatewayAPIError.server(code: code, message: "x", status: 401, details: [:])
            #expect(error.isSessionInvalid)
            #expect(!error.isConnectivityFailure)
        }
    }

    @Test("reauth-required is separated from both")
    func reauthClassification() {
        let error = GatewayAPIError.server(code: "reauth-required", message: "x", status: 401, details: [:])
        #expect(error.requiresRecentAuth)
        #expect(!error.isSessionInvalid)
        #expect(!error.isConnectivityFailure)
    }

    @Test("callable gRPC metadata survives the wire")
    func grpcMetadata() {
        let error = GatewayAPIError.server(
            code: "conflict",
            message: "one slot",
            status: 409,
            details: ["grpcStatus": "ALREADY_EXISTS", "grpcCode": 6]
        )
        #expect(error.grpcCode == 6)
        #expect(error.grpcStatus == "ALREADY_EXISTS")
    }

    @Test("unstructured 5xx is connectivity, structured 4xx is not")
    func failureClassification() {
        let html = Data("<html>Bad Gateway</html>".utf8)
        let server = GatewayAPIClient.classifyFailure(data: html, status: 502)
        #expect(server.isConnectivityFailure)

        let structured = Data(#"{"error":{"code":"conflict","message":"one slot"}}"#.utf8)
        let conflict = GatewayAPIClient.classifyFailure(data: structured, status: 409)
        #expect(conflict.serverCode == "conflict")
        #expect(!conflict.isConnectivityFailure)

        let malformed = GatewayAPIClient.classifyFailure(data: Data("nope".utf8), status: 400)
        if case .invalidResponse = malformed {} else {
            Issue.record("expected invalidResponse")
        }
    }
}

@Suite("Gateway profile payload")
struct GatewayProfilePayloadTests {
    @Test("decodes ISO dates and reader preferences")
    func decodesFullProfile() throws {
        let json = """
        {
          "profile": {
            "uid": "uid-1",
            "displayName": "Reader",
            "email": "reader@example.com",
            "provider": "Email",
            "photoURL": "https://gateway.example.com/v1/avatar?v=1",
            "createdAt": "2026-01-02T03:04:05.678Z",
            "updatedAt": "2026-01-03T03:04:05.000Z",
            "preferences": {"readerFontSize": 20, "theme": "dark", "lineHeightMultiple": 1.4,
              "letterSpacing": 0, "paragraphSpacingMultiplier": 1, "pageMarginH": 16, "pageMarginV": 16,
              "footerBottomPadding": 0, "footerTextGap": 0, "pageTurnStyle": "curl",
              "readerWritingMode": "horizontal", "textConversion": "original", "scrollMode": false}
          }
        }
        """.data(using: .utf8)!
        struct Response: Decodable { let profile: GatewayProfilePayload? }
        let response = try JSONDecoder().decode(Response.self, from: json)
        let profile = try #require(response.profile?.userProfile)
        #expect(profile.uid == "uid-1")
        #expect(profile.displayName == "Reader")
        #expect(profile.preferences.readerFontSize == 20)
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(profile.createdAt == expected.date(from: "2026-01-02T03:04:05.678Z"))
    }

    @Test("a null profile stays nil")
    func decodesMissingProfile() throws {
        struct Response: Decodable { let profile: GatewayProfilePayload? }
        let response = try JSONDecoder().decode(Response.self, from: #"{"profile":null}"#.data(using: .utf8)!)
        #expect(response.profile == nil)
    }

    @Test("missing preferences fall back to current settings rather than failing")
    func decodesWithoutPreferences() throws {
        let json = """
        {"uid":"u","displayName":"n","email":"e","provider":"Email","createdAt":"","updatedAt":""}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(GatewayProfilePayload.self, from: json)
        #expect(payload.userProfile.uid == "u")
    }
}

@Suite("Gateway avatar URL resolution")
struct GatewayAvatarURLResolverTests {
    private let gateway = URL(string: "https://gateway.example.com")!

    @Test("storage URLs are rewritten to the gateway only on the gateway route")
    func rewritesStorageURL() {
        let storage = "https://firebasestorage.googleapis.com/v0/b/yuedu-readerr.firebasestorage.app/o/avatars%2Fuid.jpg?alt=media"
        let rewritten = GatewayAvatarURLResolver.resolvedURL(
            from: storage,
            gatewayRouteActive: true,
            gatewayBaseURL: gateway
        )
        #expect(rewritten?.absoluteString == "https://gateway.example.com/v1/avatar")
        let untouched = GatewayAvatarURLResolver.resolvedURL(
            from: storage,
            gatewayRouteActive: false,
            gatewayBaseURL: gateway
        )
        #expect(untouched?.absoluteString == storage)
    }

    @Test("gateway URLs are recognized and never rewritten twice")
    func keepsGatewayURL() {
        let url = "https://gateway.example.com/v1/avatar?v=1"
        #expect(GatewayAvatarURLResolver.isGatewayURL(URL(string: url)!, gatewayBaseURL: gateway))
        #expect(GatewayAvatarURLResolver.resolvedURL(
            from: url,
            gatewayRouteActive: true,
            gatewayBaseURL: gateway
        )?.absoluteString == url)
    }

    @Test("unrelated public URLs are left alone")
    func leavesUnrelatedURL() {
        let url = "https://example.com/avatar.jpg"
        #expect(GatewayAvatarURLResolver.resolvedURL(
            from: url,
            gatewayRouteActive: true,
            gatewayBaseURL: gateway
        )?.absoluteString == url)
    }
}

// MARK: - Session store

private final class GatewayMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var refreshCount = 0

    static func reset() {
        handler = nil
        requestCount = 0
        refreshCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if request.url?.path.hasSuffix("/v1/auth/refresh") == true {
            Self.refreshCount += 1
        }
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
@Suite("Gateway session store", .serialized)
struct GatewaySessionStoreTests {
    private let gatewayBaseURL = URL(string: "https://gateway.test")!

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeStore() -> GatewaySessionStore {
        GatewaySessionStore(
            client: GatewayAPIClient(session: makeSession(), baseURLProvider: { gatewayBaseURL })
        )
    }

    private func sessionJSON(idToken: String, refreshToken: String, expiresIn: Int) -> Data {
        """
        {"idToken":"\(idToken)","refreshToken":"\(refreshToken)","expiresIn":\(expiresIn),
         "user":{"uid":"uid-1","email":"a@b.co","displayName":"A","photoURL":null,
                 "providerIds":["password"],"emailVerified":false}}
        """.data(using: .utf8)!
    }

    private func clearKeychain() {
        GatewayKeychain.delete(account: GatewayKeychain.refreshTokenAccount)
        GatewayKeychain.delete(account: GatewayKeychain.cachedUserAccount)
    }

    @Test("adopt persists the refresh token so a relaunch can restore")
    func adoptPersists() {
        clearKeychain()
        defer { clearKeychain() }
        let first = makeStore()
        first.adopt(try! JSONDecoder().decode(
            GatewaySessionPayload.self,
            from: sessionJSON(idToken: "t1", refreshToken: "r1", expiresIn: 3600)
        ))
        let second = makeStore()
        #expect(second.hasSession)
        #expect(second.uid == "uid-1")
    }

    @Test("concurrent token resolution refreshes only once")
    func singleFlightRefresh() async {
        clearKeychain()
        defer { clearKeychain() }
        GatewayMockURLProtocol.reset()
        GatewayMockURLProtocol.handler = { request in
            (200, self.sessionJSON(idToken: "fresh", refreshToken: "r2", expiresIn: 3600))
        }
        let store = makeStore()
        store.adopt(try! JSONDecoder().decode(
            GatewaySessionPayload.self,
            from: sessionJSON(idToken: "stale", refreshToken: "r1", expiresIn: 1)
        ))
        async let first = store.validIDToken(forceRefresh: true)
        async let second = store.validIDToken(forceRefresh: true)
        let tokens = try? await [first, second]
        #expect(tokens == ["fresh", "fresh"])
        #expect(GatewayMockURLProtocol.refreshCount == 1)
    }

    @Test("an invalid refresh token clears the session")
    func invalidRefreshClears() async {
        clearKeychain()
        defer { clearKeychain() }
        GatewayMockURLProtocol.reset()
        let error = #"{"error":{"code":"unauthenticated","message":"expired"}}"#.data(using: .utf8)!
        GatewayMockURLProtocol.handler = { _ in (401, error) }
        let store = makeStore()
        store.adopt(try! JSONDecoder().decode(
            GatewaySessionPayload.self,
            from: sessionJSON(idToken: "t", refreshToken: "revoked", expiresIn: 1)
        ))
        _ = try? await store.validIDToken(forceRefresh: true)
        #expect(!store.hasSession)
        #expect(GatewayKeychain.load(account: GatewayKeychain.refreshTokenAccount) == nil)
    }

    @Test("a transport failure keeps the stored session for a later retry")
    func transportFailureKeepsSession() async {
        clearKeychain()
        defer { clearKeychain() }
        GatewayMockURLProtocol.reset()
        GatewayMockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore()
        store.adopt(try! JSONDecoder().decode(
            GatewaySessionPayload.self,
            from: sessionJSON(idToken: "t", refreshToken: "r", expiresIn: 1)
        ))
        _ = try? await store.validIDToken(forceRefresh: true)
        #expect(store.hasSession)
        #expect(store.uid == "uid-1")
    }

    @Test("a 401 on a data request refreshes once and retries")
    func dataRequestRetriesAfter401() async throws {
        clearKeychain()
        defer { clearKeychain() }
        GatewayMockURLProtocol.reset()
        GatewayMockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/v1/auth/refresh") == true {
                return (200, self.sessionJSON(idToken: "fresh", refreshToken: "r2", expiresIn: 3600))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" {
                return (200, #"{"user":{"uid":"uid-1","email":"a@b.co","displayName":"A","photoURL":null,"providerIds":["password"],"emailVerified":false}}"#.data(using: .utf8)!)
            }
            return (401, #"{"error":{"code":"unauthenticated","message":"stale"}}"#.data(using: .utf8)!)
        }
        let store = makeStore()
        store.adopt(try! JSONDecoder().decode(
            GatewaySessionPayload.self,
            from: sessionJSON(idToken: "stale", refreshToken: "r1", expiresIn: 3600)
        ))
        struct Response: Decodable { let user: AccountUser }
        let response = try await store.authorizedSend(
            GatewayRequest(method: "GET", path: "/v1/account/me"),
            as: Response.self
        )
        #expect(response.user.uid == "uid-1")
        #expect(GatewayMockURLProtocol.refreshCount == 1)
    }
}
