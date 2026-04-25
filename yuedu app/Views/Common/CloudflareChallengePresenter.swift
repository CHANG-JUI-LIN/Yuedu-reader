import Foundation
import SwiftUI
import UIKit
import WebKit

@MainActor
enum CloudflareChallengePresenter {
    // MARK: - 去重狀態
    // 只允許一個 CF 挑戰 UI 同時存在。
    // 其他並發呼叫等待第一個完成後共享結果（不重複彈視窗）。
    private static var isPresenting = false
    private static var pendingContinuations: [CheckedContinuation<String, Error>] = []

    static func present(url: URL) async throws -> String {
        // 若已有 cf_clearance 對應此 domain，直接略過，無需顯示 UI
        if await hasClearance(for: url) { return "" }

        // 若已有進行中的挑戰，排隊等待而不重複彈視窗
        if isPresenting {
            return try await withCheckedThrowingContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }

        isPresenting = true
        do {
            let result = try await _present(url: url)
            drainPending(with: .success(result))
            return result
        } catch {
            drainPending(with: .failure(error))
            throw error
        }
    }

    // MARK: - 內部

    private static func hasClearance(for url: URL) async -> Bool {
        let host = url.host ?? ""
        guard !host.isEmpty else { return false }
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        return cookies.contains {
            guard $0.name == "cf_clearance" else { return false }
            let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            return host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func drainPending(with result: Result<String, Error>) {
        isPresenting = false
        let waiting = pendingContinuations
        pendingContinuations = []
        for c in waiting {
            switch result {
            case .success(let v): c.resume(returning: v)
            case .failure(let e): c.resume(throwing: e)
            }
        }
    }

    private static func _present(url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard
                let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                let rootVC = windowScene.windows.first?.rootViewController
            else {
                continuation.resume(throwing: FetchError.emptyContent)
                return
            }

            // 預先 retain hostVC 供 callback dismiss 自己用，避免 dismiss rootVC
            // 把底下的閱讀器 fullScreenCover 一起關掉。
            var hostVCRef: UIHostingController<CloudflareChallengeView>?

            let challengeView = CloudflareChallengeView(
                targetURL: url,
                onChallengePassed: { html in
                    hostVCRef?.dismiss(animated: true) {
                        hostVCRef = nil
                        continuation.resume(returning: html)
                    }
                },
                onCancel: {
                    hostVCRef?.dismiss(animated: true) {
                        hostVCRef = nil
                        continuation.resume(throwing: FetchError.httpError(503))
                    }
                }
            )

            let hostVC = UIHostingController(rootView: challengeView)
            hostVC.modalPresentationStyle = .fullScreen
            hostVCRef = hostVC

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(hostVC, animated: true)
        }
    }
}
