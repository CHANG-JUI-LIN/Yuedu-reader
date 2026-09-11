import Foundation
import StoreKit

/// Gateway implementation of the account backend. Every request goes to the
/// relay; no Google-hosted endpoint is contacted.
@MainActor
final class GatewayAccountBackend: AccountBackend {
    private let store: GatewaySessionStore

    init(store: GatewaySessionStore? = nil) {
        self.store = store ?? .shared
    }

    func fetchProfile(uid: String) async throws -> UserProfile? {
        // Admin access bypasses Security Rules, so the in-flight request must be
        // pinned to the uid that started it; otherwise a response ordered after a
        // sign-in could publish the previous account's profile.
        guard store.uid == uid else { throw AccountBackendError.notAuthenticated }
        struct Response: Decodable { let profile: GatewayProfilePayload? }
        let request = GatewayRequest(method: "GET", path: "/v1/profile")
        let response = try await store.authorizedSend(request, as: Response.self)
        guard store.uid == uid else { throw AccountBackendError.notAuthenticated }
        return response.profile?.userProfile
    }

    func upsertProfile(_ profile: UserProfile) async throws {
        // The token decides which document the server writes; refusing a write
        // whose uid no longer owns the session prevents account A's settings
        // from being written into account B's profile.
        guard store.uid == profile.uid else { throw AccountBackendError.notAuthenticated }
        struct Patch: Encodable {
            let displayName: String
            let preferences: ReaderPreferences
        }
        let request = try GatewayRequest(method: "PUT", path: "/v1/profile")
            .jsonBody(Patch(displayName: profile.displayName, preferences: profile.preferences))
        try await store.authorizedSendVoid(request)
    }

    func uploadAvatar(data: Data) async throws -> URL {
        var request = GatewayRequest(method: "PUT", path: "/v1/avatar")
        request.body = data
        request.headers["Content-Type"] = "image/jpeg"
        let responseData = try await store.authorizedSendForData(request)
        struct Response: Decodable { let photoURL: String }
        guard
            let response = try? JSONDecoder().decode(Response.self, from: responseData),
            let url = URL(string: response.photoURL)
        else {
            throw AccountBackendError.invalidResponse
        }
        store.updateUserPhotoURL(url.absoluteString)
        return url
    }

    func refreshEntitlement(uid: String) async throws -> CachedSubscriptionEntitlement? {
        guard SubscriptionRuntimeEnvironment.isResolved else { return nil }
        let environment = SubscriptionRuntimeEnvironment.current == .sandbox ? "sandbox" : "production"
        let request = GatewayRequest(
            method: "GET",
            path: "/v1/subscription/entitlement",
            query: [URLQueryItem(name: "environment", value: environment)]
        )
        let response = try await store.authorizedSend(request, as: GatewayEntitlementResponse.self)
        guard response.exists else { return nil }
        return CachedSubscriptionEntitlement(
            isProActive: response.isProActive ?? false,
            expiresAt: response.expiresAtMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) },
            productIDs: response.productIds
        )
    }

    func accountToken() async throws -> UUID {
        struct Response: Decodable { let token: String }
        let request = GatewayRequest(method: "GET", path: "/v1/subscription/account-token")
        let response = try await store.authorizedSend(request, as: Response.self)
        guard let token = UUID(uuidString: response.token) else {
            throw SubscriptionAccountError.invalidServerResponse
        }
        return token
    }

    func bind(signedTransaction: String) async throws -> CachedSubscriptionEntitlement {
        struct Body: Encodable { let signedTransaction: String }
        let request = try GatewayRequest(method: "POST", path: "/v1/subscription/bind")
            .jsonBody(Body(signedTransaction: signedTransaction))
        let response = try await store.authorizedSend(request, as: GatewayEntitlementResponse.self)
        return CachedSubscriptionEntitlement(
            isProActive: response.isProActive ?? false,
            expiresAt: response.expiresAtMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) },
            productIDs: response.productIds
        )
    }

    func deleteSubscriptionAccountData() async throws {
        let request = GatewayRequest(method: "DELETE", path: "/v1/subscription/account-data")
        try await store.authorizedSendVoid(request)
    }

    func requestTestFlightAccess(email: String) async throws -> TestFlightAccessResult {
        struct Body: Encodable { let email: String }
        struct Response: Decodable {
            let alreadySubmitted: Bool
            let status: String
        }
        let request = try GatewayRequest(method: "POST", path: "/v1/subscription/testflight-request")
            .jsonBody(Body(email: email))
        let response = try await store.authorizedSend(request, as: Response.self)
        return TestFlightAccessResult(alreadySubmitted: response.alreadySubmitted, status: response.status)
    }

    func deleteRemoteData(uid: String) async throws {
        // Account deletion on the Gateway is orchestrated by
        // `FirebaseAuthManager.deleteAccount` through POST /v1/account/delete,
        // which cleans user data before the Auth user is removed.
        throw AccountBackendError.unsupportedOnGateway
    }
}

private extension GatewaySessionStore {
    /// Keeps the cached account snapshot's avatar in sync after an upload
    /// without waiting for the next profile fetch.
    func updateUserPhotoURL(_ photoURL: String) {
        guard let user else { return }
        updateUser(AccountUser(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName,
            photoURL: photoURL,
            providerIds: user.providerIds,
            emailVerified: user.emailVerified
        ))
    }
}

struct GatewayEntitlementResponse: Decodable {
    let exists: Bool
    let isProActive: Bool?
    let productIds: [String]?
    let expiresAtMilliseconds: Double?
}

/// Wire shape of `GET/PUT /v1/profile`. Dates are ISO strings; preferences use
/// the same keys as `ReaderPreferences`.
struct GatewayProfilePayload: Decodable {
    let uid: String
    let displayName: String
    let email: String
    let provider: String
    let photoURL: String?
    let createdAt: String
    let updatedAt: String
    let preferences: ReaderPreferences?

    enum CodingKeys: String, CodingKey {
        case uid, displayName, email, provider, photoURL, createdAt, updatedAt, preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = (try? container.decode(String.self, forKey: .uid)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
        email = (try? container.decode(String.self, forKey: .email)) ?? ""
        provider = (try? container.decode(String.self, forKey: .provider)) ?? ""
        photoURL = try? container.decodeIfPresent(String.self, forKey: .photoURL)
        createdAt = (try? container.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? container.decode(String.self, forKey: .updatedAt)) ?? ""
        preferences = try? container.decodeIfPresent(ReaderPreferences.self, forKey: .preferences)
    }

    var userProfile: UserProfile {
        UserProfile(
            uid: uid,
            displayName: displayName,
            email: email,
            provider: provider,
            photoURL: photoURL,
            createdAt: Self.parseDate(createdAt),
            updatedAt: Self.parseDate(updatedAt),
            preferences: preferences ?? .current()
        )
    }

    static func parseDate(_ value: String) -> Date {
        guard !value.isEmpty else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? Date()
    }
}
