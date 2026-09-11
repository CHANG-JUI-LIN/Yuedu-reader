import Foundation
import Combine

struct OPDSCatalog: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var username: String?
    var sortOrder: Int = 0
    var kind: RemoteLibraryKind = .opds
    var syncProgress: Bool = false

    private enum CodingKeys: String, CodingKey { case id, name, url, username, sortOrder, kind, syncProgress }

    init(id: String = UUID().uuidString, name: String, url: String, username: String? = nil,
         sortOrder: Int = 0, kind: RemoteLibraryKind = .opds, syncProgress: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.sortOrder = sortOrder
        self.kind = kind
        self.syncProgress = syncProgress
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        url = try values.decode(String.self, forKey: .url)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        kind = try values.decodeIfPresent(RemoteLibraryKind.self, forKey: .kind) ?? .opds
        syncProgress = try values.decodeIfPresent(Bool.self, forKey: .syncProgress) ?? false
    }
}

/// The existing OPDS file remains the single connection registry. Both username
/// and password live in Keychain; legacy passwords keep their account identity.
final class OPDSCatalogStore: ObservableObject {
    static let shared = OPDSCatalogStore()
    @Published private(set) var catalogs: [OPDSCatalog] = []
    var connections: [RemoteLibraryConnection] { catalogs }
    private let storageURL: URL
    private var clients: [String: RemoteLibraryHTTPClient] = [:]

    static let presets: [OPDSCatalog] = [
        OPDSCatalog(name: "Project Gutenberg", url: "https://m.gutenberg.org/ebooks.opds/")
    ]

    init(storageDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!,
         importLegacyWebDAV: Bool = true, defaults: UserDefaults = .standard) {
        storageURL = storageDirectory.appendingPathComponent("opds_catalogs.json")
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do { catalogs = try JSONDecoder().decode([OPDSCatalog].self, from: Data(contentsOf: storageURL)) }
            catch { AppLogger.error("Unable to load remote library connections: \(error)") }
        }
        let needsUsernameMigration = catalogs.contains { $0.username != nil }
        for index in catalogs.indices where catalogs[index].username == nil {
            catalogs[index].username = KeychainHelper.load(account: Self.usernameAccount(catalogs[index].id))
        }
        if needsUsernameMigration { save() }
        if importLegacyWebDAV, !defaults.bool(forKey: "remote_library_webdav_migrated") {
            if let url = defaults.string(forKey: "webdav_url"),
               let normalized = OPDSCatalog.normalizedURL(url, kind: .webDAV) {
                add(name: normalized.host ?? "WebDAV", url: normalized.absoluteString,
                    username: defaults.string(forKey: "webdav_username"),
                    password: defaults.string(forKey: "webdav_password"), kind: .webDAV)
            }
            // Copy once. Future changes to library connections must never change
            // the synchronization/backup account and vice versa.
            defaults.set(true, forKey: "remote_library_webdav_migrated")
        }
    }

    @discardableResult
    func add(name: String, url: String, username: String?, password: String?, kind: RemoteLibraryKind = .opds) -> OPDSCatalog {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = OPDSCatalog.normalizedURL(url, kind: kind)?.absoluteString ?? url.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = OPDSCatalog(name: cleanName.isEmpty ? URL(string: normalized)?.host ?? normalized : cleanName,
                                  url: normalized, username: cleanUser?.isEmpty == false ? cleanUser : nil,
                                  sortOrder: (catalogs.map(\.sortOrder).max() ?? -1) + 1, kind: kind)
        if let password, !password.isEmpty { KeychainHelper.save(account: Self.keychainAccount(catalog.id), data: password) }
        catalogs.append(catalog)
        save()
        return catalog
    }

    func update(_ catalog: OPDSCatalog, password: String?) {
        guard let index = catalogs.firstIndex(where: { $0.id == catalog.id }) else { return }
        var catalog = catalog
        catalog.url = OPDSCatalog.normalizedURL(catalog.url, kind: catalog.kind)?.absoluteString ?? catalog.url
        let username = catalog.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.username = username?.isEmpty == false ? username : nil
        if catalog.username == nil { KeychainHelper.delete(account: Self.usernameAccount(catalog.id)) }
        catalogs[index] = catalog
        if let password {
            if password.isEmpty { KeychainHelper.delete(account: Self.keychainAccount(catalog.id)) }
            else { KeychainHelper.save(account: Self.keychainAccount(catalog.id), data: password) }
        }
        clients.removeValue(forKey: catalog.id)
        save()
    }

    func remove(_ catalog: OPDSCatalog) {
        KeychainHelper.delete(account: Self.keychainAccount(catalog.id))
        KeychainHelper.delete(account: Self.usernameAccount(catalog.id))
        clients.removeValue(forKey: catalog.id)
        catalogs.removeAll { $0.id == catalog.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for catalog in offsets.map({ catalogs[$0] }) { remove(catalog) }
    }

    func password(for catalog: OPDSCatalog) -> String? { KeychainHelper.load(account: Self.keychainAccount(catalog.id)) }
    func catalog(id: String) -> OPDSCatalog? { catalogs.first { $0.id == id } }
    func connection(id: String) -> OPDSCatalog? { catalog(id: id) }

    func httpClient(for catalog: OPDSCatalog) -> RemoteLibraryHTTPClient {
        if let client = clients[catalog.id] { return client }
        let client = RemoteLibraryHTTPClient(baseURL: URL(string: catalog.url) ?? URL(string: "https://invalid.invalid")!,
                                             username: catalog.username, password: password(for: catalog))
        clients[catalog.id] = client
        return client
    }

    func client(for catalog: OPDSCatalog) -> OPDSClient {
        OPDSClient(username: catalog.username, password: password(for: catalog),
                   baseURL: URL(string: catalog.url), kind: catalog.kind, httpClient: httpClient(for: catalog))
    }

    func webDAVClient(for catalog: OPDSCatalog) -> WebDAVBrowseClient {
        WebDAVBrowseClient(serverUrl: catalog.url, username: catalog.username ?? "", password: password(for: catalog) ?? "",
                           httpClient: httpClient(for: catalog))
    }

    func testConnection(url: URL, kind: RemoteLibraryKind, username: String?, password: String?) async throws {
        let http = RemoteLibraryHTTPClient(baseURL: url, username: username, password: password)
        if kind == .webDAV {
            _ = try await WebDAVBrowseClient(serverUrl: url.absoluteString, username: username ?? "", password: password ?? "", httpClient: http).list(url)
        } else {
            _ = try await OPDSClient(kind: kind, httpClient: http).fetchFeed(url)
        }
    }

    private static func keychainAccount(_ id: String) -> String { "opds_pw_\(id)" }
    private static func usernameAccount(_ id: String) -> String { "opds_user_\(id)" }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var persisted = catalogs
            for index in persisted.indices {
                if let username = persisted[index].username {
                    // Never remove the only legacy username before its Keychain
                    // write succeeds (for example while protected data is locked).
                    guard KeychainHelper.save(account: Self.usernameAccount(persisted[index].id), data: username) else {
                        AppLogger.error("Unable to migrate remote library username into Keychain")
                        return
                    }
                }
                persisted[index].username = nil
            }
            try JSONEncoder().encode(persisted).write(to: storageURL, options: .atomic)
        } catch { AppLogger.error("Unable to save remote library connections: \(error)") }
    }
}
