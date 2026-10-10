import Combine
import Foundation

/// What 遠端書庫 shows under a WebDAV connection (unified library 2d).
enum WebDAVIndexStatus: Hashable, Sendable {
    case indexing(Int)
    case indexed(Int)
    case pausedNotOnWiFi
    case limitReached(Int)
    case failed(String)

    var title: String {
        switch self {
        case .indexing(let count): String(format: localized("正在建立索引（%d 本）"), count)
        case .indexed(let count): String(format: localized("已建立索引（%d 本）"), count)
        case .pausedNotOnWiFi: localized("已暫停：未連接 Wi-Fi")
        case .limitReached(let count): String(format: localized("已達上限（%d 本）"), count)
        case .failed(let message): String(format: localized("建立索引失敗：%@"), message)
        }
    }
}

/// Runs WebDAV indexing (unified library 2d; maintainer decisions 5–6):
///
/// - A connection is indexed when the app is active, the network allows background work
///   (Wi-Fi or wired, not expensive or constrained), its setting is on, and its last complete
///   crawl is older than `limits.recrawlInterval` (or a crawl is unfinished).
/// - One connection at a time.
/// - Entering the background finishes the batch in hand under a `BackgroundTaskHold`, then
///   stops. Losing Wi-Fi, turning the setting off or removing the connection stops at once.
/// - An authentication failure stops that connection until the connections change (an edit
///   is the only way credentials change) or the app launches again.
@MainActor
final class WebDAVIndexCoordinator: ObservableObject {
    static let shared = WebDAVIndexCoordinator()

    typealias Lister = @Sendable (URL) async throws -> [WebDAVBrowseClient.Entry]

    @Published private(set) var statuses: [String: WebDAVIndexStatus] = [:]

    private let connections: OPDSCatalogStore
    private let network: NetworkPathProviding
    private let limits: WebDAVIndexLimits
    private let now: @Sendable () -> Date
    private let makeLister: @MainActor (OPDSCatalog, OPDSCatalogStore) -> Lister

    private var store: RemoteRecordStore?
    private var isActive = false
    private var summaries: [String: Summary] = [:]
    private var running: Running?
    private var authStopped: Set<String> = []
    private var knownConnectionIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    /// What a connection's index holds, kept in memory so statuses never read a file on main.
    struct Summary: Hashable, Sendable {
        var root: URL
        var username: String?
        var visibleCount: Int
        var isCrawling: Bool
        var lastCompletedAt: Date?
        var outcome: WebDAVIndexOutcome?

        init(_ state: WebDAVIndexState) {
            root = state.root
            username = state.username
            visibleCount = state.visibleFiles.count
            isCrawling = state.isCrawling
            lastCompletedAt = state.lastCompletedAt
            outcome = state.outcome
        }
    }

    private final class Running {
        let connectionID: String
        let stopFlag = StopFlag()
        var task: Task<Void, Never>?
        var stopReason: WebDAVIndexPauseReason?
        var hold: BackgroundTaskHold?
        init(connectionID: String) { self.connectionID = connectionID }
    }

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    init(
        connections: OPDSCatalogStore = .shared,
        network: NetworkPathProviding = NetworkPathMonitor.shared,
        limits: WebDAVIndexLimits = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        makeLister: @escaping @MainActor (OPDSCatalog, OPDSCatalogStore) -> Lister = WebDAVIndexCoordinator.liveLister
    ) {
        self.connections = connections
        self.network = network
        self.limits = limits
        self.now = now
        self.makeLister = makeLister
    }

    /// Starts watching the connections and the network. Called once with the app's store.
    func attach(store: RemoteRecordStore) async {
        guard self.store == nil else { return }
        self.store = store
        let existing = Set(connections.catalogs.map(\.id))
        knownConnectionIDs = existing
        // Load what each index holds off the main actor, and drop indexes of connections
        // removed while the app was not running.
        let loaded = await Task.detached(priority: .utility) { () -> [String: Summary] in
            var summaries: [String: Summary] = [:]
            for id in store.connectionIDs() {
                if !existing.contains(id) { store.remove(connectionID: id); continue }
                if let state = store.state(connectionID: id) { summaries[id] = Summary(state) }
            }
            return summaries
        }.value
        summaries = loaded
        connections.$catalogs.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.connectionsChanged() }
        }.store(in: &cancellables)
        network.allowsBackgroundWorkPublisher.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }.store(in: &cancellables)
        evaluate()
    }

    /// From the scene phase: active, or not.
    func setActive(_ active: Bool) {
        isActive = active
        evaluate()
    }

    #if DEBUG
    /// Waits until no crawl is running, for tests.
    func waitForIdleForTesting() async {
        while let task = running?.task { await task.value }
    }

    var summariesForTesting: [String: Summary] { summaries }
    var stopReasonForTesting: WebDAVIndexPauseReason? { running?.stopReason }
    #endif

    // MARK: - Decisions

    private func connectionsChanged() {
        let current = Set(connections.catalogs.map(\.id))
        for removed in knownConnectionIDs.subtracting(current) {
            if running?.connectionID == removed { stopRunning(reason: .disabled) }
            store?.remove(connectionID: removed)
            summaries.removeValue(forKey: removed)
        }
        knownConnectionIDs = current
        // An edit is the only way credentials change.
        authStopped.removeAll()
        evaluate()
    }

    private func evaluate() {
        guard let store else { return }
        let webDAV = connections.catalogs.filter { $0.kind == .webDAV }.sorted { $0.sortOrder < $1.sortOrder }
        let onWiFi = network.allowsBackgroundWork

        if let running {
            let connection = webDAV.first { $0.id == running.connectionID }
            if connection == nil || !connections.indexesBooks(connection!) {
                stopRunning(reason: .disabled)
            } else if !onWiFi {
                stopRunning(reason: .notOnWiFi)
            } else if !isActive, running.hold == nil {
                // Finish the batch in hand, then stop.
                running.hold = BackgroundTaskHold(name: "webdav.index")
                running.stopFlag.set()
            }
        }

        if running == nil, isActive, onWiFi,
           let next = webDAV.first(where: { connections.indexesBooks($0) && needsWork($0) }) {
            start(next, store: store)
        }
        refreshStatuses(webDAV, onWiFi: onWiFi)
    }

    private func needsWork(_ connection: OPDSCatalog) -> Bool {
        guard !authStopped.contains(connection.id) else { return false }
        guard let summary = summaries[connection.id],
              summary.root == RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV),
              summary.username == connection.username else { return true }
        if summary.isCrawling { return true }
        guard let completed = summary.lastCompletedAt else { return true }
        return now().timeIntervalSince(completed) >= limits.recrawlInterval
    }

    private func start(_ connection: OPDSCatalog, store: RemoteRecordStore) {
        guard let root = RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV) else { return }
        let running = Running(connectionID: connection.id)
        self.running = running
        let indexer = WebDAVIndexer(
            connectionID: connection.id, root: root, limits: limits,
            list: makeLister(connection, connections),
            save: { [weak self] state in
                store.save(state)
                let summary = Summary(state)
                Task { @MainActor in self?.noteProgress(state.connectionID, summary) }
            },
            now: now
        )
        let username = connection.username
        let flag = running.stopFlag
        running.task = Task { [weak self] in
            let initial = await Task.detached(priority: .utility) { () -> WebDAVIndexState in
                // Another root or user starts over.
                if let state = store.state(connectionID: connection.id), state.root == root, state.username == username { return state }
                return WebDAVIndexState(connectionID: connection.id, root: root, username: username)
            }.value
            let result = await indexer.run(from: initial, stopAfterBatch: { flag.isSet })
            self?.finished(running, result: result, store: store)
        }
        AppLogger.cache("⟐ WebDAV index started", context: ["connection": connection.id])
    }

    private func stopRunning(reason: WebDAVIndexPauseReason) {
        guard let running else { return }
        running.stopReason = reason
        running.stopFlag.set()
        running.task?.cancel()
    }

    private func finished(_ running: Running, result: WebDAVIndexState, store: RemoteRecordStore) {
        var result = result
        if case .failed(let kind, _) = result.outcome {
            if kind == .authentication { authStopped.insert(running.connectionID) }
            // A failure because the network went away is a pause, not a failure.
            if kind == .network, !network.allowsBackgroundWork {
                result.outcome = .paused(.notOnWiFi)
                store.save(result)
            }
        } else if let reason = running.stopReason, result.outcome == nil || result.outcome == .paused(.background) {
            // The stop flag is shared: a crawl stopped for Wi-Fi or the setting may have seen it
            // between batches and reported a background pause. The coordinator knows why.
            result.outcome = .paused(reason)
            if reason != .disabled || knownConnectionIDs.contains(running.connectionID) { store.save(result) }
        }
        if knownConnectionIDs.contains(running.connectionID) { summaries[running.connectionID] = Summary(result) }
        running.hold?.release()
        if self.running === running { self.running = nil }
        evaluate()
    }

    private func noteProgress(_ connectionID: String, _ summary: Summary) {
        guard knownConnectionIDs.contains(connectionID) else { return }
        summaries[connectionID] = summary
        refreshStatuses(connections.catalogs.filter { $0.kind == .webDAV }, onWiFi: network.allowsBackgroundWork)
    }

    private func refreshStatuses(_ webDAV: [OPDSCatalog], onWiFi: Bool) {
        var statuses: [String: WebDAVIndexStatus] = [:]
        for connection in webDAV where connections.indexesBooks(connection) {
            let summary = summaries[connection.id]
            let count = summary?.visibleCount ?? 0
            if running?.connectionID == connection.id {
                statuses[connection.id] = .indexing(count)
                continue
            }
            switch summary?.outcome {
            case .failed(let kind, let message):
                statuses[connection.id] = kind == .authentication || onWiFi ? .failed(message) : .pausedNotOnWiFi
            case .limitReached(let files):
                statuses[connection.id] = .limitReached(files)
            case .completed, .empty:
                statuses[connection.id] = .indexed(count)
            case .paused, nil:
                if !onWiFi, summary?.lastCompletedAt == nil || summary?.isCrawling == true {
                    statuses[connection.id] = .pausedNotOnWiFi
                } else if summary?.isCrawling == true || summary == nil {
                    statuses[connection.id] = onWiFi ? .indexing(count) : .pausedNotOnWiFi
                } else {
                    statuses[connection.id] = .indexed(count)
                }
            }
        }
        if statuses != self.statuses { self.statuses = statuses }
    }

    // MARK: - The indexer's own client

    /// A client of its own (Phase 2 plan, decision 6): it refuses expensive and constrained
    /// networks, which the shared client must not, and it never touches the store's unlocked
    /// client cache from off the main actor. The password is read here, on the main actor.
    static func liveLister(_ connection: OPDSCatalog, _ store: OPDSCatalogStore) -> Lister {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        let password = store.password(for: connection)
        let base = RemoteLibraryConnection.normalizedURL(connection.url, kind: .webDAV) ?? URL(string: "https://invalid.invalid")!
        let http = RemoteLibraryHTTPClient(baseURL: base, username: connection.username, password: password, configuration: configuration)
        let client = WebDAVBrowseClient(serverUrl: connection.url, username: connection.username ?? "", password: password ?? "", httpClient: http)
        return { try await client.list($0) }
    }
}
