import Foundation

/// Native Content Server routes live beside /opds, beneath the same proxy prefix.
/// These routes are verified against calibre 9.14's srv/cdb.py and srv/ajax.py.
struct CalibreServerAddress: Hashable, Sendable {
    let baseURL: URL

    init(connectionURL: String) throws {
        guard let url = OPDSClient.url(from: connectionURL) else { throw RemoteLibraryWriteError.invalidDestination }
        try self.init(connectionURL: url)
    }

    init(connectionURL: URL) throws {
        guard var parts = URLComponents(url: connectionURL, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil else {
            throw RemoteLibraryWriteError.invalidDestination
        }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.contains(where: {
            guard let value = $0.removingPercentEncoding else { return true }
            return value == "." || value == ".." || value.contains("/") || value.contains("\\")
                || value.rangeOfCharacter(from: .controlCharacters) != nil
        }) else { throw RemoteLibraryWriteError.invalidDestination }
        guard let opds = path.firstIndex(where: { $0.removingPercentEncoding?.lowercased() == "opds" }) else {
            throw RemoteLibraryWriteError.unsupported
        }
        parts.percentEncodedPath = "/" + path[..<opds].joined(separator: "/")
        parts.queryItems = parts.queryItems?.filter { $0.name != "library_id" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        parts.fragment = nil
        guard let url = parts.url else { throw RemoteLibraryWriteError.invalidDestination }
        baseURL = url
    }

    func endpoint(_ pathComponents: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw RemoteLibraryWriteError.invalidDestination
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = try pathComponents.map { component -> String in
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"),
                  component.rangeOfCharacter(from: .controlCharacters) == nil,
                  let value = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw RemoteLibraryWriteError.invalidDestination
            }
            return value
        }
        let prefix = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = "/" + ([prefix].filter { !$0.isEmpty } + encoded).joined(separator: "/")
        let replaced = Set(queryItems.map(\.name))
        let merged = (parts.queryItems ?? []).filter { !replaced.contains($0.name) } + queryItems
        parts.queryItems = merged.isEmpty ? nil : merged
        guard let url = parts.url else { throw RemoteLibraryWriteError.invalidDestination }
        return url
    }

    func relativeComponents(of url: URL) throws -> [String] {
        guard RemoteLibraryHTTPClient.sameOrigin(url, baseURL), url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw RemoteLibraryWriteError.invalidDestination
        }
        let path = parts.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let prefix = base.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard path.starts(with: prefix), !path.contains(".."), !path.contains("."),
              !path.contains(where: { $0.contains("/") || $0.contains("\\") }) else {
            throw RemoteLibraryWriteError.invalidDestination
        }
        return Array(path.dropFirst(prefix.count))
    }
}

struct CalibreBookLocator: Hashable, Sendable {
    let address: CalibreServerAddress
    let libraryID: String
    let bookID: Int
    let format: String

    init(reference: RemoteBookReference, connection: OPDSCatalog) throws {
        guard reference.connectionID == connection.id else { throw RemoteLibraryWriteError.invalidDestination }
        try self.init(resource: reference.format, connection: connection)
    }

    init(item: RemoteLibraryItem, connection: OPDSCatalog) throws {
        guard item.connectionID == connection.id, let format = item.formats.first else {
            throw RemoteLibraryWriteError.invalidDestination
        }
        try self.init(resource: format, connection: connection)
    }

    private init(resource: RemoteLibraryFormat, connection: OPDSCatalog) throws {
        guard connection.kind == .calibre else { throw RemoteLibraryWriteError.unsupported }
        address = try CalibreServerAddress(connectionURL: connection.url)
        let parts = try address.relativeComponents(of: resource.url)
        guard parts.count >= 4, parts[0] == "get", let id = Int(parts[2]), id > 0,
              parts[1].caseInsensitiveCompare(resource.fileExtension) == .orderedSame,
              !parts[3].isEmpty else { throw RemoteLibraryWriteError.unsupported }
        bookID = id
        libraryID = parts[3]
        format = parts[1].uppercased()
    }
}

struct CalibreLibraryInfo: Decodable, Sendable {
    let libraryMap: [String: String]
    let defaultLibrary: String
    enum CodingKeys: String, CodingKey {
        case libraryMap = "library_map", defaultLibrary = "default_library"
    }
}

struct CalibreServerAPI {
    let address: CalibreServerAddress
    let transport: any RemoteLibraryTransport

    func libraryInfo() async throws -> CalibreLibraryInfo {
        var request = URLRequest(url: try address.endpoint(["ajax", "library-info"]))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        // A 404 means this server does not expose the native Content Server API
        // (e.g. Calibre-Web). It is not a reason to attempt its HTML upload form.
        if response.statusCode == 404 { throw RemoteLibraryWriteError.unsupported }
        try RemoteLibraryWriteError.validate(response)
        guard let info = try? JSONDecoder().decode(CalibreLibraryInfo.self, from: data),
              !info.libraryMap.isEmpty, info.libraryMap[info.defaultLibrary] != nil else {
            throw RemoteLibraryWriteError.unsupported
        }
        return info
    }

    func selectedLibrary(connectionURL: URL, directoryURL: URL?) async throws -> String {
        let info = try await libraryInfo()
        // Never silently upload into the default library when a selected library
        // no longer exists or is inaccessible to this user.
        for url in [directoryURL, connectionURL].compactMap({ $0 }) {
            let path = try address.relativeComponents(of: url)
            guard path.first == "opds" else { throw RemoteLibraryWriteError.invalidDestination }
            if let selected = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?
                .first(where: { $0.name == "library_id" })?.value, !selected.isEmpty {
                guard info.libraryMap[selected] != nil else { throw RemoteLibraryWriteError.invalidDestination }
                return selected
            }
        }
        return info.defaultLibrary
    }

    func selectedLibrary(connectionURL: String, directoryURL: URL?) async throws -> String {
        guard let url = OPDSClient.url(from: connectionURL) else { throw RemoteLibraryWriteError.invalidDestination }
        return try await selectedLibrary(connectionURL: url, directoryURL: directoryURL)
    }
}
