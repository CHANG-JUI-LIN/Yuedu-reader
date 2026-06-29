import Combine
import Foundation

/// Completes imports that the Share Extension can only *queue*.
///
/// The Share Extension (`ShareViewController`) runs in its own process and
/// cannot touch app stores directly, so it writes payloads into the App Group:
///   - `shared_import_items_queue` — generic file / remote URL payload metadata
///   - `shared_import_payloads/` — large shared files copied by the extension
///
/// Legacy queues are still drained for users who queued data before upgrading:
///   - `shared_book_sources_queue` — raw Legado book-source JSON `Data` blobs
///   - `shared_source_urls_queue`  — book-source URL strings
///
/// Call `bind(bookStore:)` before draining so local books can be imported into
/// the same `BookStore` instance the UI uses. Call `drain()` on launch and
/// whenever the app returns to the foreground.
@MainActor
final class SharedImportQueueDrainer: ObservableObject {
    static let shared = SharedImportQueueDrainer()

    nonisolated static let appGroupID = "group.com.zhangruilin.yuedureader"
    nonisolated static let payloadQueueKey = "shared_import_items_queue"
    nonisolated static let payloadDirectoryName = "shared_import_payloads"
    nonisolated static let bookSourcesQueueKey = "shared_book_sources_queue"
    nonisolated static let sourceURLsQueueKey = "shared_source_urls_queue"

    /// Result of the most recent non-empty drain, for surfacing user feedback.
    struct Outcome: Equatable {
        var importedCount: Int
        var failureCount: Int
        var importedBookCount = 0
        var importedBookSourceCount = 0
        var importedRSSCount = 0
        var importedReplaceRuleCount = 0

        mutating func record(_ result: ImportResult) {
            importedCount += result.count
            switch result.category {
            case .book:
                importedBookCount += result.count
            case .bookSource:
                importedBookSourceCount += result.count
            case .rss:
                importedRSSCount += result.count
            case .replaceRule:
                importedReplaceRuleCount += result.count
            }
        }

        mutating func recordFailure() {
            failureCount += 1
        }
    }

    enum StorageKind: String, Codable, Equatable {
        case file
        case remoteURL
    }

    struct QueuedPayload: Codable, Equatable {
        var id: String
        var storageKind: StorageKind
        var relativePath: String?
        var remoteURLString: String?
        var suggestedFilename: String?
        var typeIdentifier: String?
        var createdAt: Date

        init(
            id: String = UUID().uuidString,
            storageKind: StorageKind,
            relativePath: String? = nil,
            remoteURLString: String? = nil,
            suggestedFilename: String? = nil,
            typeIdentifier: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.storageKind = storageKind
            self.relativePath = relativePath
            self.remoteURLString = remoteURLString
            self.suggestedFilename = suggestedFilename
            self.typeIdentifier = typeIdentifier
            self.createdAt = createdAt
        }
    }

    enum ImportCategory: Equatable {
        case book
        case bookSource
        case rss
        case replaceRule
    }

    struct ImportResult: Equatable {
        var count: Int
        var category: ImportCategory
    }

    enum ImportError: LocalizedError {
        case missingPayloadDirectory
        case missingQueuedFile(String)
        case missingBookStore
        case invalidRemoteURL(String)
        case unsupportedPayload(String)

        var errorDescription: String? {
            switch self {
            case .missingPayloadDirectory:
                return "App Group import directory is unavailable"
            case .missingQueuedFile(let path):
                return "Queued shared file is missing: \(path)"
            case .missingBookStore:
                return "BookStore is not bound before draining shared imports"
            case .invalidRemoteURL(let url):
                return "Invalid shared URL: \(url)"
            case .unsupportedPayload(let name):
                return "Unsupported shared import payload: \(name)"
            }
        }
    }

    /// Set after a drain that processed at least one queued item. The UI observes
    /// this to show a toast, then resets it to `nil`.
    @Published var lastOutcome: Outcome?

    private let defaults: UserDefaults?
    private let payloadDirectoryURL: URL?
    private let importData: (Data) throws -> Int
    private let fetchURL: (URL) async throws -> Data
    private let importBookFileOverride: ((URL) async throws -> Int)?
    private let importOPMLData: (Data) throws -> Int
    private let importLegadoRSSData: (Data) throws -> Int
    private let importReplaceRuleData: (Data) throws -> Int
    private weak var bookStore: BookStore?
    private var isDraining = false

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: SharedImportQueueDrainer.appGroupID),
        payloadDirectoryURL: URL? = SharedImportQueueDrainer.defaultPayloadDirectoryURL(),
        importData: @escaping (Data) throws -> Int = {
            try BookSourceStore.shared.importFromData($0, fileExtension: "json")
        },
        fetchURL: @escaping (URL) async throws -> Data = {
            try await URLSession.shared.data(from: $0).0
        },
        importBookFile: ((URL) async throws -> Int)? = nil,
        importOPMLData: @escaping (Data) throws -> Int = { data in
            let sources = try RSSOPMLParser.parse(data: data)
            return RSSStore.shared.addSourcesReturningAdded(sources).count
        },
        importLegadoRSSData: @escaping (Data) throws -> Int = { data in
            let sources = try LegadoSourceJSONParser.parse(data: data)
            return RSSStore.shared.addSourcesReturningAdded(sources).count
        },
        importReplaceRuleData: @escaping (Data) throws -> Int = {
            try ReplaceRuleStore.shared.importFromLegadoData($0)
        }
    ) {
        self.defaults = defaults
        self.payloadDirectoryURL = payloadDirectoryURL
        self.importData = importData
        self.fetchURL = fetchURL
        self.importBookFileOverride = importBookFile
        self.importOPMLData = importOPMLData
        self.importLegadoRSSData = importLegadoRSSData
        self.importReplaceRuleData = importReplaceRuleData
    }

    nonisolated static func defaultPayloadDirectoryURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(payloadDirectoryName, isDirectory: true)
    }

    func bind(bookStore: BookStore) {
        self.bookStore = bookStore
    }

    /// Drain all known queues. Safe to call repeatedly; queues are cleared as
    /// they're read, and a re-entrancy guard prevents overlapping runs.
    @discardableResult
    func drain() async -> Outcome {
        guard let defaults, !isDraining else {
            return Outcome(importedCount: 0, failureCount: 0)
        }
        isDraining = true
        defer { isDraining = false }

        var outcome = Outcome(importedCount: 0, failureCount: 0)

        await drainGenericPayloadQueue(defaults: defaults, outcome: &outcome)
        await drainLegacyBookSourceDataQueue(defaults: defaults, outcome: &outcome)
        await drainLegacyBookSourceURLQueue(defaults: defaults, outcome: &outcome)

        if outcome.importedCount > 0 || outcome.failureCount > 0 {
            lastOutcome = outcome
        }
        return outcome
    }

    private func drainGenericPayloadQueue(defaults: UserDefaults, outcome: inout Outcome) async {
        guard let queue = defaults.array(forKey: Self.payloadQueueKey) as? [Data],
              !queue.isEmpty else { return }

        defaults.removeObject(forKey: Self.payloadQueueKey)
        let decoder = JSONDecoder()
        for encoded in queue {
            do {
                let payload = try decoder.decode(QueuedPayload.self, from: encoded)
                let result = try await importQueuedPayload(payload)
                outcome.record(result)
            } catch {
                outcome.recordFailure()
                AppLogger.error("Shared payload import failed", error: error)
            }
        }
    }

    private func drainLegacyBookSourceDataQueue(defaults: UserDefaults, outcome: inout Outcome) async {
        guard let jsonQueue = defaults.array(forKey: Self.bookSourcesQueueKey) as? [Data],
              !jsonQueue.isEmpty else { return }

        defaults.removeObject(forKey: Self.bookSourcesQueueKey)
        for data in jsonQueue {
            do {
                outcome.record(.init(count: try importData(data), category: .bookSource))
            } catch {
                outcome.recordFailure()
                AppLogger.error("Shared book-source JSON import failed", error: error)
            }
        }
    }

    private func drainLegacyBookSourceURLQueue(defaults: UserDefaults, outcome: inout Outcome) async {
        guard let urlQueue = defaults.array(forKey: Self.sourceURLsQueueKey) as? [String],
              !urlQueue.isEmpty else { return }

        defaults.removeObject(forKey: Self.sourceURLsQueueKey)
        for urlString in urlQueue {
            guard let url = URL(string: urlString) else {
                outcome.recordFailure()
                continue
            }
            do {
                let data = try await fetchURL(url)
                outcome.record(.init(count: try importData(data), category: .bookSource))
            } catch {
                outcome.recordFailure()
                AppLogger.network(
                    "Shared book-source URL import failed",
                    error: error,
                    context: ["url": urlString]
                )
            }
        }
    }

    private func importQueuedPayload(_ payload: QueuedPayload) async throws -> ImportResult {
        switch payload.storageKind {
        case .file:
            guard let fileURL = queuedFileURL(for: payload) else {
                throw ImportError.missingPayloadDirectory
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ImportError.missingQueuedFile(fileURL.path)
            }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            return try await importFilePayload(fileURL, suggestedFilename: payload.suggestedFilename)

        case .remoteURL:
            guard let rawURL = payload.remoteURLString,
                  let url = URL(string: rawURL) else {
                throw ImportError.invalidRemoteURL(payload.remoteURLString ?? "")
            }
            let data = try await fetchURL(url)
            return try await importDataPayload(
                data,
                fileExtension: url.pathExtension,
                suggestedFilename: url.lastPathComponent
            )
        }
    }

    private func queuedFileURL(for payload: QueuedPayload) -> URL? {
        guard let payloadDirectoryURL,
              let relativePath = payload.relativePath else { return nil }
        return payloadDirectoryURL.appendingPathComponent(relativePath)
    }

    private func importFilePayload(_ url: URL, suggestedFilename: String?) async throws -> ImportResult {
        let fileExtension = effectiveFileExtension(for: url, suggestedFilename: suggestedFilename)
        let classification = try SharedImportPayloadClassifier.classify(
            fileURL: url,
            fileExtension: fileExtension,
            suggestedFilename: suggestedFilename
        )

        switch classification {
        case .bookSource(let ext):
            let data = try Data(contentsOf: url)
            return .init(count: try importBookSources(data, fileExtension: ext), category: .bookSource)
        case .rssOPML:
            return .init(count: try importOPMLData(Data(contentsOf: url)), category: .rss)
        case .rssLegadoJSON:
            return .init(count: try importLegadoRSSData(Data(contentsOf: url)), category: .rss)
        case .replaceRules:
            return .init(count: try importReplaceRuleData(Data(contentsOf: url)), category: .replaceRule)
        case .localBook:
            return .init(count: try await importBookFile(url), category: .book)
        }
    }

    private func importDataPayload(
        _ data: Data,
        fileExtension: String,
        suggestedFilename: String?
    ) async throws -> ImportResult {
        let classification = try SharedImportPayloadClassifier.classify(
            data: data,
            fileExtension: fileExtension,
            suggestedFilename: suggestedFilename
        )

        switch classification {
        case .bookSource(let ext):
            return .init(count: try importBookSources(data, fileExtension: ext), category: .bookSource)
        case .rssOPML:
            return .init(count: try importOPMLData(data), category: .rss)
        case .rssLegadoJSON:
            return .init(count: try importLegadoRSSData(data), category: .rss)
        case .replaceRules:
            return .init(count: try importReplaceRuleData(data), category: .replaceRule)
        case .localBook(let ext):
            let tempURL = try writeTemporaryPayload(
                data,
                fileExtension: ext,
                suggestedFilename: suggestedFilename
            )
            defer { try? FileManager.default.removeItem(at: tempURL) }
            return .init(count: try await importBookFile(tempURL), category: .book)
        }
    }

    private func importBookSources(_ data: Data, fileExtension: String) throws -> Int {
        if fileExtension.lowercased() == "json" {
            return try importData(data)
        }
        return try BookSourceStore.shared.importFromData(data, fileExtension: fileExtension)
    }

    private func importBookFile(_ url: URL) async throws -> Int {
        if let importBookFileOverride {
            return try await importBookFileOverride(url)
        }
        guard let bookStore else {
            throw ImportError.missingBookStore
        }

        let ext = url.pathExtension.lowercased()
        if ext == "epub" {
            _ = try await bookStore.importEpub(url: url)
            return 1
        }

        if LocalAudiobookArchive.supports(url) {
            _ = try await bookStore.importLocalAudiobook(url: url)
            return 1
        }

        if ext == "zip" {
            if await LocalAudiobookArchive.zipContainsAudio(url) {
                _ = try await bookStore.importLocalAudiobook(url: url)
            } else {
                _ = try await bookStore.importLocalManga(url: url)
            }
            return 1
        }

        if LocalMangaArchive.supports(url) {
            _ = try await bookStore.importLocalManga(url: url)
            return 1
        }

        let parsed = try await BookParserRegistry.parse(url: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = parsed.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? fallbackTitle : title
        let resolvedAuthor: String
        if author.isEmpty || author == "Unknown Author" || author == "未知作者" {
            resolvedAuthor = localized("未知作者")
        } else {
            resolvedAuthor = author
        }

        if ext == "md" || ext == "markdown" {
            _ = try bookStore.importMarkdown(url: url, title: resolvedTitle, author: resolvedAuthor)
        } else {
            _ = try bookStore.importWeb(
                content: parsed.storageText,
                title: resolvedTitle,
                author: resolvedAuthor,
                sourceURL: "local"
            )
        }
        return 1
    }

    private func effectiveFileExtension(for url: URL, suggestedFilename: String?) -> String {
        if let suggestedFilename {
            let suggestedExt = (suggestedFilename as NSString).pathExtension.lowercased()
            if !suggestedExt.isEmpty { return suggestedExt }
        }
        return url.pathExtension.lowercased()
    }

    private func writeTemporaryPayload(
        _ data: Data,
        fileExtension: String,
        suggestedFilename: String?
    ) throws -> URL {
        let ext = SharedImportPayloadClassifier.normalizedLocalBookExtension(
            fileExtension,
            suggestedFilename: suggestedFilename
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }
}

enum SharedImportPayloadClassification: Equatable {
    case bookSource(fileExtension: String)
    case rssOPML
    case rssLegadoJSON
    case replaceRules
    case localBook(fileExtension: String)
}

enum SharedImportPayloadClassifier {
    private static let directLocalBookExtensions = Set([
        "epub", "cbz", "zip",
        "mp3", "m4a", "m4b", "aac", "flac", "wav"
    ])

    private static let textLocalBookExtensions = Set([
        "txt", "md", "markdown", "json"
    ])

    static func classify(
        fileURL: URL,
        fileExtension: String,
        suggestedFilename: String?
    ) throws -> SharedImportPayloadClassification {
        let ext = normalizedExtension(fileExtension, suggestedFilename: suggestedFilename)

        if directLocalBookExtensions.contains(ext) {
            return .localBook(fileExtension: ext)
        }

        if ["yds", "xbs", "mrs"].contains(ext) {
            return .bookSource(fileExtension: ext)
        }

        let sample = try readSample(from: fileURL)
        if ext == "opml" || looksLikeOPML(sample) {
            return .rssOPML
        }
        if ext == "xml", looksLikeXML(sample) {
            return .rssOPML
        }

        if ext == "json" || looksLikeJSON(sample) {
            let data = try Data(contentsOf: fileURL)
            return try classify(data: data, fileExtension: ext, suggestedFilename: suggestedFilename)
        }

        if textLocalBookExtensions.contains(ext) || looksLikeText(sample) {
            return .localBook(fileExtension: normalizedLocalBookExtension(ext, suggestedFilename: suggestedFilename))
        }

        throw SharedImportQueueDrainer.ImportError.unsupportedPayload(fileURL.lastPathComponent)
    }

    static func classify(
        data: Data,
        fileExtension: String,
        suggestedFilename: String?
    ) throws -> SharedImportPayloadClassification {
        let ext = normalizedExtension(fileExtension, suggestedFilename: suggestedFilename)

        if ["yds", "xbs", "mrs"].contains(ext) {
            return .bookSource(fileExtension: ext)
        }

        if ext == "opml" || looksLikeOPML(data) {
            return .rssOPML
        }

        if ext == "xml", looksLikeXML(data) {
            return .rssOPML
        }

        if ext == "json" || looksLikeJSON(data) {
            let root: Any
            do {
                root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            } catch {
                if textLocalBookExtensions.contains(ext) || looksLikeText(data) {
                    let fallbackExt = ext == "json"
                        ? "txt"
                        : normalizedLocalBookExtension(ext, suggestedFilename: suggestedFilename)
                    return .localBook(fileExtension: fallbackExt)
                }
                throw error
            }
            if looksLikeBookSourceRoot(root) {
                return .bookSource(fileExtension: ext.isEmpty ? "json" : ext)
            }
            if looksLikeRSSRoot(root) {
                return .rssLegadoJSON
            }
            if looksLikeReplaceRuleRoot(root) {
                return .replaceRules
            }
            return .localBook(fileExtension: "json")
        }

        if directLocalBookExtensions.contains(ext) || textLocalBookExtensions.contains(ext) || looksLikeText(data) {
            return .localBook(fileExtension: normalizedLocalBookExtension(ext, suggestedFilename: suggestedFilename))
        }

        throw SharedImportQueueDrainer.ImportError.unsupportedPayload(suggestedFilename ?? ext)
    }

    static func normalizedLocalBookExtension(_ ext: String, suggestedFilename: String?) -> String {
        let normalized = normalizedExtension(ext, suggestedFilename: suggestedFilename)
        if normalized == "markdown" { return "markdown" }
        if normalized.isEmpty { return "txt" }
        return normalized
    }

    private static func normalizedExtension(_ ext: String, suggestedFilename: String?) -> String {
        let lower = ext.lowercased()
        if !lower.isEmpty { return lower }
        if let suggestedFilename {
            let suggestedExt = (suggestedFilename as NSString).pathExtension.lowercased()
            if !suggestedExt.isEmpty { return suggestedExt }
        }
        return ""
    }

    private static func readSample(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4096) ?? Data()
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let byte = data.first(where: { ![9, 10, 13, 32].contains($0) }) else {
            return false
        }
        return byte == 0x7B || byte == 0x5B
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        guard let string = String(data: data.prefix(512), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return string.hasPrefix("<")
    }

    private static func looksLikeOPML(_ data: Data) -> Bool {
        guard let string = String(data: data.prefix(2048), encoding: .utf8)?
            .lowercased() else { return false }
        return string.contains("<opml")
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        let printableCount = data.reduce(0) { partial, byte in
            if byte == 9 || byte == 10 || byte == 13 { return partial + 1 }
            if (32...126).contains(byte) { return partial + 1 }
            if byte >= 0x80 { return partial + 1 }
            return partial
        }
        return Double(printableCount) / Double(data.count) > 0.85
    }

    private static func looksLikeBookSourceRoot(_ root: Any) -> Bool {
        if let dictionary = root as? [String: Any] {
            if dictionary["bookSources"] != nil { return true }
            return looksLikeBookSource(dictionary)
        }
        if let array = root as? [[String: Any]] {
            return array.contains(where: looksLikeBookSource)
        }
        return false
    }

    private static func looksLikeBookSource(_ dictionary: [String: Any]) -> Bool {
        if dictionary["bookSourceUrl"] != nil || dictionary["bookSourceName"] != nil {
            return true
        }
        if dictionary["searchUrl"] != nil,
           dictionary["ruleSearch"] != nil || dictionary["ruleBookInfo"] != nil || dictionary["ruleContent"] != nil {
            return true
        }
        return false
    }

    private static func looksLikeRSSRoot(_ root: Any) -> Bool {
        if let dictionary = root as? [String: Any] {
            return looksLikeRSSSource(dictionary)
        }
        if let array = root as? [[String: Any]] {
            return array.contains(where: looksLikeRSSSource)
        }
        return false
    }

    private static func looksLikeRSSSource(_ dictionary: [String: Any]) -> Bool {
        if dictionary["sourceUrl"] != nil || dictionary["sourceName"] != nil {
            return true
        }
        return dictionary["ruleArticles"] != nil
    }

    private static func looksLikeReplaceRuleRoot(_ root: Any) -> Bool {
        if let array = root as? [[String: Any]] {
            return array.contains(where: looksLikeReplaceRule)
        }
        guard let dictionary = root as? [String: Any] else {
            return false
        }
        if looksLikeReplaceRule(dictionary) { return true }
        for key in ["replaceRules", "replaceRule", "replaceRuleList", "rules"] {
            if let nested = dictionary[key], looksLikeReplaceRuleRoot(nested) {
                return true
            }
        }
        if let nested = dictionary["data"] {
            return looksLikeReplaceRuleRoot(nested)
        }
        return false
    }

    private static func looksLikeReplaceRule(_ dictionary: [String: Any]) -> Bool {
        dictionary["pattern"] != nil
            || dictionary["regex"] != nil
            || dictionary["replaceRegex"] != nil
    }
}
