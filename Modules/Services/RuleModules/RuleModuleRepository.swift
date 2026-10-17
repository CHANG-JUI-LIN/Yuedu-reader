import Combine
import Foundation

// Module ecosystem M6: a module repository is one address that lists modules —
// `{"name": "…", "modules": [{"id", "title", "description", "version", "url"}]}` — so a reader
// subscribes once and installs from a list instead of pasting each module's address. Every
// install and update still goes through the import sheet: the file is read, validated and
// previewed, and an update that adds a site says so before anything is written (6e).

/// A repository's index, as read.
struct RuleModuleRepositoryIndex: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let description: String?
        let author: String?
        /// The version the repository lists; the file's own version is what installs.
        let version: String
        /// The module file, resolved against the index's address.
        let url: URL
    }

    let name: String
    let modules: [Entry]

    static let maximumModules = 500
    static let maximumBytes = 1_000_000

    /// Refuses an index that is not one, naming the entry at fault: a repository is fixed by
    /// its author, never read in part.
    static func parse(_ data: Data, from address: URL) throws(RuleModuleRepositoryError) -> RuleModuleRepositoryIndex {
        guard data.count <= maximumBytes else { throw .tooLarge }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .notAnIndex
        }
        guard let root = object as? [String: Any], let list = root["modules"] as? [Any] else { throw .notAnIndex }
        guard let name = trimmed(root["name"]) else { throw .missingName }
        guard list.count <= maximumModules else { throw .tooManyModules }
        var seen = Set<String>()
        var modules: [Entry] = []
        for (offset, item) in list.enumerated() {
            let position = offset + 1
            guard let fields = item as? [String: Any] else { throw .invalidEntry(position: position, field: "id") }
            guard let id = trimmed(fields["id"]), RuleModuleValidator.isFileSafe(id) else {
                throw .invalidEntry(position: position, field: "id")
            }
            guard let title = trimmed(fields["title"]) else { throw .invalidEntry(position: position, field: "title") }
            guard let version = trimmed(fields["version"]), RuleModuleVersion(version) != nil else {
                throw .invalidEntry(position: position, field: "version")
            }
            guard let written = trimmed(fields["url"]),
                  let url = URL(string: written, relativeTo: address)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
                throw .invalidEntry(position: position, field: "url")
            }
            guard seen.insert(id).inserted else { throw .duplicateID(id) }
            modules.append(Entry(id: id, title: title, description: trimmed(fields["description"]), author: trimmed(fields["author"]),
                                 version: version, url: url))
        }
        return RuleModuleRepositoryIndex(name: name, modules: modules)
    }

    /// Whether `data` is meant as an index rather than a module: an object listing `modules`
    /// with no `id` of its own (a module file has both).
    static func isIndex(_ data: Data) -> Bool {
        guard data.count <= maximumBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return root["id"] == nil && root["modules"] != nil
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

enum RuleModuleRepositoryError: Error, Equatable, Sendable {
    case notAnIndex
    case missingName
    case tooLarge
    case tooManyModules
    /// `position` counts from 1, as a reader reads the list.
    case invalidEntry(position: Int, field: String)
    case duplicateID(String)
    /// The file at an entry's address is another module.
    case differentModule(listed: String, file: String)

    var message: String {
        switch self {
        case .notAnIndex: localized("這不是模組倉庫的索引")
        case .missingName: localized("模組倉庫沒有名稱")
        case .tooLarge: localized("模組倉庫的索引太大")
        case .tooManyModules: String(format: localized("模組倉庫最多列 %d 個模組"), RuleModuleRepositoryIndex.maximumModules)
        case .invalidEntry(let position, let field): String(format: localized("模組倉庫第 %d 個模組的「%@」無效"), position, field)
        case .duplicateID(let id): String(format: localized("模組倉庫列了兩次「%@」"), id)
        case .differentModule(let listed, let file):
            String(format: localized("模組倉庫列的是「%@」，下載的檔案卻是「%@」"), listed, file)
        }
    }
}

extension RuleModule {
    /// Sites this version sends requests to that `installed` did not: said before an update
    /// replaces anything (6e).
    func hosts(addedTo installed: RuleModule) -> [String] {
        let known = Set(installed.hosts.map { $0.lowercased() })
        return hosts.filter { !known.contains($0.lowercased()) }
    }
}

/// A repository's module against what is installed.
enum RuleModuleRepositoryStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// The repository lists a higher version than `installed`.
    case updateAvailable(installed: String)
    /// An official module's id: it comes with the app, never from a repository.
    case official

    init(_ entry: RuleModuleRepositoryIndex.Entry, installed: [InstalledRuleModule]) {
        if OfficialRuleModules.reservedIDs.contains(entry.id) {
            self = .official
            return
        }
        guard let current = installed.first(where: { $0.module.id == entry.id }) else {
            self = .notInstalled
            return
        }
        if let listed = RuleModuleVersion(entry.version), let have = RuleModuleVersion(current.module.version), have < listed {
            self = .updateAvailable(installed: current.module.version)
        } else {
            self = .installed
        }
    }
}

/// A repository the reader subscribed to.
struct RuleModuleRepositorySubscription: Codable, Equatable, Sendable {
    let url: URL
    /// The index's name when it was last read.
    var name: String
}

/// The subscribed repositories, in the order they were added: `.repositories.json` in the
/// modules folder (hidden, so the folder's listing of modules never reads it).
struct RuleModuleRepositoryStore: Sendable {
    let file: URL

    init(file: URL = RuleModuleStore.defaultDirectory.appendingPathComponent(".repositories.json")) {
        self.file = file
    }

    func list() -> [RuleModuleRepositorySubscription] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            return try JSONDecoder().decode([RuleModuleRepositorySubscription].self, from: Data(contentsOf: file))
        } catch {
            AppLogger.error("Module repositories unreadable", error: error, context: ["path": file.path], level: .error)
            return []
        }
    }

    /// Adds `subscription`, or renames the one at its address in place.
    func add(_ subscription: RuleModuleRepositorySubscription) throws {
        var all = list()
        if let index = all.firstIndex(where: { $0.url == subscription.url }) {
            all[index] = subscription
        } else {
            all.append(subscription)
        }
        try write(all)
    }

    func remove(url: URL) throws {
        try write(list().filter { $0.url != url })
    }

    private func write(_ all: [RuleModuleRepositorySubscription]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
    }
}

/// The repositories' page: each subscription with its index read again when the page opens
/// (maintainer, 2026-10-17: updates are checked then and applied only on 「更新」).
@MainActor
final class RuleModuleRepositoryModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(RuleModuleRepositoryIndex)
        case failed(String)
    }

    struct Repository: Identifiable, Equatable {
        var subscription: RuleModuleRepositorySubscription
        var state: State
        var id: URL { subscription.url }

        var index: RuleModuleRepositoryIndex? {
            if case .loaded(let index) = state { return index }
            return nil
        }
    }

    static let shared = RuleModuleRepositoryModel()

    @Published private(set) var repositories: [Repository] = []
    /// Why the last unsubscription failed.
    @Published var message: String?

    private let store: RuleModuleRepositoryStore
    let library: RuleModuleLibrary
    private let download: (String) async throws -> (data: Data, url: URL)

    init(store: RuleModuleRepositoryStore = RuleModuleRepositoryStore(), library: RuleModuleLibrary? = nil,
         download: @escaping (String) async throws -> (data: Data, url: URL) = { try await RuleModuleClient.download($0) }) {
        self.store = store
        self.library = library ?? .shared
        self.download = download
    }

    func status(of entry: RuleModuleRepositoryIndex.Entry) -> RuleModuleRepositoryStatus {
        RuleModuleRepositoryStatus(entry, installed: library.installed)
    }

    /// Every subscription, each index read again.
    func load() async {
        await library.loadIfNeeded()
        repositories = store.list().map { Repository(subscription: $0, state: .loading) }
        for repository in repositories {
            await reload(repository.id)
        }
    }

    /// A repository read through the import sheet (`RuleModuleImportModel`), the one way in.
    func keep(_ index: RuleModuleRepositoryIndex, from url: URL) throws {
        let subscription = RuleModuleRepositorySubscription(url: url, name: index.name)
        try store.add(subscription)
        let repository = Repository(subscription: subscription, state: .loaded(index))
        if let position = repositories.firstIndex(where: { $0.id == url }) {
            repositories[position] = repository
        } else {
            repositories.append(repository)
        }
    }

    /// One repository's index read again (its page's 重新整理).
    func reload(_ url: URL) async {
        guard let position = repositories.firstIndex(where: { $0.id == url }) else { return }
        repositories[position].state = .loading
        let state = await read(url)
        guard let position = repositories.firstIndex(where: { $0.id == url }) else { return }
        repositories[position].state = state
        if case .loaded(let index) = state, index.name != repositories[position].subscription.name {
            rename(position, to: index.name)
        }
    }

    /// What 選擇's 安裝 did with each chosen module.
    struct BatchOutcome: Equatable {
        struct Item: Equatable {
            let id: String
            let title: String
            /// Why it was not installed; nil for one that waits for its preview.
            var message: String?
        }

        var installed: [String] = []
        var updated: [String] = []
        /// Updates that add a site: each goes through the import sheet's preview instead.
        var needsReview: [Item] = []
        var failed: [Item] = []
    }

    /// 選擇 then 安裝 (maintainer, 2026-10-17: 「多選後一次安裝／更新」): each chosen module read,
    /// validated and written in turn. An update that adds a site is not written — its preview
    /// says so first, as 更新 on one module does. Installed and official ones are passed over.
    func install(_ entries: [RuleModuleRepositoryIndex.Entry]) async -> BatchOutcome {
        var outcome = BatchOutcome()
        for entry in entries {
            switch status(of: entry) {
            case .installed, .official: continue
            case .notInstalled, .updateAvailable: break
            }
            do {
                let file = try await download(entry.url.absoluteString)
                let module = try RuleModuleValidator.validate(file.data)
                guard module.id == entry.id else {
                    throw RuleModuleRepositoryError.differentModule(listed: entry.id, file: module.id)
                }
                if let current = library.installed(id: entry.id), !current.isOfficial {
                    guard module.hosts(addedTo: current.module).isEmpty else {
                        outcome.needsReview.append(.init(id: entry.id, title: entry.title))
                        continue
                    }
                    try await library.update(id: entry.id, with: file.data, from: entry.url)
                    outcome.updated.append(entry.id)
                } else {
                    try await library.install(file.data, from: entry.url)
                    outcome.installed.append(entry.id)
                }
            } catch {
                let message = Self.message(for: error)
                AppLogger.info("module repository install skipped", context: ["module": entry.id, "reason": message])
                outcome.failed.append(.init(id: entry.id, title: entry.title, message: message))
            }
        }
        return outcome
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? RuleModuleRepositoryError { return error.message }
        if let error = error as? RuleModuleRejection { return error.message }
        if let error = error as? RuleModuleStoreError { return error.message }
        return String(format: localized("無法下載模組：%@"), error.localizedDescription)
    }

    func unsubscribe(_ url: URL) {
        do {
            try store.remove(url: url)
            repositories.removeAll { $0.id == url }
        } catch {
            AppLogger.error("Module repository not removed", error: error, context: ["address": url.absoluteString], level: .error)
            message = error.localizedDescription
        }
    }

    private func read(_ url: URL) async -> State {
        do {
            let file = try await download(url.absoluteString)
            return .loaded(try RuleModuleRepositoryIndex.parse(file.data, from: file.url))
        } catch let error as RuleModuleRepositoryError {
            AppLogger.info("module repository refused", context: ["address": url.absoluteString, "reason": error.message])
            return .failed(error.message)
        } catch {
            AppLogger.network("module repository download failed", error: SourceFailure.loggable(error),
                              context: ["address": url.absoluteString])
            return .failed(String(format: localized("無法下載模組倉庫：%@"), error.localizedDescription))
        }
    }

    private func rename(_ position: Int, to name: String) {
        var subscription = repositories[position].subscription
        subscription.name = name
        repositories[position].subscription = subscription
        do {
            try store.add(subscription)
        } catch {
            AppLogger.error("Module repository not renamed", error: error, context: ["address": subscription.url.absoluteString],
                            level: .warning)
        }
    }
}
