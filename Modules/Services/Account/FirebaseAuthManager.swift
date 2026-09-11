import AuthenticationServices
import Combine
import FirebaseAuth
import Foundation
import GoogleSignIn
import UIKit

/// Route-neutral auth facade. Owns exactly one live session at a time: either
/// the Firebase SDK session (direct route) or the Gateway session (relay
/// route). UI and services read `accountUser`; nothing outside this file should
/// treat `FirebaseAuth.User` as the account model.
@MainActor
final class FirebaseAuthManager: ObservableObject {
    static let shared = FirebaseAuthManager()

    /// Route-neutral account. Non-nil == signed in, on either route.
    @Published private(set) var accountUser: AccountUser?
    /// SDK user, populated only while the direct route is active. Kept for the
    /// Firebase-only operations (link/unlink/reauth) performed in-process.
    @Published private(set) var currentUser: User?
    @Published private(set) var uid: String?
    @Published private(set) var isAuthenticated = false
    /// Which route backs the current session. Nil when signed out.
    @Published private(set) var activeRoute: AuthRoute?
    /// True when a link attempt failed because the identity already belongs to a
    /// different account, so the UI can offer to sign into that account instead.
    @Published private(set) var hasPendingSignInCredential = false

    /// Provider IDs already linked to the current account, e.g. ["google.com", "apple.com", "password"].
    var linkedProviderIDs: [String] {
        accountUser?.providerIds ?? []
    }

    /// An account must keep at least one way in, so the last provider can't be removed.
    var canUnlinkProvider: Bool {
        linkedProviderIDs.count > 1
    }

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var currentAppleNonce: String?
    private var appleReauthCoordinator: AppleReauthCoordinator?
    private var pendingSignInCredential: AuthCredential?
    /// Pending credential produced by a failed Gateway link, used to sign into
    /// the owning account on the same route.
    private var pendingGatewayToken: String?

    private let gateway = GatewayAuthProvider.shared
    private let gatewayStore = GatewaySessionStore.shared

    private init() {
        currentUser = Auth.auth().currentUser

        if !GatewayConfiguration.isConfigured, gatewayStore.hasSession {
            // This build has no relay entry point (the normal case until an
            // HTTPS host is verified). A session cached by another build must
            // not make account traffic route into a service that does not exist.
            gatewayStore.clearLocalSession()
        }

        if GatewayConfiguration.isConfigured, gatewayStore.hasSession, let cached = gatewayStore.user {
            // A persisted Gateway session outranks a leftover SDK session: it is
            // the only route that carries a refresh token for this install.
            apply(cached, route: .gateway)
            signSDKOutOfGateway()
            Task { await restoreGatewaySession() }
        } else if let sdkUser = currentUser {
            apply(AccountUser(firebaseUser: sdkUser), route: .direct)
        } else {
            apply(nil, route: nil)
        }

        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                // The Gateway owns the session in this mode. A leftover SDK user
                // (or an SDK sign-out triggered while adopting the Gateway) must
                // never overwrite the Gateway account with nil.
                if self.activeRoute == .gateway {
                    if user != nil {
                        self.signSDKOutOfGateway()
                    }
                    return
                }
                self.currentUser = user
                guard let user else {
                    self.apply(nil, route: nil)
                    await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: false)
                    return
                }
                self.apply(AccountUser(firebaseUser: user), route: .direct)
                AuthRouteMemory.lastSuccessfulRoute = .direct
                await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: true)
                await FirestoreSyncManager.shared.syncAfterSignIn()
            }
        }
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleSignInNonce.random()
        currentAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleSignInNonce.sha256(nonce)
    }

    // MARK: - Sign in

    @discardableResult
    func signInWithGoogle(presenting rootViewController: UIViewController) async throws -> AccountUser {
        try await performAccountOperation(operation: .signInWithGoogle) { route in
            switch route {
            case .direct:
                return try await self.performDirectGoogleSignIn(presenting: rootViewController)
            case .gateway:
                let tokens = try await self.requestGoogleIDTokens(presenting: rootViewController)
                let user = try await self.gateway.signInWithGoogle(
                    idToken: tokens.idToken,
                    accessToken: tokens.accessToken
                )
                self.adoptGatewayUser(user)
                return user
            }
        }
    }

    @discardableResult
    func signInWithApple(credential appleCredential: ASAuthorizationAppleIDCredential) async throws -> AccountUser {
        guard let nonce = currentAppleNonce else {
            throw AuthFlowError.missingAppleNonce
        }
        currentAppleNonce = nil

        guard let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthFlowError.missingAppleIDToken
        }

        return try await performAccountOperation(operation: .signInWithApple) { route in
            switch route {
            case .direct:
                let credential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: appleCredential.fullName
                )
                let authResult = try await Auth.auth().signIn(with: credential)
                // Apple only returns the name on the very first authorization; persist it onto
                // the Firebase profile so it survives future logins.
                if (authResult.user.displayName ?? "").isEmpty, let fullName = appleCredential.fullName {
                    let formatted = PersonNameComponentsFormatter().string(from: fullName)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !formatted.isEmpty {
                        let change = authResult.user.createProfileChangeRequest()
                        change.displayName = formatted
                        try? await change.commitChanges()
                    }
                }
                return AccountUser(firebaseUser: authResult.user)
            case .gateway:
                let user = try await self.gateway.signInWithApple(
                    idToken: idToken,
                    rawNonce: nonce,
                    fullName: appleCredential.fullName
                )
                self.adoptGatewayUser(user)
                return user
            }
        }
    }

    @discardableResult
    func signInWithEmail(email: String, password: String) async throws -> AccountUser {
        try await performAccountOperation(operation: .signInWithEmail) { route in
            switch route {
            case .direct:
                let authResult = try await Auth.auth().signIn(withEmail: email, password: password)
                return AccountUser(firebaseUser: authResult.user)
            case .gateway:
                let user = try await self.gateway.signInWithEmail(email: email, password: password)
                self.adoptGatewayUser(user)
                return user
            }
        }
    }

    @discardableResult
    func signUpWithEmail(email: String, password: String) async throws -> AccountUser {
        // Registration has a side effect; it is never retried on a second route.
        try await performAccountOperation(operation: .signUpWithEmail) { route in
            switch route {
            case .direct:
                let authResult = try await Auth.auth().createUser(withEmail: email, password: password)
                return AccountUser(firebaseUser: authResult.user)
            case .gateway:
                let user = try await self.gateway.signUpWithEmail(email: email, password: password)
                self.adoptGatewayUser(user)
                return user
            }
        }
    }

    // MARK: - Account linking

    /// Links a Google identity to the currently signed-in account (same uid).
    func linkGoogle() async throws {
        let route = activeRoute ?? resolveRoute()
        do {
            switch route {
            case .direct:
                guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
                let tokens = try await requestGoogleIDTokens(presenting: try topViewController())
                let credential = GoogleAuthProvider.credential(
                    withIDToken: tokens.idToken,
                    accessToken: tokens.accessToken
                )
                try await link(user, with: credential)
            case .gateway:
                let tokens = try await requestGoogleIDTokens(presenting: try topViewController())
                do {
                    try await gateway.linkGoogle(idToken: tokens.idToken, accessToken: tokens.accessToken)
                } catch let error as GatewayAPIError where error.requiresRecentAuth {
                    throw AuthFlowError.requiresRecentLogin
                }
                try await refreshGatewayAccount()
            }
        } catch let error as AuthFlowError {
            throw error
        } catch {
            try mapGatewayLinkingError(error)
        }
    }

    /// Links an Apple identity to the currently signed-in account (same uid).
    func linkApple() async throws {
        let nonce = AppleSignInNonce.random()
        let coordinator = AppleReauthCoordinator()
        appleReauthCoordinator = coordinator
        defer { appleReauthCoordinator = nil }

        let appleCredential = try await coordinator.requestCredential(nonceSHA256: AppleSignInNonce.sha256(nonce))
        guard let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthFlowError.missingAppleIDToken
        }

        let route = activeRoute ?? resolveRoute()
        do {
            switch route {
            case .direct:
                guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
                let credential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: appleCredential.fullName
                )
                try await link(user, with: credential)
            case .gateway:
                do {
                    try await gateway.linkApple(idToken: idToken, rawNonce: nonce)
                } catch let error as GatewayAPIError where error.requiresRecentAuth {
                    // The Apple credential is already in hand; the provider
                    // re-verifies it to mint a fresh token before retrying.
                    throw AuthFlowError.requiresRecentLogin
                }
                try await refreshGatewayAccount()
            }
        } catch let error as AuthFlowError {
            throw error
        } catch {
            try mapGatewayLinkingError(error)
        }
    }

    /// Links an email/password identity to the currently signed-in account (same uid).
    func linkEmail(email: String, password: String) async throws {
        let route = activeRoute ?? resolveRoute()
        do {
            switch route {
            case .direct:
                guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
                let credential = EmailAuthProvider.credential(withEmail: email, password: password)
                try await link(user, with: credential)
            case .gateway:
                do {
                    try await gateway.linkEmail(email: email, password: password)
                } catch let error as GatewayAPIError where error.requiresRecentAuth {
                    throw AuthFlowError.requiresRecentLogin
                }
                try await refreshGatewayAccount()
            }
        } catch let error as AuthFlowError {
            throw error
        } catch {
            try mapGatewayLinkingError(error)
        }
    }

    private func link(_ user: User, with credential: AuthCredential) async throws {
        do {
            let result = try await user.link(with: credential)
            clearPendingSignInCredential()
            currentUser = result.user
            apply(AccountUser(firebaseUser: result.user), route: .direct)
        } catch {
            let nsError = error as NSError
            switch nsError.code {
            case AuthErrorCode.credentialAlreadyInUse.rawValue:
                // Firebase hands back a refreshed credential for the account that owns
                // this identity; keeping it lets the user switch to that account instead
                // of dead-ending on "already linked" with no way forward.
                pendingSignInCredential = nsError.userInfo[AuthErrorUserInfoUpdatedCredentialKey]
                    as? AuthCredential ?? credential
                hasPendingSignInCredential = true
                throw AuthFlowError.providerLinkedToAnotherAccount
            case AuthErrorCode.emailAlreadyInUse.rawValue, AuthErrorCode.providerAlreadyLinked.rawValue:
                throw AuthFlowError.providerAlreadyLinked
            default:
                throw error
            }
        }
    }

    /// Removes one sign-in method from the current account (same uid, one fewer provider).
    func unlink(providerID: String) async throws {
        let route = activeRoute ?? resolveRoute()
        switch route {
        case .direct:
            guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
            guard user.providerData.count > 1 else { throw AuthFlowError.cannotUnlinkLastProvider }
            let updated = try await user.unlink(fromProvider: providerID)
            currentUser = updated
            apply(AccountUser(firebaseUser: updated), route: .direct)
        case .gateway:
            do {
                let user = try await gateway.unlink(providerID: providerID)
                apply(user, route: .gateway)
            } catch let error as GatewayAPIError {
                switch error.serverCode {
                case "cannot-unlink-last-provider":
                    throw AuthFlowError.cannotUnlinkLastProvider
                case "reauth-required":
                    throw AuthFlowError.requiresRecentLogin
                default:
                    throw error
                }
            }
        }
    }

    /// Signs into the account that already owns the credential a link attempt rejected.
    /// Books and settings live in iCloud per device, so switching accounts here only
    /// changes which identity the profile syncs under.
    @discardableResult
    func signInWithPendingCredential() async throws -> AccountUser {
        if let pendingGatewayToken {
            clearPendingSignInCredential()
            // The profile fingerprint / createdAt caches in UserDefaults are per device,
            // not per uid: without this reset the new account's first profile push is
            // skipped as an unchanged write.
            FirestoreSyncManager.shared.resetLocalSyncState()
            let user = try await gateway.signInWithPendingToken(pendingGatewayToken)
            adoptGatewayUser(user)
            return user
        }

        guard let credential = pendingSignInCredential else {
            throw AuthFlowError.missingPendingCredential
        }
        clearPendingSignInCredential()
        FirestoreSyncManager.shared.resetLocalSyncState()
        let result = try await Auth.auth().signIn(with: credential)
        return AccountUser(firebaseUser: result.user)
    }

    func clearPendingSignInCredential() {
        pendingSignInCredential = nil
        pendingGatewayToken = nil
        hasPendingSignInCredential = false
    }

    // MARK: - Sign out / delete

    func signOut(revokeGoogleAccess: Bool = false) async throws {
        if revokeGoogleAccess {
            try? await GIDSignIn.sharedInstance.disconnect()
        } else {
            GIDSignIn.sharedInstance.signOut()
        }

        if activeRoute == .gateway {
            await gateway.logout()
            FirestoreSyncManager.shared.resetLocalSyncState()
            apply(nil, route: nil)
            await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: false)
            return
        }

        try Auth.auth().signOut()
        gatewayStore.clearLocalSession()
        FirestoreSyncManager.shared.resetLocalSyncState()
        apply(nil, route: nil)
    }

    /// Deletes the account, in the only order that cannot strand data: re-authenticate
    /// (interactive for Google/Apple, password for Email) → clear the user-owned cloud
    /// documents while the credentials that may delete them still exist → revoke the
    /// Apple token → delete the auth user last.
    func deleteAccount(emailPassword: String? = nil) async throws {
        if activeRoute == .gateway {
            try await deleteGatewayAccount(emailPassword: emailPassword)
            return
        }

        guard let user = Auth.auth().currentUser else {
            throw AuthFlowError.missingFirebaseUser
        }
        let uid = user.uid
        let appleAuthorizationCode = try await reauthenticate(user, emailPassword: emailPassword)

        // Subscription bookkeeping lives in a callable Cloud Function. Its documents are
        // keyed by uid, server-owned and invisible in the app, so losing that cleanup only
        // leaves dead rows — while letting it throw here aborts the whole deletion, which
        // App Store guideline 5.1.1(v) requires to work from inside the app. Real case it
        // guards: the callables are not deployed to the project, so every delete failed at
        // this line. Delete this catch once subscription cleanup runs from an
        // `auth.user().onDelete` trigger instead of a client call.
        do {
            try await SubscriptionStore.shared.deleteCurrentAccountSubscriptionData()
        } catch {
            AppLogger.error("⟐ account-delete subscription cleanup failed", error: error, context: ["uid": uid])
        }

        // This one must block: the Firestore rules only let the owner delete these
        // documents, so dropping the auth user first would strand the profile forever.
        try await FirestoreSyncManager.shared.deleteRemoteData(uid: uid)

        // Sign in with Apple requires the app to revoke the token when the user deletes
        // their account (App Store guideline 5.1.1(v)); it has to happen while the auth
        // user still exists.
        if let appleAuthorizationCode {
            do {
                try await Auth.auth().revokeToken(withAuthorizationCode: appleAuthorizationCode)
            } catch {
                AppLogger.error("⟐ account-delete apple token revoke failed", error: error, context: ["uid": uid])
            }
        }

        do {
            try await user.delete()
        } catch {
            if (error as NSError).code == AuthErrorCode.requiresRecentLogin.rawValue {
                throw AuthFlowError.requiresRecentLogin
            }
            throw error
        }
        GIDSignIn.sharedInstance.signOut()
        FirestoreSyncManager.shared.resetLocalSyncState()
        apply(nil, route: nil)
    }

    /// Gateway deletion: one server call verifies the credential, cleans
    /// server-owned data first and removes the Auth user last. A partial failure
    /// is recorded server-side and can be retried with a fresh credential.
    private func deleteGatewayAccount(emailPassword: String?) async throws {
        guard let account = accountUser else {
            throw AuthFlowError.missingFirebaseUser
        }
        let reauth: GatewayReauth
        switch preferredReauthProviderID(for: account.providerIds) {
        case "google.com":
            let tokens = try await requestGoogleIDTokens(presenting: try topViewController())
            reauth = .google(idToken: tokens.idToken, accessToken: tokens.accessToken)
        case "apple.com":
            let apple = try await appleReauthCredential()
            reauth = .apple(
                idToken: apple.idToken,
                rawNonce: apple.rawNonce,
                authorizationCode: apple.authorizationCode
            )
        case "password":
            guard let emailPassword, !emailPassword.isEmpty else {
                throw AuthFlowError.requiresPassword
            }
            reauth = .password(emailPassword)
        default:
            throw AuthFlowError.missingFirebaseUser
        }

        do {
            try await gateway.deleteAccount(reauth: reauth)
        } catch let error as GatewayAPIError {
            switch error.serverCode {
            case "reauth-required", "invalid-credentials":
                throw AuthFlowError.requiresRecentLogin
            default:
                throw error
            }
        }
        GIDSignIn.sharedInstance.signOut()
        FirestoreSyncManager.shared.resetLocalSyncState()
        apply(nil, route: nil)
        await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: false)
    }

    /// Whether deletion needs a password prompt before it can proceed.
    var deletionRequiresPassword: Bool {
        guard let account = accountUser else { return false }
        return preferredReauthProviderID(for: account.providerIds) == "password"
    }

    // MARK: - Routing

    /// Resolves the route from persisted mode + memory + a regional hint. Never
    /// from Remote Config: that would require the very connection being fixed.
    func resolveRoute() -> AuthRoute {
        let decision = AuthRoutePolicy.decide(
            mode: GlobalSettings.shared.authRouteMode,
            gatewayConfigured: GatewayConfiguration.isConfigured,
            lastSuccessfulRoute: AuthRouteMemory.lastSuccessfulRoute,
            regionHintIsMainland: AuthRoutePolicy.regionHintIsMainland()
        )
        return decision.route
    }

    /// Runs an operation on the resolved route, retrying once on the other route
    /// only when the operation is idempotent and the failure is connectivity.
    /// Credential errors (wrong password, disabled account) never switch routes.
    private func performAccountOperation(
        operation: AccountOperation,
        _ body: (AuthRoute) async throws -> AccountUser
    ) async throws -> AccountUser {
        let route = resolveRoute()
        AppLogger.network("auth route selected: \(route.rawValue)")
        do {
            let user = try await body(route)
            adoptIfDirect(user, route: route)
            return user
        } catch {
            guard
                AuthRouteFallbackPolicy.allowsAutomaticRouteSwitch(operation: operation),
                isConnectivityError(error)
            else {
                throw error
            }
            let alternate: AuthRoute = route == .direct ? .gateway : .direct
            guard alternate == .direct || GatewayConfiguration.isConfigured else {
                throw error
            }
            AppLogger.network("auth route \(route.rawValue) unreachable; retrying once on \(alternate.rawValue)")
            let user = try await body(alternate)
            adoptIfDirect(user, route: alternate)
            AuthRouteMemory.lastSuccessfulRoute = alternate
            return user
        }
    }

    /// Direct-route sign-ins complete through the SDK listener; the result here
    /// just makes sure the published model is current even before the listener
    /// hops to the main actor.
    private func adoptIfDirect(_ user: AccountUser, route: AuthRoute) {
        guard route == .direct else { return }
        currentUser = Auth.auth().currentUser
        apply(user, route: .direct)
    }

    private func adoptGatewayUser(_ user: AccountUser) {
        apply(user, route: .gateway)
        signSDKOutOfGateway()
        AuthRouteMemory.lastSuccessfulRoute = .gateway
        Task {
            await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: true)
            await FirestoreSyncManager.shared.syncAfterSignIn()
        }
    }

    private func refreshGatewayAccount() async throws {
        _ = try await gateway.refreshSession()
        if let user = gatewayStore.user {
            apply(user, route: .gateway)
        }
    }

    /// Restores a persisted Gateway session on launch.
    private func restoreGatewaySession() async {
        guard GatewayConfiguration.isConfigured else { return }
        await gatewayStore.restoreIfPossible()
        guard gatewayStore.hasSession, let user = gatewayStore.user else {
            // Only an explicit invalid-session answer clears the store; a
            // transport failure keeps the cached identity above.
            if !gatewayStore.hasSession {
                apply(nil, route: nil)
                await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: false)
            }
            return
        }
        apply(user, route: .gateway)
        await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: true)
        await FirestoreSyncManager.shared.syncAfterSignIn()
    }

    private func signSDKOutOfGateway() {
        if Auth.auth().currentUser != nil {
            try? Auth.auth().signOut()
        }
    }

    private func apply(_ user: AccountUser?, route: AuthRoute?) {
        accountUser = user
        activeRoute = user == nil ? nil : route
        uid = user?.uid
        isAuthenticated = user != nil
        GlobalSettings.shared.applyAccountUser(user)
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        if let gatewayError = error as? GatewayAPIError {
            return gatewayError.isConnectivityFailure
        }
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain {
            return nsError.code == AuthErrorCode.networkError.rawValue
                || nsError.code == AuthErrorCode.webNetworkRequestFailed.rawValue
        }
        return nsError.domain == NSURLErrorDomain
    }

    private func mapGatewayLinkingError(_ error: Error) throws -> Never {
        guard let gatewayError = error as? GatewayAPIError else { throw error }
        switch gatewayError.serverCode {
        case "provider-already-linked", "email-exists":
            throw AuthFlowError.providerAlreadyLinked
        case "credential-already-in-use":
            if let pending = gatewayError.details["pendingToken"] as? String, !pending.isEmpty {
                pendingGatewayToken = pending
                hasPendingSignInCredential = true
            }
            throw AuthFlowError.providerLinkedToAnotherAccount
        case "reauth-required":
            throw AuthFlowError.requiresRecentLogin
        case "cannot-unlink-last-provider":
            throw AuthFlowError.cannotUnlinkLastProvider
        default:
            throw gatewayError
        }
    }

    // MARK: - Re-authentication

    /// Re-auth prefers a federated provider: it is one system prompt with nothing to
    /// type, and Apple additionally hands back the authorization code needed to revoke
    /// the token on deletion. `providerData.first` is not a usable choice — the order is
    /// server-defined, so an account with several providers linked could be asked for a
    /// password while its interactive providers sat unused.
    private func preferredReauthProviderID(for providerIds: [String]) -> String? {
        let linked = Set(providerIds)
        for candidate in ["apple.com", "google.com", "password"] where linked.contains(candidate) {
            return candidate
        }
        return providerIds.first
    }

    /// Returns the Apple authorization code when re-auth went through Apple, so the
    /// caller can revoke the token before deleting the user.
    @discardableResult
    private func reauthenticate(_ user: User, emailPassword: String?) async throws -> String? {
        switch preferredReauthProviderID(for: user.providerData.map(\.providerID)) {
        case "google.com":
            let credential = try await googleReauthCredential()
            try await user.reauthenticate(with: credential)
            return nil
        case "apple.com":
            let reauth = try await appleReauthCredential()
            try await user.reauthenticate(with: reauth.credential)
            return reauth.authorizationCode
        case "password":
            guard let email = user.email, let password = emailPassword, !password.isEmpty else {
                throw AuthFlowError.requiresPassword
            }
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            try await user.reauthenticate(with: credential)
            return nil
        default:
            return nil
        }
    }

    private func googleReauthCredential() async throws -> AuthCredential {
        let tokens = try await requestGoogleIDTokens(presenting: try topViewController())
        return GoogleAuthProvider.credential(
            withIDToken: tokens.idToken,
            accessToken: tokens.accessToken
        )
    }

    private struct GoogleIDTokens {
        let idToken: String
        let accessToken: String
    }

    private func requestGoogleIDTokens(presenting presenter: UIViewController) async throws -> GoogleIDTokens {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthFlowError.missingGoogleIDToken
        }
        return GoogleIDTokens(idToken: idToken, accessToken: result.user.accessToken.tokenString)
    }

    private func performDirectGoogleSignIn(presenting presenter: UIViewController) async throws -> AccountUser {
        let tokens = try await requestGoogleIDTokens(presenting: presenter)
        let credential = GoogleAuthProvider.credential(
            withIDToken: tokens.idToken,
            accessToken: tokens.accessToken
        )
        let authResult = try await Auth.auth().signIn(with: credential)
        return AccountUser(firebaseUser: authResult.user)
    }

    private struct AppleReauth {
        let credential: AuthCredential
        let authorizationCode: String?
        let rawNonce: String
        let idToken: String
    }

    private func appleReauthCredential() async throws -> AppleReauth {
        let nonce = AppleSignInNonce.random()
        let coordinator = AppleReauthCoordinator()
        appleReauthCoordinator = coordinator
        defer { appleReauthCoordinator = nil }

        let appleCredential = try await coordinator.requestCredential(nonceSHA256: AppleSignInNonce.sha256(nonce))
        guard let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthFlowError.missingAppleIDToken
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: appleCredential.fullName
        )
        let authorizationCode = appleCredential.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }
        return AppleReauth(
            credential: credential,
            authorizationCode: authorizationCode,
            rawNonce: nonce,
            idToken: idToken
        )
    }

    private func topViewController() throws -> UIViewController {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard var top = (scene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            throw AuthFlowError.missingPresenter
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

enum AuthFlowError: LocalizedError {
    case missingGoogleIDToken
    case missingAppleNonce
    case missingAppleIDToken
    case missingFirebaseUser
    case missingPresenter
    case missingPendingCredential
    case pendingGatewayCredential(String)
    case requiresRecentLogin
    case requiresPassword
    case providerAlreadyLinked
    case providerLinkedToAnotherAccount
    case cannotUnlinkLastProvider

    var errorDescription: String? {
        switch self {
        case .missingGoogleIDToken:
            return localized("Google 登入缺少身份憑證")
        case .missingAppleNonce:
            return localized("Apple 登入安全驗證失敗")
        case .missingAppleIDToken:
            return localized("Apple 登入缺少身份憑證")
        case .missingFirebaseUser:
            return localized("目前沒有已登入的帳號")
        case .missingPresenter:
            return localized("無法取得登入視窗")
        case .missingPendingCredential:
            return localized("連結資訊已失效，請重新操作")
        case .pendingGatewayCredential:
            return localized("此登入方式屬於另一個帳號。你可以改用它登入那個帳號，或先在那個帳號解除連結。")
        case .requiresRecentLogin:
            return localized("為了保護帳號安全，請重新登入後再試")
        case .requiresPassword:
            return localized("請輸入密碼以確認刪除帳號")
        case .providerAlreadyLinked:
            return localized("此登入方式已綁定其他帳號，無法連結")
        case .providerLinkedToAnotherAccount:
            return localized("此登入方式屬於另一個帳號。你可以改用它登入那個帳號，或先在那個帳號解除連結。")
        case .cannotUnlinkLastProvider:
            return localized("這是唯一的登入方式，解除後就無法再登入，請先連結另一種方式")
        }
    }
}
