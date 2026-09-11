import Foundation

/// Re-authentication material for sensitive Gateway operations. Created from a
/// fresh interactive credential; short-lived and never persisted.
enum GatewayReauth {
    case password(String)
    case apple(idToken: String, rawNonce: String, authorizationCode: String?)
    case google(idToken: String, accessToken: String?)
}

/// All Gateway auth operations. Returns the shared `AccountUser` model so the
/// business layer never sees a Gateway-specific payload.
@MainActor
final class GatewayAuthProvider {
    static let shared = GatewayAuthProvider()

    private let store: GatewaySessionStore
    private let client: GatewayAPIClient

    init(store: GatewaySessionStore? = nil, client: GatewayAPIClient? = nil) {
        self.store = store ?? .shared
        self.client = client ?? .shared
    }

    // MARK: - Sign-in

    func signInWithEmail(email: String, password: String) async throws -> AccountUser {
        try await authenticate(path: "/v1/auth/email/signin", body: EmailBody(email: email, password: password))
    }

    func signUpWithEmail(email: String, password: String) async throws -> AccountUser {
        try await authenticate(path: "/v1/auth/email/signup", body: EmailBody(email: email, password: password))
    }

    func signInWithApple(
        idToken: String,
        rawNonce: String,
        fullName: PersonNameComponents?
    ) async throws -> AccountUser {
        let body = IdpBody(
            provider: "apple",
            idToken: idToken,
            rawNonce: rawNonce,
            accessToken: nil,
            fullName: fullName.flatMap { components in
                let given = components.givenName
                let family = components.familyName
                if given == nil, family == nil { return nil }
                return IdpBody.FullName(givenName: given, familyName: family)
            }
        )
        return try await authenticate(path: "/v1/auth/idp", body: body)
    }

    func signInWithGoogle(idToken: String, accessToken: String?) async throws -> AccountUser {
        let body = IdpBody(
            provider: "google",
            idToken: idToken,
            rawNonce: nil,
            accessToken: accessToken,
            fullName: nil
        )
        return try await authenticate(path: "/v1/auth/idp", body: body)
    }

    func signInWithPendingToken(_ pendingToken: String) async throws -> AccountUser {
        struct Body: Encodable { let pendingToken: String }
        return try await authenticate(path: "/v1/auth/pending", body: Body(pendingToken: pendingToken))
    }

    /// Confirms the stored refresh token and republishes the account. Used by
    /// `FirebaseAuthManager` after adopting an externally obtained session.
    func refreshSession() async throws -> AccountUser {
        // The store owns the refresh token; asking it to resolve a token forces
        // the single-flight refresh and republishes the account.
        _ = try await store.validIDToken(forceRefresh: true)
        guard let user = store.user else {
            throw GatewaySessionError.noSession
        }
        return user
    }

    // MARK: - Account linking

    func linkEmail(email: String, password: String) async throws {
        let request = try GatewayRequest(method: "POST", path: "/v1/auth/link/email")
            .jsonBody(EmailBody(email: email, password: password))
        try await store.authorizedSendVoid(request)
    }

    func linkApple(idToken: String, rawNonce: String) async throws {
        let body = IdpLinkBody(provider: "apple", idToken: idToken, rawNonce: rawNonce, accessToken: nil)
        try await linkIdp(body)
    }

    func linkGoogle(idToken: String, accessToken: String?) async throws {
        let body = IdpLinkBody(provider: "google", idToken: idToken, rawNonce: nil, accessToken: accessToken)
        try await linkIdp(body)
    }

    private func linkIdp(_ body: IdpLinkBody) async throws {
        let request = try GatewayRequest(method: "POST", path: "/v1/auth/link/idp").jsonBody(body)
        do {
            try await store.authorizedSendVoid(request)
        } catch let error as GatewayAPIError where error.requiresRecentAuth {
            // The credential is already in hand; re-verify it through the normal
            // sign-in endpoint to mint a token with a fresh auth_time, then retry
            // the link once. This is a real credential check, not a token refresh.
            _ = try await reauthenticateWithIdp(body)
            try await store.authorizedSendVoid(request)
        }
    }

    func unlink(providerID: String) async throws -> AccountUser {
        struct Body: Encodable { let providerId: String }
        struct Response: Decodable { let user: AccountUser }
        let request = try GatewayRequest(method: "POST", path: "/v1/auth/unlink")
            .jsonBody(Body(providerId: providerID))
        let response = try await store.authorizedSend(request, as: Response.self)
        store.updateUser(response.user)
        return response.user
    }

    // MARK: - Sign-out / delete

    func logout(revokeAllDevices: Bool = false) async {
        if revokeAllDevices, store.hasSession {
            struct Body: Encodable { let revokeAllDevices: Bool }
            let request = GatewayRequest(method: "POST", path: "/v1/auth/logout")
            if let body = try? request.jsonBody(Body(revokeAllDevices: true)) {
                _ = try? await store.authorizedSendVoid(body)
            }
        }
        store.clearLocalSession()
    }

    func deleteAccount(reauth: GatewayReauth) async throws {
        let request = try GatewayRequest(method: "POST", path: "/v1/account/delete")
            .jsonBody(DeleteBody(reauth: DeleteBody.Reauth(reauth)))
        try await store.authorizedSendVoid(request)
        store.clearLocalSession()
    }

    // MARK: - Helpers

    private func authenticate<Body: Encodable>(path: String, body: Body) async throws -> AccountUser {
        let request = try GatewayRequest(method: "POST", path: path).jsonBody(body)
        do {
            let payload = try await client.send(request, as: GatewaySessionPayload.self)
            store.adopt(payload)
            return payload.user
        } catch let error as GatewayAPIError {
            if let pending = error.details["pendingToken"] as? String, !pending.isEmpty {
                throw AuthFlowError.pendingGatewayCredential(pending)
            }
            throw error
        }
    }

    private func reauthenticateWithIdp(_ body: IdpLinkBody) async throws -> AccountUser {
        let request = try GatewayRequest(method: "POST", path: "/v1/auth/idp").jsonBody(body)
        do {
            let payload = try await client.send(request, as: GatewaySessionPayload.self)
            store.adopt(payload)
            return payload.user
        } catch let error as GatewayAPIError {
            if let pending = error.details["pendingToken"] as? String, !pending.isEmpty {
                throw AuthFlowError.pendingGatewayCredential(pending)
            }
            throw error
        }
    }
}

private struct EmailBody: Encodable {
    let email: String
    let password: String
}

private struct IdpBody: Encodable {
    struct FullName: Encodable {
        let givenName: String?
        let familyName: String?
    }
    let provider: String
    let idToken: String
    let rawNonce: String?
    let accessToken: String?
    let fullName: FullName?
}

private struct IdpLinkBody: Encodable {
    let provider: String
    let idToken: String
    let rawNonce: String?
    let accessToken: String?
}

private struct DeleteBody: Encodable {
    let reauth: Reauth

    struct Reauth: Encodable {
        let provider: String
        let password: String?
        let idToken: String?
        let rawNonce: String?
        let accessToken: String?
        let appleAuthorizationCode: String?

        init(_ reauth: GatewayReauth) {
            switch reauth {
            case .password(let password):
                provider = "password"
                self.password = password
                idToken = nil
                rawNonce = nil
                accessToken = nil
                appleAuthorizationCode = nil
            case .apple(let idToken, let rawNonce, let authorizationCode):
                provider = "apple"
                password = nil
                self.idToken = idToken
                self.rawNonce = rawNonce
                accessToken = nil
                appleAuthorizationCode = authorizationCode
            case .google(let idToken, let accessToken):
                provider = "google"
                password = nil
                self.idToken = idToken
                rawNonce = nil
                self.accessToken = accessToken
                appleAuthorizationCode = nil
            }
        }
    }
}
