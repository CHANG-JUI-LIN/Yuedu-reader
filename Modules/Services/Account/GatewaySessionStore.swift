import Combine
import Foundation

/// Remembers which route last worked, so the automatic mode does not re-guess
/// on every launch. Not sensitive; stored in UserDefaults.
enum AuthRouteMemory {
    private static let key = "yd_auth_last_successful_route"

    static var lastSuccessfulRoute: AuthRoute? {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(AuthRoute.init(rawValue:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

enum GatewaySessionError: Error {
    case noSession
}

/// The single Gateway-side session source of truth.
///
/// Holds the short-lived ID token in memory, the refresh token in the Keychain,
/// and the last server-authoritative account snapshot for offline launch. A
/// refresh is single-flight, and a transport failure never deletes the refresh
/// token — only an explicit `unauthenticated` / `user-disabled` answer does.
@MainActor
final class GatewaySessionStore: ObservableObject {
    static let shared = GatewaySessionStore()

    @Published private(set) var user: AccountUser?
    @Published private(set) var isRestoring = false
    /// Last transport-level restore failure, so UI can say "showing cached
    /// identity" without treating it as a sign-out.
    @Published private(set) var lastRestoreError: GatewayAPIError?

    private let client: GatewayAPIClient
    private var idToken: String?
    private var idTokenExpiresAt: Date = .distantPast
    private var refreshToken: String?
    private var refreshTask: Task<GatewaySessionPayload, Error>?

    init(client: GatewayAPIClient = .shared) {
        self.client = client
        refreshToken = Self.decodePersisted()?.refreshToken
        user = Self.decodePersistedUser()
        idTokenExpiresAt = .distantPast
    }

    /// True once the app holds a Gateway session (cached identity or live).
    var hasSession: Bool {
        refreshToken != nil && user != nil
    }

    var uid: String? {
        user?.uid
    }

    /// Restores the session on launch. The cached identity is published first so
    /// an offline launch still shows the account; the network refresh then either
    /// confirms it, keeps it (transport failure), or clears it (session invalid).
    func restoreIfPossible() async {
        guard refreshToken != nil else { return }
        if user == nil {
            user = Self.decodePersistedUser()
        }
        guard user != nil else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            _ = try await validIDToken(forceRefresh: true)
            let me = try await fetchCurrentUser()
            user = me
            persist(user: me)
            lastRestoreError = nil
        } catch let error as GatewayAPIError {
            if error.isSessionInvalid {
                clearLocalSession()
            } else {
                lastRestoreError = error
                AppLogger.network("gateway session restore deferred", error: error)
            }
        } catch {
            lastRestoreError = .invalidResponse
        }
    }

    /// Adopts a session returned by a sign-in / refresh / reauth call.
    func adopt(_ payload: GatewaySessionPayload) {
        refreshToken = payload.refreshToken
        idToken = payload.idToken
        idTokenExpiresAt = Date().addingTimeInterval(TimeInterval(max(payload.expiresIn, 60)))
        user = payload.user
        persist(user: payload.user)
        lastRestoreError = nil
        AuthRouteMemory.lastSuccessfulRoute = .gateway
    }

    func updateUser(_ user: AccountUser) {
        self.user = user
        persist(user: user)
    }

    func clearLocalSession() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        idToken = nil
        idTokenExpiresAt = .distantPast
        user = nil
        lastRestoreError = nil
        GatewayKeychain.delete(account: GatewayKeychain.refreshTokenAccount)
        GatewayKeychain.delete(account: GatewayKeychain.cachedUserAccount)
    }

    // MARK: - Token acquisition

    /// A token usable for an API call. Refreshes when within 90 seconds of
    /// expiry, collapsing concurrent callers into one upstream refresh.
    func validIDToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let idToken, idTokenExpiresAt > Date().addingTimeInterval(90) {
            return idToken
        }
        return try await refreshPayload().idToken
    }

    /// Authenticated request helper: attaches the token, retries once after a
    /// server-side 401 with a forced refresh, and clears the session only when
    /// the server says the session is actually invalid.
    func authorizedSend<T: Decodable & Sendable>(
        _ request: GatewayRequest,
        as type: T.Type = T.self,
        allowStaleTokenRetry: Bool = true
    ) async throws -> T {
        var token = try await validIDToken()
        do {
            return try await send(request, as: type, idToken: token)
        } catch let error as GatewayAPIError {
            if allowStaleTokenRetry, case .server(_, _, let status, _) = error, status == 401 {
                do {
                    token = try await validIDToken(forceRefresh: true)
                    return try await send(request, as: type, idToken: token)
                } catch let second as GatewayAPIError {
                    handle(second)
                    throw second
                }
            }
            handle(error)
            throw error
        }
    }

    func authorizedSendVoid(_ request: GatewayRequest) async throws {
        var token = try await validIDToken()
        do {
            try await send(request, idToken: token)
        } catch let error as GatewayAPIError {
            if case .server(_, _, let status, _) = error, status == 401 {
                do {
                    token = try await validIDToken(forceRefresh: true)
                    try await send(request, idToken: token)
                    return
                } catch let second as GatewayAPIError {
                    handle(second)
                    throw second
                }
            }
            handle(error)
            throw error
        }
    }

    func authorizedSendForData(_ request: GatewayRequest) async throws -> Data {
        var token = try await validIDToken()
        do {
            return try await sendForData(request, idToken: token)
        } catch let error as GatewayAPIError {
            if case .server(_, _, let status, _) = error, status == 401 {
                do {
                    token = try await validIDToken(forceRefresh: true)
                    return try await sendForData(request, idToken: token)
                } catch let second as GatewayAPIError {
                    handle(second)
                    throw second
                }
            }
            handle(error)
            throw error
        }
    }

    private func send<T: Decodable & Sendable>(
        _ request: GatewayRequest,
        as type: T.Type,
        idToken: String
    ) async throws -> T {
        var authenticated = request
        authenticated.authenticated = true
        return try await client.send(authenticated, as: type, idToken: idToken)
    }

    private func send(_ request: GatewayRequest, idToken: String) async throws {
        var authenticated = request
        authenticated.authenticated = true
        try await client.sendVoid(authenticated, idToken: idToken)
    }

    private func sendForData(_ request: GatewayRequest, idToken: String) async throws -> Data {
        var authenticated = request
        authenticated.authenticated = true
        return try await client.sendForData(authenticated, idToken: idToken)
    }

    // MARK: - Refresh

    private func refreshPayload() async throws -> GatewaySessionPayload {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let token = refreshToken else {
            throw GatewaySessionError.noSession
        }
        let client = self.client
        let task = Task<GatewaySessionPayload, Error> {
            let request = try GatewayRequest(method: "POST", path: "/v1/auth/refresh")
                .jsonBody(["refreshToken": token])
            return try await client.send(request, as: GatewaySessionPayload.self)
        }
        refreshTask = task
        do {
            let payload = try await task.value
            adopt(payload)
            refreshTask = nil
            return payload
        } catch let error as GatewayAPIError {
            refreshTask = nil
            handle(error)
            throw error
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func fetchCurrentUser() async throws -> AccountUser {
        struct Response: Decodable { let user: AccountUser }
        let request = GatewayRequest(method: "GET", path: "/v1/account/me")
        let response = try await authorizedSend(request, as: Response.self)
        return response.user
    }

    private func handle(_ error: GatewayAPIError) {
        if error.isSessionInvalid {
            AppLogger.network("gateway session rejected; clearing local session")
            clearLocalSession()
        }
    }

    // MARK: - Persistence

    private func persist(user: AccountUser) {
        guard let refreshToken else { return }
        let record = PersistedGatewaySession(refreshToken: refreshToken, user: user)
        guard let data = try? JSONEncoder().encode(record) else { return }
        _ = GatewayKeychain.save(data, account: GatewayKeychain.refreshTokenAccount)
        if let userData = try? JSONEncoder().encode(user) {
            _ = GatewayKeychain.save(userData, account: GatewayKeychain.cachedUserAccount)
        }
    }

    private static func decodePersisted() -> PersistedGatewaySession? {
        guard let data = GatewayKeychain.load(account: GatewayKeychain.refreshTokenAccount) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedGatewaySession.self, from: data)
    }

    private static func decodePersistedUser() -> AccountUser? {
        guard
            let data = GatewayKeychain.load(account: GatewayKeychain.cachedUserAccount)
        else {
            if let persisted = decodePersisted() { return persisted.user }
            return nil
        }
        return (try? JSONDecoder().decode(AccountUser.self, from: data)) ?? decodePersisted()?.user
    }
}

struct GatewaySessionPayload: Decodable {
    let idToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: AccountUser
}

private struct PersistedGatewaySession: Codable {
    let refreshToken: String
    let user: AccountUser
}
