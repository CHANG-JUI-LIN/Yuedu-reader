import Foundation

extension URL {
    func upgradedToHTTPS() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.scheme == "http" else {
            return self
        }
        components.scheme = "https"
        return components.url ?? self
    }
}

extension String {
    var httpsUpgradedURL: URL? {
        URL(string: self)?.upgradedToHTTPS()
    }
}
