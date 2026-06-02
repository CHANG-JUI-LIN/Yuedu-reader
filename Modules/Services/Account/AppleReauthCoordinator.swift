import AuthenticationServices
import UIKit

/// Drives a native "Sign in with Apple" prompt purely to obtain a fresh credential
/// for `user.reauthenticate(...)` (required before deleting the account).
@MainActor
final class AppleReauthCoordinator: NSObject {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func requestCredential(nonceSHA256: String) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonceSHA256
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func resume(_ result: Result<ASAuthorizationAppleIDCredential, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let credential):
            continuation?.resume(returning: credential)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

extension AppleReauthCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            resume(.failure(AuthFlowError.missingAppleIDToken))
            return
        }
        resume(.success(credential))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        resume(.failure(error))
    }
}

extension AppleReauthCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
