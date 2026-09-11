import Foundation

/// Saved connections share the existing OPDS persistence and Keychain identity.
enum RemoteLibraryKind: String, Codable, CaseIterable, Identifiable {
    case opds
    case webDAV
    case calibre

    var id: String { rawValue }
}

typealias RemoteLibraryConnection = OPDSCatalog
typealias RemoteLibraryConnectionStore = OPDSCatalogStore

extension OPDSCatalog {
    /// Calibre accepts a server base (including reverse-proxy prefix), while a
    /// complete /opds URL and its library/query parameters are left intact.
    static func normalizedURL(_ value: String, kind: RemoteLibraryKind) -> URL? {
        guard let url = OPDSClient.url(from: value),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        if kind == .calibre, !components.path.split(separator: "/").contains(where: { $0.lowercased() == "opds" }) {
            let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.percentEncodedPath = path.isEmpty ? "/opds" : "/\(path)/opds"
        }
        if kind == .webDAV, !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url
    }
}
