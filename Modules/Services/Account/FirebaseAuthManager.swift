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

    /// Provider IDs already linked to the current account, e.g. ["google.com", "apple.com", "password"].
    var linkedProviderIDs: [String] {
        currentUser?.providerData.map(\.providerID) ?? []
    }

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var currentAppleNonce: String?
    private var appleReauthCoordinator: AppleReauthCoordinator?

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
            currentUser = result.user
            syncPublishedState(from: result.user)
            GlobalSettings.shared.applyFirebaseUser(result.user)
        } catch {
            let code = (error as NSError).code
            if code == AuthErrorCode.credentialAlreadyInUse.rawValue
                || code == AuthErrorCode.emailAlreadyInUse.rawValue
                || code == AuthErrorCode.providerAlreadyLinked.rawValue {
                throw AuthFlowError.providerAlreadyLinked
            }
            throw error
        }
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

    /// Deletes the account. Re-authenticates first (interactive for Google/Apple,
    /// password for Email) so we never wipe cloud data and then fail to delete the
    /// auth user, leaving a half-deleted account.
    func deleteAccount(emailPassword: String? = nil) async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthFlowError.missingFirebaseUser
        }
        try await reauthenticate(user, emailPassword: emailPassword)
        try await SubscriptionStore.shared.deleteCurrentAccountSubscriptionData()
        try await FirestoreSyncManager.shared.deleteRemoteData(uid: user.uid)
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
        currentUser?.providerData.first?.providerID == "password"
    }

    // MARK: - Re-authentication

    private func reauthenticate(_ user: User, emailPassword: String?) async throws {
        switch user.providerData.first?.providerID {
        case "google.com":
            let credential = try await googleReauthCredential()
            try await user.reauthenticate(with: credential)
        case "apple.com":
            let credential = try await appleReauthCredential()
            try await user.reauthenticate(with: credential)
        case "password":
            guard let email = user.email, let password = emailPassword, !password.isEmpty else {
                throw AuthFlowError.requiresPassword
            }
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            try await user.reauthenticate(with: credential)
        default:
            break
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

    private func appleReauthCredential() async throws -> AuthCredential {
        let nonce = AppleSignInNonce.random()
        let coordinator = AppleReauthCoordinator()
        appleReauthCoordinator = coordinator
        defer { appleReauthCoordinator = nil }

        let appleCredential = try await coordinator.requestCredential(nonceSHA256: AppleSignInNonce.sha256(nonce))
        guard let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthFlowError.missingAppleIDToken
        }
        return OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: appleCredential.fullName
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

    private func syncPublishedState(from user: User?) {
        uid = user?.uid
        isAuthenticated = user != nil
    }
}

enum AuthFlowError: LocalizedError {
    case missingGoogleIDToken
    case missingAppleNonce
    case missingAppleIDToken
    case missingFirebaseUser
    case missingPresenter
    case requiresRecentLogin
    case requiresPassword
    case providerAlreadyLinked

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
        case .requiresRecentLogin:
            return localized("為了保護帳號安全，請重新登入後再刪除帳號")
        case .requiresPassword:
            return localized("請輸入密碼以確認刪除帳號")
        case .providerAlreadyLinked:
            return localized("此登入方式已綁定其他帳號，無法連結")
        }
    }
}
