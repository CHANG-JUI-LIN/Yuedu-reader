import Foundation
import Combine

// MARK: - OPDS Catalog
//
// A saved OPDS catalog (Calibre-Web, Standard Ebooks, Project Gutenberg, …).
// URL, name and username live in `opds_catalogs.json`; the password — when the
// catalog needs Basic Auth — is kept in the Keychain (account = "opds_pw_<id>"),
// never on disk in plaintext.

struct OPDSCatalog: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var username: String?
    var sortOrder: Int = 0
}

// MARK: - OPDS Catalog Store

final class OPDSCatalogStore: ObservableObject {

    static let shared = OPDSCatalogStore()

    @Published private(set) var catalogs: [OPDSCatalog] = []

    private let storageURL: URL

    /// Built-in public catalogs offered as one-tap quick-adds when the list is empty.
    /// Project Gutenberg serves OPDS Atom (with EPUB acquisition) without auth.
    static let presets: [OPDSCatalog] = [
        OPDSCatalog(name: "Project Gutenberg", url: "https://m.gutenberg.org/ebooks.opds/", username: nil),
    ]

    init(storageDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!) {
        storageURL = storageDirectory.appendingPathComponent("opds_catalogs.json")
        catalogs = load([OPDSCatalog].self, from: storageURL) ?? []
    }

    // MARK: Mutations

    @discardableResult
    func add(name: String, url: String, username: String?, password: String?) -> OPDSCatalog {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        var catalog = OPDSCatalog(
            name: trimmedName.isEmpty ? Self.defaultName(for: url) : trimmedName,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: (trimmedUser?.isEmpty ?? true) ? nil : trimmedUser,
            sortOrder: (catalogs.map(\.sortOrder).max() ?? -1) + 1
        )
        if let password, !password.isEmpty {
            KeychainHelper.save(account: Self.keychainAccount(catalog.id), data: password)
        }
        catalogs.append(catalog)
        save()
        return catalog
    }

    func remove(_ catalog: OPDSCatalog) {
        KeychainHelper.delete(account: Self.keychainAccount(catalog.id))
        catalogs.removeAll { $0.id == catalog.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        let removedIDs = Set(offsets.map { catalogs[$0].id })
        for id in removedIDs {
            KeychainHelper.delete(account: Self.keychainAccount(id))
        }
        catalogs.removeAll { removedIDs.contains($0.id) }
        save()
    }

    // MARK: Credentials

    func password(for catalog: OPDSCatalog) -> String? {
        KeychainHelper.load(account: Self.keychainAccount(catalog.id))
    }

    func catalog(id: String) -> OPDSCatalog? {
        catalogs.first { $0.id == id }
    }

    /// Build a client carrying the catalog's stored credentials.
    func client(for catalog: OPDSCatalog) -> OPDSClient {
        OPDSClient(username: catalog.username, password: password(for: catalog))
    }

    // MARK: Helpers

    private static func keychainAccount(_ id: String) -> String { "opds_pw_\(id)" }

    private static func defaultName(for url: String) -> String {
        URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? url
    }

    // MARK: Persistence (mirrors RSSStore)

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(catalogs) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
