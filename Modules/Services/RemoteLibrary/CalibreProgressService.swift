import Combine
import Foundation

enum CalibreProgressState: Equatable {
    case idle, syncing, synced, failed(String)
}

enum CalibreProgressError: LocalizedError {
    case loginRequired, unsupportedServer, preparing, unmappedPosition, invalidData
    case webUpdateFailed(String)
    var errorDescription: String? {
        switch self {
        case .loginRequired: return localized("Calibre 進度同步需要登入帳號")
        case .unsupportedServer: return localized("此伺服器不支援 Calibre 進度同步")
        case .preparing: return localized("Calibre 正在準備閱讀資料，請稍後重試")
        case .unmappedPosition: return localized("無法精確對應 Calibre 閱讀位置，已保留本機進度")
        case .invalidData: return localized("Calibre 閱讀資料無效")
        case .webUpdateFailed(let reason): return String(format: localized("Calibre 網頁進度回傳失敗：%@"), reason)
        }
    }
}

/// Explicitly enabled per connection. Updates native Calibre Content Server's
/// web reader position. Its annotation API discards last-read annotations, and
/// the standalone desktop viewer does not load this user's web position.
/// Calibre-Web's session bookmark/Kobo APIs are also different.
/// Failed work is durable and retried only by the user's retry action.
@MainActor
final class CalibreProgressService: ObservableObject {
    @Published private(set) var states: [UUID: CalibreProgressState] = [:]
    private let connections: OPDSCatalogStore
    private let transportFactory: ((OPDSCatalog) -> any RemoteLibraryTransport)?
    private let storageURL: URL
    private let deviceID: String
    private var pending: [UUID: Snapshot] = [:]
    private var active: Set<UUID> = []
    private var completed: [UUID: Snapshot] = [:]

    private struct Snapshot: Codable, Equatable {
        let bookID: UUID
        let reference: RemoteBookReference
        let chapterHref: String
        let spineIndex: Int
        let originalOffset: Int
        let renderedText: String
        let contextOffset: Int
        let progress: Double
        /// Captured with the reading snapshot and unchanged by manual retry.
        /// Optional for migration of older pending records.
        let savedAt: Date?
        let isVertical: Bool?

        func hasSameLocation(as other: Snapshot) -> Bool {
            bookID == other.bookID && reference == other.reference && chapterHref == other.chapterHref
                && spineIndex == other.spineIndex && originalOffset == other.originalOffset
                && renderedText == other.renderedText && contextOffset == other.contextOffset
                && isVertical == other.isVertical
        }
    }

    init(connections: OPDSCatalogStore = .shared,
         storageDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CalibreProgress", isDirectory: true),
         defaults: UserDefaults = .standard,
         transportFactory: ((OPDSCatalog) -> any RemoteLibraryTransport)? = nil) {
        self.connections = connections
        self.transportFactory = transportFactory
        self.storageURL = storageDirectory.appendingPathComponent("pending.json")
        let key = "calibre_progress_device_id"
        if let existing = defaults.string(forKey: key) { deviceID = existing }
        else { deviceID = "Yuedu-" + UUID().uuidString; defaults.set(deviceID, forKey: key) }
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let saved = try JSONDecoder().decode([Snapshot].self, from: Data(contentsOf: storageURL))
                pending = Dictionary(saved.map { ($0.bookID, $0) }, uniquingKeysWith: { _, new in new })
                for id in pending.keys { states[id] = .failed(localized("上次 Calibre 進度尚未回傳")) }
            } catch { AppLogger.error("Unable to load pending Calibre progress: \(error)") }
        }
    }

    func state(for bookID: UUID) -> CalibreProgressState { states[bookID] ?? .idle }

    func save(book: ReadingBook, session: PublicationSession,
              position: CoreTextReadingPosition, renderedText: String, isVertical: Bool = false) async {
        guard session.chapters.indices.contains(position.spineIndex) else { return }
        await save(book: book, chapterHref: session.chapters[position.spineIndex].href,
                   position: position, renderedText: renderedText, isVertical: isVertical)
    }

    /// Also usable with a restored reader snapshot; no session/client is retained
    /// after the reader closes. Persist at most 1024 UTF-16 units of nearby text.
    func save(book: ReadingBook, chapterHref: String,
              position: CoreTextReadingPosition, renderedText: String, isVertical: Bool = false) async {
        guard let reference = book.remoteSource, reference.format.fileExtension == "epub",
              let connection = connections.connection(id: reference.connectionID),
              connection.kind == .calibre, connection.syncProgress else { return }
        let text = renderedText as NSString
        guard position.charOffset >= 0, position.charOffset < text.length,
              text.character(at: position.charOffset) != 0xFFFC,
              text.substring(from: position.charOffset).unicodeScalars.contains(where: {
                  !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0xFFFC
              }) else { return }
        let range = text.rangeOfComposedCharacterSequences(for:
            NSRange(location: max(0, position.charOffset - 512),
                    length: min(text.length, position.charOffset + 512) - max(0, position.charOffset - 512)))
        let snapshot = Snapshot(bookID: book.id, reference: reference, chapterHref: chapterHref,
            spineIndex: position.spineIndex, originalOffset: position.charOffset,
            renderedText: text.substring(with: range), contextOffset: position.charOffset - range.location,
            progress: min(1, max(0, book.currentPosition.isFinite ? book.currentPosition : 0)), savedAt: Date(),
            isVertical: isVertical)
        if completed[book.id]?.hasSameLocation(as: snapshot) == true
            || pending[book.id]?.hasSameLocation(as: snapshot) == true { return }
        pending[book.id] = snapshot
        guard persist(bookID: book.id) else { return }
        // New local progress replaces stale pending work, but an earlier error
        // never causes an unsolicited retry during subsequent page turns.
        if case .failed = state(for: book.id) { return }
        await process(bookID: book.id)
    }

    func retry(bookID: UUID) async { await process(bookID: bookID) }

    private func process(bookID: UUID) async {
        guard !active.contains(bookID), pending[bookID] != nil else { return }
        active.insert(bookID)
        defer { active.remove(bookID) }
        while let snapshot = pending[bookID] {
            guard let connection = connections.connection(id: snapshot.reference.connectionID),
                  connection.kind == .calibre, connection.syncProgress else {
                states[bookID] = .idle
                return
            }
            states[bookID] = .syncing
            do {
                try Task.checkCancellation()
                guard connection.username?.isEmpty == false else { throw CalibreProgressError.loginRequired }
                let locator: CalibreBookLocator
                do { locator = try CalibreBookLocator(reference: snapshot.reference, connection: connection) }
                catch { throw CalibreProgressError.unsupportedServer }
                let transport = transportFactory?(connection) ?? connections.httpClient(for: connection)
                let libraries = try await CalibreServerAPI(address: locator.address, transport: transport).libraryInfo()
                guard libraries.libraryMap[locator.libraryID] != nil else { throw CalibreProgressError.unsupportedServer }
                let query = [URLQueryItem(name: "library_id", value: locator.libraryID)]
                let manifestURL = try locator.address.endpoint(["book-manifest", String(locator.bookID), "EPUB"], queryItems: query)
                let manifestData = try await request(manifestURL, transport: transport)
                guard pending[bookID] == snapshot else { continue }
                guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
                    throw CalibreProgressError.invalidData
                }
                if manifest["job_status"] != nil { throw CalibreProgressError.preparing }
                guard let spine = manifest["spine"] as? [String],
                      let hash = manifest["book_hash"] as? [String: Any],
                      let size = hash["size"] as? Int64, let mtime = hash["mtime"] as? Int64,
                      let index = spine.firstIndex(where: { Self.path($0) == Self.path(snapshot.chapterHref) }) else {
                    throw CalibreProgressError.unmappedPosition
                }
                let fileURL = try locator.address.endpoint(
                    ["book-file", String(locator.bookID), "EPUB", String(size), String(mtime)]
                        + spine[index].split(separator: "/").map(String.init), queryItems: query)
                let document = try await request(fileURL, transport: transport)
                // A page/scene event may have saved a newer position while the
                // manifest or chapter was loading. Coalesce to that snapshot
                // before any write, retaining its own original reading time.
                guard pending[bookID] == snapshot else { continue }
                let matched = try CalibreCFIMapper.match(document: document, spineIndex: index,
                    renderedText: snapshot.renderedText, charOffset: snapshot.contextOffset,
                    isVertical: snapshot.isVertical ?? false)
                try Task.checkCancellation()
                // Re-check opt-in immediately before the external write, including
                // when the user disabled it while the prepared chapter was loading.
                guard connections.connection(id: connection.id)?.syncProgress == true else {
                    states[bookID] = .idle
                    return
                }
                let endpoint = try locator.address.endpoint(["book-set-last-read-position", locator.libraryID,
                                                            String(locator.bookID), "EPUB"])
                var post = URLRequest(url: endpoint)
                post.httpMethod = "POST"
                post.setValue("application/json", forHTTPHeaderField: "Content-Type")
                post.httpBody = try JSONSerialization.data(withJSONObject:
                    ["device": deviceID, "cfi": matched.cfi, "pos_frac": snapshot.progress])
                do {
                    let (_, response) = try await transport.data(for: post)
                    try RemoteLibraryHTTPClient.validate(response)
                } catch { throw CalibreProgressError.webUpdateFailed(error.localizedDescription) }
                completed[bookID] = snapshot
                if pending[bookID] == snapshot { pending.removeValue(forKey: bookID) }
                guard persist(bookID: bookID) else { return }
                states[bookID] = .synced
            } catch {
                states[bookID] = .failed(error.localizedDescription)
                AppLogger.error("Calibre progress upload failed for \(bookID): \(error)")
                return
            }
        }
    }

    private static func path(_ value: String) -> String {
        let stripped = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        return (stripped.removingPercentEncoding ?? stripped).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func request(_ url: URL, transport: any RemoteLibraryTransport) async throws -> Data {
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        try RemoteLibraryHTTPClient.validate(response)
        return data
    }

    @discardableResult
    private func persist(bookID: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(pending.values)).write(to: storageURL, options: .atomic)
            return true
        } catch {
            states[bookID] = .failed(error.localizedDescription)
            AppLogger.error("Unable to save pending Calibre progress: \(error)")
            return false
        }
    }
}
