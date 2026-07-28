import AuthenticationServices
import Combine
import FirebaseAuth
import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class FirebaseAuthManager: ObservableObject {
    static let shared = FirebaseAuthManager()

    @Published private(set) var currentUser: User?
    @Published private(set) var uid: String?
    @Published private(set) var isAuthenticated = false
    /// True when a link attempt failed because the identity already belongs to a
    /// different account, so the UI can offer to sign into that account instead.
    @Published private(set) var hasPendingSignInCredential = false

    /// Provider IDs already linked to the current account, e.g. ["google.com", "apple.com", "password"].
    var linkedProviderIDs: [String] {
        currentUser?.providerData.map(\.providerID) ?? []
    }

    /// An account must keep at least one way in, so the last provider can't be removed.
    var canUnlinkProvider: Bool {
        linkedProviderIDs.count > 1
    }

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var currentAppleNonce: String?
    private var appleReauthCoordinator: AppleReauthCoordinator?
    private var pendingSignInCredential: AuthCredential?

    private init() {
        currentUser = Auth.auth().currentUser
        syncPublishedState(from: currentUser)
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.currentUser = user
                self?.syncPublishedState(from: user)
                GlobalSettings.shared.applyFirebaseUser(user)
                await SubscriptionStore.shared.authenticationDidChange(isAuthenticated: user != nil)
                if user != nil {
                    await FirestoreSyncManager.shared.syncAfterSignIn()
                }
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
    func signInWithGoogle(presenting rootViewController: UIViewController) async throws -> User {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthFlowError.missingGoogleIDToken
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        let authResult = try await Auth.auth().signIn(with: credential)
        GlobalSettings.shared.applyFirebaseUser(authResult.user, providerOverride: "Google")
        return authResult.user
    }

    @discardableResult
    func signInWithApple(credential appleCredential: ASAuthorizationAppleIDCredential) async throws -> User {
        guard let nonce = currentAppleNonce else {
            throw AuthFlowError.missingAppleNonce
        }
        currentAppleNonce = nil

        guard let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthFlowError.missingAppleIDToken
        }

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

        GlobalSettings.shared.applyFirebaseUser(authResult.user, providerOverride: "Apple")
        return authResult.user
    }

    @discardableResult
    func signInWithEmail(email: String, password: String) async throws -> User {
        let authResult = try await Auth.auth().signIn(withEmail: email, password: password)
        GlobalSettings.shared.applyFirebaseUser(authResult.user, providerOverride: "Email")
        return authResult.user
    }

    @discardableResult
    func signUpWithEmail(email: String, password: String) async throws -> User {
        let authResult = try await Auth.auth().createUser(withEmail: email, password: password)
        GlobalSettings.shared.applyFirebaseUser(authResult.user, providerOverride: "Email")
        return authResult.user
    }

    // MARK: - Account linking

    /// Links a Google identity to the currently signed-in account (same uid).
    func linkGoogle() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: try topViewController())
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthFlowError.missingGoogleIDToken
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await link(user, with: credential)
    }

    /// Links an Apple identity to the currently signed-in account (same uid).
    func linkApple() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
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
        try await link(user, with: credential)
    }

    /// Links an email/password identity to the currently signed-in account (same uid).
    func linkEmail(email: String, password: String) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await link(user, with: credential)
    }

    private func link(_ user: User, with credential: AuthCredential) async throws {
        do {
            let result = try await user.link(with: credential)
            clearPendingSignInCredential()
            currentUser = result.user
            syncPublishedState(from: result.user)
            GlobalSettings.shared.applyFirebaseUser(result.user)
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
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.missingFirebaseUser }
        guard user.providerData.count > 1 else { throw AuthFlowError.cannotUnlinkLastProvider }
        let updated = try await user.unlink(fromProvider: providerID)
        currentUser = updated
        syncPublishedState(from: updated)
        GlobalSettings.shared.applyFirebaseUser(updated)
    }

    /// Signs into the account that already owns the credential a link attempt rejected.
    /// Books and settings live in iCloud per device, so switching accounts here only
    /// changes which identity the profile syncs under.
    @discardableResult
    func signInWithPendingCredential() async throws -> User {
        guard let credential = pendingSignInCredential else {
            throw AuthFlowError.missingPendingCredential
        }
        clearPendingSignInCredential()
        // The profile fingerprint / createdAt caches in UserDefaults are per device,
        // not per uid: without this reset the new account's first profile push is
        // skipped as an unchanged write.
        FirestoreSyncManager.shared.resetLocalSyncState()
        let result = try await Auth.auth().signIn(with: credential)
        GlobalSettings.shared.applyFirebaseUser(result.user)
        return result.user
    }

    func clearPendingSignInCredential() {
        pendingSignInCredential = nil
        hasPendingSignInCredential = false
    }

    // MARK: - Sign out / delete

    func signOut(revokeGoogleAccess: Bool = false) async throws {
        if revokeGoogleAccess {
            try? await GIDSignIn.sharedInstance.disconnect()
        } else {
            GIDSignIn.sharedInstance.signOut()
        }
        try Auth.auth().signOut()
        FirestoreSyncManager.shared.resetLocalSyncState()
        GlobalSettings.shared.clearAccountState()
    }

    /// Deletes the account, in the only order that cannot strand data: re-authenticate
    /// (interactive for Google/Apple, password for Email) → clear the user-owned cloud
    /// documents while the credentials that may delete them still exist → revoke the
    /// Apple token → delete the auth user last.
    func deleteAccount(emailPassword: String? = nil) async throws {
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
        GlobalSettings.shared.clearAccountState()
    }

    /// Whether deletion needs a password prompt before it can proceed.
    var deletionRequiresPassword: Bool {
        guard let user = currentUser else { return false }
        return preferredReauthProviderID(for: user) == "password"
    }

    // MARK: - Re-authentication

    /// Re-auth prefers a federated provider: it is one system prompt with nothing to
    /// type, and Apple additionally hands back the authorization code needed to revoke
    /// the token on deletion. `providerData.first` is not a usable choice — the order is
    /// server-defined, so an account with several providers linked could be asked for a
    /// password while its interactive providers sat unused.
    private func preferredReauthProviderID(for user: User) -> String? {
        let linked = Set(user.providerData.map(\.providerID))
        for candidate in ["apple.com", "google.com", "password"] where linked.contains(candidate) {
            return candidate
        }
        return user.providerData.first?.providerID
    }

    /// Returns the Apple authorization code when re-auth went through Apple, so the
    /// caller can revoke the token before deleting the user.
    @discardableResult
    private func reauthenticate(_ user: User, emailPassword: String?) async throws -> String? {
        switch preferredReauthProviderID(for: user) {
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
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: try topViewController())
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthFlowError.missingGoogleIDToken
        }
        return GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
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
        return AppleReauth(credential: credential, authorizationCode: authorizationCode)
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

    private func syncPublishedState(from user: User?) {
        uid = user?.uid
        isAuthenticated = user != nil
    }

    /// Apple re-auth result: the Firebase credential plus the one-shot authorization
    /// code that `Auth.revokeToken(withAuthorizationCode:)` needs.
    private struct AppleReauth {
        let credential: AuthCredential
        let authorizationCode: String?
    }
}

enum AuthFlowError: LocalizedError {
    case missingGoogleIDToken
    case missingAppleNonce
    case missingAppleIDToken
    case missingFirebaseUser
    case missingPresenter
    case missingPendingCredential
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
        case .requiresRecentLogin:
            return localized("為了保護帳號安全，請重新登入後再刪除帳號")
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
