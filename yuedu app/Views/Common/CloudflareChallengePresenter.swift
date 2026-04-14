import Foundation
import SwiftUI
import UIKit

@MainActor
enum CloudflareChallengePresenter {
    static func present(url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard
                let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                let rootVC = windowScene.windows.first?.rootViewController
            else {
                continuation.resume(throwing: FetchError.emptyContent)
                return
            }

            let challengeView = CloudflareChallengeView(
                targetURL: url,
                onChallengePassed: { html in
                    rootVC.dismiss(animated: true) {
                        continuation.resume(returning: html)
                    }
                },
                onCancel: {
                    rootVC.dismiss(animated: true) {
                        continuation.resume(throwing: FetchError.httpError(503))
                    }
                }
            )

            let hostVC = UIHostingController(rootView: challengeView)
            hostVC.modalPresentationStyle = .fullScreen

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(hostVC, animated: true)
        }
    }
}
