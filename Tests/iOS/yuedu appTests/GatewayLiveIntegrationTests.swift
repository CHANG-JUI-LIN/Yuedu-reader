import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Debug-only route override behavior.
@Suite("Auth route override")
struct AuthRouteOverrideTests {
    @Test("the forced-gateway launch argument pins the route")
    func forcedGateway() {
        #expect(AuthRouteOverride.forcedRoute(launchArguments: ["-gateway-route-forced"]) == .gateway)
    }

    @Test("no argument leaves the route to policy")
    func noOverride() {
        #expect(AuthRouteOverride.forcedRoute(launchArguments: []) == nil)
        #expect(AuthRouteOverride.forcedRoute(launchArguments: ["-something-else"]) == nil)
    }

    @Test("Debug test builds inject the deployed gateway URL into Info.plist")
    func infoPlistInjection() {
        let value = Bundle.main.object(forInfoDictionaryKey: GatewayConfiguration.infoPlistKey) as? String
        #expect(value == "https://gateway.yuedureader.com")
        #expect(GatewayConfiguration.baseURL?.host == "gateway.yuedureader.com")
    }
}

/// Real-account integration against the deployed Gateway. Runs only when the
/// build has a Gateway URL (Debug/test build). It creates a throwaway email
/// account through the Gateway, exercises the account lifecycle, and deletes
/// the account at the end. It never touches a real user account.
@Suite("Gateway live integration", .serialized, .enabled(if: GatewayConfiguration.isConfigured))
@MainActor
struct GatewayLiveIntegrationTests {
    private struct MeResponse: Decodable { let user: AccountUser }
    private struct EntitlementResponse: Decodable { let exists: Bool }
    private struct LogoutResponse: Decodable { let signedOut: Bool; let revokedAllDevices: Bool }
    private struct RefreshBody: Encodable { let refreshToken: String }
    private struct LogoutBody: Encodable { let revokeAllDevices: Bool }

    private static func clearKeychain() {
        GatewayKeychain.delete(account: GatewayKeychain.refreshTokenAccount)
        GatewayKeychain.delete(account: GatewayKeychain.cachedUserAccount)
    }

    private static func makeClient(baseURL: URL) -> GatewayAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return GatewayAPIClient(
            session: URLSession(configuration: configuration),
            baseURLProvider: { baseURL }
        )
    }

    private static func makeJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    @Test("real account lifecycle through the deployed gateway")
    func realAccountLifecycle() async throws {
        let baseURL = try #require(GatewayConfiguration.baseURL)
        #expect(baseURL.host == "gateway.yuedureader.com")

        // Proof that this host is our gateway and not a Firebase endpoint: only
        // the gateway emits its own X-Request-Id.
        let (healthData, healthResponse) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("healthz")
        )
        let http = try #require(healthResponse as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect((http.value(forHTTPHeaderField: "X-Request-Id") ?? "").isEmpty == false)
        let healthJSON = try JSONSerialization.jsonObject(with: healthData) as? [String: Any]
        #expect(healthJSON?["status"] as? String == "ok")

        Self.clearKeychain()
        defer { Self.clearKeychain() }

        let client = Self.makeClient(baseURL: baseURL)
        let store = GatewaySessionStore(client: client)
        let provider = GatewayAuthProvider(store: store, client: client)

        let email = "gateway-it-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = "Gt-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        // --- Registration ---
        let registered = try await provider.signUpWithEmail(email: email, password: password)
        #expect(registered.email == email)
        #expect(store.user?.uid == registered.uid)
        let uid = registered.uid

        // --- Sign-in with the same credentials keeps the UID ---
        try await provider.signInWithEmail(email: email, password: password)
        #expect(store.user?.uid == uid)

        // --- Wrong password is a credential error, not a network error ---
        do {
            _ = try await provider.signInWithEmail(email: email, password: password + "-wrong")
            Issue.record("wrong password unexpectedly succeeded")
        } catch let error as GatewayAPIError {
            #expect(error.serverCode == "invalid-credentials")
            #expect(error.isConnectivityFailure == false)
        }

        // --- Duplicate registration is rejected by Firebase ---
        do {
            _ = try await provider.signUpWithEmail(email: email, password: password)
            Issue.record("duplicate registration unexpectedly succeeded")
        } catch let error as GatewayAPIError {
            #expect(error.serverCode == "email-exists")
        }

        // --- Restart: a second store restores the persisted session ---
        let restoredStore = GatewaySessionStore(client: client)
        #expect(restoredStore.hasSession)
        #expect(restoredStore.user?.uid == uid)
        _ = try await restoredStore.validIDToken(forceRefresh: true)
        let me: MeResponse = try await restoredStore.authorizedSend(
            GatewayRequest(method: "GET", path: "/v1/account/me"),
            as: MeResponse.self
        )
        #expect(me.user.uid == uid)

        let restoredProvider = GatewayAuthProvider(store: restoredStore, client: client)

        // --- Profile push / pull ---
        let backend = GatewayAccountBackend(store: restoredStore)
        let profile = UserProfile(
            uid: uid,
            displayName: "Gateway IT",
            email: email,
            provider: "Email",
            photoURL: nil,
            preferences: .current()
        )
        try await backend.upsertProfile(profile)
        let fetched = try #require(try await backend.fetchProfile(uid: uid))
        #expect(fetched.displayName == "Gateway IT")
        #expect(fetched.uid == uid)

        // --- Avatar upload / authenticated download ---
        let jpeg = Self.makeJPEG()
        #expect(jpeg.count > 0)
        let avatarURL = try await backend.uploadAvatar(data: jpeg)
        #expect(avatarURL.host == baseURL.host)
        let afterAvatar = try #require(try await backend.fetchProfile(uid: uid))
        #expect(afterAvatar.photoURL?.contains("/v1/avatar") == true)
        let avatarBytes = try await restoredStore.authorizedSendForData(
            GatewayRequest(method: "GET", path: "/v1/avatar")
        )
        #expect(avatarBytes.count > 0)
        #expect(avatarBytes.prefix(3) == Data([0xFF, 0xD8, 0xFF]))

        // --- Entitlement read: a brand-new account has no document ---
        let entitlement: EntitlementResponse = try await restoredStore.authorizedSend(
            GatewayRequest(
                method: "GET",
                path: "/v1/subscription/entitlement",
                query: [URLQueryItem(name: "environment", value: "production")]
            ),
            as: EntitlementResponse.self
        )
        #expect(entitlement.exists == false)

        // --- Subscription callable proxy: account token must be a real UUID ---
        let accountToken = try await backend.accountToken()
        #expect(accountToken.uuidString.count == 36)

        // --- Subscription callable proxy: an invalid transaction is rejected upstream ---
        do {
            _ = try await backend.bind(signedTransaction: "not.a.valid.jws")
            Issue.record("invalid signed transaction unexpectedly bound")
        } catch let error as GatewayAPIError {
            let code = error.serverCode ?? ""
            #expect(
                ["invalid-argument", "conflict", "permission-denied"].contains(code),
                "unexpected bind error: \(code) \(error.localizedDescription)"
            )
        }

        // --- Linking guards: email is already linked; the last provider cannot be removed ---
        do {
            try await restoredProvider.linkEmail(email: email, password: password)
            Issue.record("linking an already-linked email unexpectedly succeeded")
        } catch let error as GatewayAPIError {
            #expect(error.serverCode == "provider-already-linked")
        }
        do {
            _ = try await restoredProvider.unlink(providerID: "password")
            Issue.record("unlinking the last provider unexpectedly succeeded")
        } catch let error as GatewayAPIError {
            #expect(error.serverCode == "cannot-unlink-last-provider")
        }

        // --- Revocation: Console-style revoke must reject the next call and refresh ---
        let rawSession: GatewaySessionPayload = try await client.send(
            try GatewayRequest(method: "POST", path: "/v1/auth/email/signin")
                .jsonBody(["email": email, "password": password]),
            as: GatewaySessionPayload.self
        )
        let logout: LogoutResponse = try await client.send(
            try GatewayRequest(method: "POST", path: "/v1/auth/logout", authenticated: true)
                .jsonBody(LogoutBody(revokeAllDevices: true)),
            as: LogoutResponse.self,
            idToken: rawSession.idToken
        )
        #expect(logout.revokedAllDevices == true)
        do {
            _ = try await client.send(
                try GatewayRequest(method: "POST", path: "/v1/auth/refresh")
                    .jsonBody(RefreshBody(refreshToken: rawSession.refreshToken)),
                as: GatewaySessionPayload.self
            )
            Issue.record("revoked refresh token unexpectedly refreshed")
        } catch let error as GatewayAPIError {
            #expect(["unauthenticated", "user-disabled"].contains(error.serverCode ?? ""))
        }
        do {
            let _: MeResponse = try await client.send(
                GatewayRequest(method: "GET", path: "/v1/account/me", authenticated: true),
                as: MeResponse.self,
                idToken: rawSession.idToken
            )
            Issue.record("revoked ID token unexpectedly accepted")
        } catch let error as GatewayAPIError {
            #expect(error.serverCode == "unauthenticated")
        }

        // --- Account deletion (re-authenticated with the password) ---
        try await restoredProvider.signInWithEmail(email: email, password: password)
        try await restoredProvider.deleteAccount(reauth: .password(password))
        #expect(restoredStore.user == nil)

        do {
            _ = try await restoredProvider.signInWithEmail(email: email, password: password)
            Issue.record("deleted account unexpectedly signed in")
        } catch let error as GatewayAPIError {
            #expect(["invalid-credentials", "user-not-found"].contains(error.serverCode ?? ""))
        }
    }
}
