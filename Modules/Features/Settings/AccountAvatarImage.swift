import Combine
import Foundation
import SwiftUI
import UIKit

/// Resolves stored avatar URLs for the active route. Old profiles carry a
/// Firebase Storage URL, which is exactly what a Chinese device cannot fetch;
/// when the Gateway session is active that URL is rewritten to the Gateway
/// avatar endpoint instead of rewriting the stored data.
enum GatewayAvatarURLResolver {
    static func resolvedURL(
        from rawValue: String,
        gatewayRouteActive: Bool,
        gatewayBaseURL: URL? = GatewayConfiguration.baseURL
    ) -> URL? {
        guard !rawValue.isEmpty, let url = URL(string: rawValue) else { return nil }
        guard gatewayRouteActive else { return url }
        if isGatewayURL(url, gatewayBaseURL: gatewayBaseURL) { return url }
        guard let host = url.host?.lowercased(),
              host.contains("firebasestorage.googleapis.com") || host.contains("storage.googleapis.com") else {
            return url
        }
        guard let base = gatewayBaseURL else { return url }
        return base.appendingPathComponent("v1/avatar")
    }

    static func isGatewayURL(_ url: URL, gatewayBaseURL: URL? = GatewayConfiguration.baseURL) -> Bool {
        guard let baseHost = gatewayBaseURL?.host?.lowercased(),
              let host = url.host?.lowercased() else { return false }
        return host == baseHost
    }
}

/// Loads the signed-in user's avatar through the Gateway with its Authorization
/// header. `AsyncImage` cannot carry one, so images that require authentication
/// use this loader instead.
@MainActor
final class GatewayAvatarImageLoader: ObservableObject {
    static let shared = GatewayAvatarImageLoader()

    @Published private(set) var image: UIImage?
    @Published private(set) var failed = false

    private static let cache = NSCache<NSString, UIImage>()
    private var loadedKey: String?
    private var task: Task<Void, Never>?

    func load(url: URL, cacheKeySuffix: String) {
        let key = url.absoluteString + "|" + cacheKeySuffix
        if loadedKey == key, image != nil || failed { return }
        task?.cancel()
        loadedKey = key
        if let cached = Self.cache.object(forKey: key as NSString) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Always the signed-in user's own avatar; the server ignores any
                // client-supplied path.
                let request = GatewayRequest(method: "GET", path: "/v1/avatar")
                let data = try await GatewaySessionStore.shared.authorizedSendForData(request)
                guard !Task.isCancelled else { return }
                guard let decoded = UIImage(data: data) else {
                    self.failed = true
                    return
                }
                Self.cache.setObject(decoded, forKey: key as NSString)
                self.image = decoded
                self.failed = false
            } catch {
                guard !Task.isCancelled else { return }
                self.failed = true
            }
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        loadedKey = nil
        image = nil
        failed = false
    }
}

/// Avatar image that works on both routes: local bytes first, then the
/// authenticated Gateway loader for Gateway URLs, then plain AsyncImage for the
/// direct route's public Storage URL.
struct AccountAvatarImageView: View {
    let size: CGFloat
    let avatarData: Data?
    let photoURLString: String
    let isLoggedIn: Bool
    let gatewayRouteActive: Bool

    @StateObject private var gatewayLoader = GatewayAvatarImageLoader.shared

    var body: some View {
        Group {
            if let avatarData, let image = UIImage(data: avatarData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url = GatewayAvatarURLResolver.resolvedURL(
                from: photoURLString,
                gatewayRouteActive: gatewayRouteActive
            ), GatewayAvatarURLResolver.isGatewayURL(url) {
                gatewayImage(url: url)
            } else if let url = GatewayAvatarURLResolver.resolvedURL(
                from: photoURLString,
                gatewayRouteActive: gatewayRouteActive
            ) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            guard isLoggedIn,
                  gatewayRouteActive,
                  let url = GatewayAvatarURLResolver.resolvedURL(
                    from: photoURLString,
                    gatewayRouteActive: true
                  ),
                  GatewayAvatarURLResolver.isGatewayURL(url) else { return }
            gatewayLoader.load(url: url, cacheKeySuffix: GatewaySessionStore.shared.uid ?? "")
        }
    }

    @ViewBuilder
    private func gatewayImage(url: URL) -> some View {
        if let image = gatewayLoader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundColor(isLoggedIn ? DSColor.accent : .secondary)
            .padding(size * 0.08)
    }
}
