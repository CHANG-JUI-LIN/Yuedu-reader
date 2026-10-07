import Combine
import CryptoKit
import Foundation

@MainActor
final class AozoraCatalogStore: ObservableObject {
    enum State {
        case unavailable
        case loading
        case ready(AozoraCatalogIndex)
        case failed(any Error, cached: AozoraCatalogIndex?)
    }
    static let shared = AozoraCatalogStore()
    static let manifestURL = URL(string: "https://yuedureader.com/catalogs/aozora/v1/manifest.json")!
    @Published private(set) var state: State = .unavailable
    @Published private(set) var isRefreshing = false
    var catalog: AozoraCatalogIndex? {
        switch state {
        case .ready(let index), .failed(_, let index?): index
        default: nil
        }
    }
    let cacheURL: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (URL) async throws -> Data
    private let lastCheckKey: String
    private var loadedCache = false
    private var catalogHash: String?

    private struct Manifest: Decodable, Sendable {
        let schemaVersion: Int
        let sha256: String
        let workCount: Int
    }
    private struct Cached: Codable, Sendable {
        let data: Data
        let sha256: String
    }

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PublicLibrary/aozora", isDirectory: true),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         fetch: @escaping (URL) async throws -> Data = AozoraCatalogStore.fetchData) {
        cacheURL = directory.appendingPathComponent("catalog-cache.json")
        lastCheckKey = "aozora.catalog.lastCheck." + directory.path
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    /// Publish the verified cache before awaiting any network operation.
    func loadCached() async {
        guard !loadedCache else { return }
        loadedCache = true
        let url = cacheURL
        do {
            let cached = try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: url.path) else { return Optional<(Cached, AozoraCatalogIndex)>.none }
                let cached = try JSONDecoder().decode(Cached.self, from: Data(contentsOf: url))
                guard Self.hash(cached.data) == cached.sha256 else { throw AozoraCatalogError.hashMismatch }
                return (cached, try Self.decodeAndIndex(cached.data))
            }.value
            if let (cached, index) = cached {
                catalogHash = cached.sha256
                state = .ready(index)
            }
        } catch {
            AppLogger.error("Aozora catalog cache could not be loaded", error: error)
            state = .failed(error, cached: nil)
        }
    }

    func load(forceRefresh: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await loadCached()
        if !forceRefresh, let last = defaults.object(forKey: lastCheckKey) as? Date,
           now().timeIntervalSince(last) < 86_400 { return }
        let previous = catalog
        if previous == nil { state = .loading }
        // Include failed checks in the daily budget; returning to Explore during
        // the current official-site outage must not repeatedly fetch the manifest.
        defaults.set(now(), forKey: lastCheckKey)
        do {
            let manifestData = try await fetch(Self.manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.schemaVersion == 1 else { throw AozoraCatalogError.unsupportedSchema(manifest.schemaVersion) }
            if manifest.sha256 == catalogHash, let previous {
                state = .ready(previous)
                return
            }
            let bytes = try await fetch(Self.manifestURL.deletingLastPathComponent().appendingPathComponent("works.json"))
            let url = cacheURL
            let index = try await Task.detached(priority: .userInitiated) {
                guard Self.hash(bytes) == manifest.sha256 else { throw AozoraCatalogError.hashMismatch }
                let index = try Self.decodeAndIndex(bytes)
                guard index.worksByID.count == manifest.workCount else { throw AozoraCatalogError.invalidCatalog }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // The bytes and their digest form one atomic cache record; a
                // terminated write cannot pair a new manifest with old works.
                try JSONEncoder().encode(Cached(data: bytes, sha256: manifest.sha256)).write(to: url, options: .atomic)
                return index
            }.value
            try Task.checkCancellation()
            catalogHash = manifest.sha256
            state = .ready(index)
        } catch {
            if Task.isCancelled {
                state = previous.map(State.ready) ?? .unavailable
                return
            }
            AppLogger.network("Aozora catalog update failed", error: error, context: ["url": Self.manifestURL.absoluteString])
            // A failed update, including a corrupt asset, must not discard a
            // verified offline catalog. Remove only if offline browsing is retired.
            if previous == nil, Self.isUnavailable(error) { state = .unavailable }
            else { state = .failed(error, cached: previous) }
        }
    }

    nonisolated static func decodeAndIndex(_ data: Data) throws -> AozoraCatalogIndex {
        try SourcePerfTrace.span("aozora.catalog.load", "bytes=\(data.count)", thresholdMs: 0) {
            AozoraCatalogIndex(catalog: try AozoraCatalog.decode(data))
        }
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isUnavailable(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if case OPDSError.http(404) = error { return true }
        return false
    }

    private static func fetchData(_ url: URL) async throws -> Data {
        let http = RemoteLibraryHTTPClient(baseURL: Self.manifestURL)
        let (data, response) = try await http.data(for: URLRequest(url: url, timeoutInterval: 30))
        try RemoteLibraryHTTPClient.validate(response)
        return data
    }
}
