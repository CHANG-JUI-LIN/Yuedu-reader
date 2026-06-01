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

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var currentAppleNonce: String?

    private init() {
        currentUser = Auth.auth().currentUser
        syncPublishedState(from: currentUser)
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.currentUser = user
                self?.syncPublishedState(from: user)
                GlobalSettings.shared.applyFirebaseUser(user)
                if user != nil {
                    await FirestoreSyncManager.shared.syncAfterSignIn()
                }
            }
        }
    }

    var preparedAppleNonce: String? {
        currentAppleNonce
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleSignInNonce.random()
        currentAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleSignInNonce.sha256(nonce)
    }

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
        try await upsertProfile(for: authResult.user, provider: "Google")
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
        try await upsertProfile(for: authResult.user, provider: "Apple")
        return authResult.user
    }

    @discardableResult
    func signInWithEmail(email: String, password: String) async throws -> User {
        let authResult = try await Auth.auth().signIn(withEmail: email, password: password)
        try await upsertProfile(for: authResult.user, provider: "Email")
        return authResult.user
    }

    @discardableResult
    func signUpWithEmail(email: String, password: String) async throws -> User {
        let authResult = try await Auth.auth().createUser(withEmail: email, password: password)
        try await upsertProfile(for: authResult.user, provider: "Email")
        return authResult.user
    }

    func signOut(revokeGoogleAccess: Bool = false) async throws {
        if revokeGoogleAccess {
            try? await GIDSignIn.sharedInstance.disconnect()
        } else {
            GIDSignIn.sharedInstance.signOut()
        }
        try Auth.auth().signOut()
        GlobalSettings.shared.clearAccountState()
    }

    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthFlowError.missingFirebaseUser
        }
        try await FirestoreSyncManager.shared.deleteRemoteData(uid: user.uid)
        do {
            try await user.delete()
        } catch {
            if AuthErrorCode(_bridgedNSError: error as NSError)?.code == .requiresRecentLogin {
                throw AuthFlowError.requiresRecentLogin
            }
            throw error
        }
        GIDSignIn.sharedInstance.signOut()
        GlobalSettings.shared.clearAccountState()
    }

    func upsertProfile(for user: User, provider: String) async throws {
        GlobalSettings.shared.applyFirebaseUser(user, providerOverride: provider)
        try await FirestoreSyncManager.shared.upsertCurrentProfile(provider: provider)
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
    case requiresRecentLogin

    var errorDescription: String? {
        switch self {
        case .missingGoogleIDToken:
            return localized("Google 登入缺少身份憑證")
        case .missingAppleNonce:
            return localized("Apple 登入安全驗證失敗")
        case .missingAppleIDToken:
            return localized("Apple 登入缺少身份憑證")
        case .missingFirebaseUser:
            return localized("目前沒有已登入的 Firebase 帳號")
        case .requiresRecentLogin:
            return localized("為了保護帳號安全，請重新登入後再刪除帳號")
        }
    }
}
