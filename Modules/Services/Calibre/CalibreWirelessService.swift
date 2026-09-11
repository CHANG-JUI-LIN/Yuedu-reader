import Combine
import Foundation
@preconcurrency import Network
import UIKit

struct CalibreDiscoveredServer: Identifiable, Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

enum CalibreWirelessState: Equatable {
    case disconnected, connecting, connected(String), failed(String)

    var isActive: Bool {
        switch self { case .connecting, .connected: true; default: false }
    }
}

struct CalibreTransferStatus: Identifiable, Equatable {
    enum Phase: Equatable { case receiving, importing, completed, failed(String), cancelled }
    let id: UUID
    let title: String
    let totalBytes: Int64
    var receivedBytes: Int64 = 0
    var phase: Phase = .receiving
}

struct CalibreDeviceBook: Codable, Equatable {
    let libraryID: String
    var lpath: String
    let calibreUUID: String
    let fileExtension: String
    let bookID: UUID
    let sha256: String
    var metadata: [String: CalibreJSON]

    func matches(_ book: CalibreIncomingBook, libraryID: String) -> Bool {
        self.libraryID == libraryID && calibreUUID == book.uuid && fileExtension == book.fileExtension
    }
}

struct CalibreDeviceRegistry: Codable {
    var deviceInfo: [String: CalibreJSON] = ["device_store_uuid": .string(UUID().uuidString)]
    var books: [CalibreDeviceBook] = []

    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Calibre initiates each command after the iOS app connects to its advertised
/// wireless device socket. This is independent from the HTTP LAN API and OPDS.
@MainActor
final class CalibreWirelessService: ObservableObject {
    static let bonjourService = "_calibresmartdeviceapp._tcp"
    @Published private(set) var state: CalibreWirelessState = .disconnected
    @Published private(set) var servers: [CalibreDiscoveredServer] = []
    @Published private(set) var transfers: [CalibreTransferStatus] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var discoveryError: String?

    private let registryURL: URL
    private var registry = CalibreDeviceRegistry()
    private var browser: NWBrowser?
    private var task: Task<Void, Never>?
    private var transport: CalibreWirelessTransport?
    private var sessionID = UUID()
    private var libraryID = ""
    private var libraryName = ""
    private var initialized = false
    private var registryError: Error?
    private let isBookInUse: @MainActor (UUID) -> Bool

    init(registryURL: URL? = nil, isBookInUse: @escaping @MainActor (UUID) -> Bool = { ReadingResourceUsage.shared.isInUse(bookID: $0) }) {
        self.registryURL = registryURL ?? StorageLocations.support.appendingPathComponent("calibre-wireless-device.json")
        self.isBookInUse = isBookInUse
        do { registry = try CalibreDeviceRegistry.load(from: self.registryURL) }
        catch {
            registryError = error
            state = .failed(error.localizedDescription)
            AppLogger.error("Calibre device registry load failed: \(error)")
        }
    }

    func startDiscovery() {
        guard browser == nil else { return }
        discoveryError = nil
        isDiscovering = true
        let browser = NWBrowser(for: .bonjour(type: Self.bonjourService, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discovered = results.compactMap { result -> CalibreDiscoveredServer? in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                return CalibreDiscoveredServer(id: "\(name)|\(type)|\(domain)", name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                guard let self, self.browser === browser else { return }
                self.servers = discovered
            }
        }
        browser.stateUpdateHandler = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.browser === browser else { return }
                switch value {
                case .failed(let error), .waiting(let error):
                    self.discoveryError = error.localizedDescription
                    self.stopDiscovery()
                default: break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "com.yuedu.calibre-discovery"))
    }

    func stopDiscovery() {
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        isDiscovering = false
    }

    func connect(host: String, port: UInt16, password: String, store: BookStore) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains(where: \.isWhitespace), port > 0,
              let port = NWEndpoint.Port(rawValue: port) else {
            disconnect()
            state = .failed(CalibreWirelessError.invalidAddress.localizedDescription)
            return
        }
        connect(endpoint: .hostPort(host: .init(host), port: port), password: password, store: store)
    }

    func connect(server: CalibreDiscoveredServer, password: String, store: BookStore) {
        connect(endpoint: server.endpoint, password: password, store: store)
    }

    func disconnect() {
        sessionID = UUID()
        task?.cancel()
        task = nil
        if let transport { Task { await transport.cancel() } }
        transport = nil
        for index in transfers.indices where transfers[index].phase == .receiving || transfers[index].phase == .importing {
            transfers[index].phase = .cancelled
        }
        state = .disconnected
    }

    private func connect(endpoint: NWEndpoint, password: String, store: BookStore) {
        disconnect()
        guard registryError == nil else {
            state = .failed(registryError!.localizedDescription)
            return
        }
        stopDiscovery()
        state = .connecting
        initialized = false
        libraryID = ""
        libraryName = ""
        let session = sessionID
        let transport = CalibreWirelessTransport(endpoint: endpoint)
        self.transport = transport
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.connect()
                while !Task.isCancelled {
                    let frame = try await transport.readFrame()
                    guard self.sessionID == session else { throw CancellationError() }
                    let shouldContinue = try await self.handle(frame, password: password, store: store, transport: transport)
                    if !shouldContinue { break }
                }
                if self.sessionID == session { self.state = .disconnected }
            } catch {
                guard self.sessionID == session else { await transport.cancel(); return }
                if Task.isCancelled || error is CancellationError {
                    self.state = .disconnected
                } else {
                    let message = error.localizedDescription
                    self.state = .failed(message)
                    for index in self.transfers.indices where self.transfers[index].phase == .receiving || self.transfers[index].phase == .importing {
                        self.transfers[index].phase = .failed(message)
                    }
                    AppLogger.error("Calibre wireless session failed: \(error)")
                }
            }
            await transport.cancel()
            if self.sessionID == session { self.transport = nil; self.task = nil }
        }
    }

    private func handle(_ frame: CalibreFrame, password: String, store: BookStore, transport: CalibreWirelessTransport) async throws -> Bool {
        let arguments = frame.arguments
        guard initialized || [9, 17, 18].contains(frame.opcode) else { throw CalibreWirelessError.invalidFrame }
        switch frame.opcode {
        case 9: // GET_INITIALIZATION_INFO; the server validates the hash afterward.
            libraryID = arguments["currentLibraryUUID"]?.string ?? ""
            libraryName = String((arguments["currentLibraryName"]?.string ?? "Calibre").prefix(500))
            // Calibre's persisted drive name already includes its localized
            // device prefix. The handshake must send the raw iOS identity.
            let name = UIDevice.current.name
            try await transport.send(CalibreWirelessHandshake.response(to: arguments, password: password, deviceName: name))
            initialized = true
        case 3: // GET_DEVICE_INFORMATION establishes a successful handshake.
            state = .connected(libraryName)
            AppLogger.info("[CalibreWireless] authenticated device session")
            try await transport.send(CalibreFrame(0, ["device_info": .object(registry.deviceInfo), "device_version": .string(UIDevice.current.systemVersion), "version": .string("1.0")]))
        case 1:
            registry.deviceInfo = arguments
            try registry.save(to: registryURL)
            try await transport.send(CalibreFrame(0))
        case 2:
            registry.deviceInfo["device_name"] = arguments["name"]
            try registry.save(to: registryURL)
            try await transport.send(CalibreFrame(0))
        case 4, 5:
            let disk = try FileManager.default.attributesOfFileSystem(forPath: StorageLocations.support.path)
            let key: FileAttributeKey = frame.opcode == 4 ? .systemSize : .systemFreeSize
            let responseKey = frame.opcode == 4 ? "total_space_on_device" : "free_space_on_device"
            let size = (disk[key] as? NSNumber)?.int64Value ?? 0
            try await transport.send(CalibreFrame(0, [responseKey: .number(Double(size))]))
        case 6:
            let entries = registry.books.filter { entry in
                guard let book = store.readingBook(id: entry.bookID) else { return false }
                return FileManager.default.fileExists(atPath: StorageLocations.bookFile(book.contentFilename).path)
            }
            try await transport.send(CalibreFrame(0, ["count": .number(Double(entries.count))]))
            for entry in entries { try await transport.send(CalibreFrame(0, entry.metadata)) }
        case 7: break // SEND_BOOKLISTS is deliberately one-way. No ACK.
        case 16: // SEND_BOOK_METADATA is also one-way, including an empty list.
            if let metadata = arguments["data"]?.object, let path = metadata["lpath"]?.string,
               let index = registry.books.firstIndex(where: { $0.lpath == path }) {
                registry.books[index].metadata = metadata
                try registry.save(to: registryURL)
            }
        case 8:
            try await receiveBook(arguments, store: store, transport: transport)
        case 12:
            try await transport.send(CalibreFrame(0))
            return arguments["ejecting"] != .bool(true)
        case 13:
            try await deleteBooks(arguments, store: store, transport: transport)
        case 14:
            try await returnBookFile(arguments, store: store, transport: transport)
        case 17:
            try await transport.send(CalibreFrame(0))
            if arguments["messageKind"]?.integer == 1 { throw CalibreWirelessError.passwordRejected }
            if arguments["messageKind"]?.integer == 2 { throw CalibreWirelessError.unsupportedProtocol }
        case 18: throw CalibreWirelessError.busy
        case 19:
            libraryID = arguments["libraryUuid"]?.string ?? libraryID
            libraryName = String((arguments["libraryName"]?.string ?? libraryName).prefix(500))
            try await transport.send(CalibreFrame(0))
        default:
            try await transport.send(CalibreFrame(20, ["message": .string(CalibreWirelessError.unsupportedCommand.localizedDescription)]))
            throw CalibreWirelessError.unsupportedCommand
        }
        return true
    }

    private func receiveBook(_ arguments: [String: CalibreJSON], store: BookStore, transport: CalibreWirelessTransport) async throws {
        let sourceLibraryID = libraryID
        let incoming: CalibreIncomingBook
        let receiver: CalibreIncomingFile
        do {
            let disk = try FileManager.default.attributesOfFileSystem(forPath: StorageLocations.support.path)
            incoming = try CalibreIncomingBook(arguments: arguments, availableSpace: (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
            receiver = try CalibreIncomingFile(book: incoming)
        } catch {
            // Precise preflight rejection: Calibre has not started raw bytes yet.
            // Do not try to recover a stream after a framing or mid-file failure.
            try await transport.send(CalibreFrame(20, ["message": .string(error.localizedDescription)]))
            throw error
        }
        defer { receiver.cleanup() }
        let previous = registry.books.first { $0.matches(incoming, libraryID: sourceLibraryID) }
        // lpath is a protocol identifier, never a physical path. Calibre permits
        // the device to choose it; keep separate libraries from sharing one name.
        let logicalPath: String
        if let previous { logicalPath = previous.lpath }
        else if registry.books.contains(where: { $0.lpath == incoming.lpath }) {
            logicalPath = "\(UUID().uuidString).\(incoming.fileExtension)"
        } else { logicalPath = incoming.lpath }
        let statusID = UUID()
        AppLogger.info("[CalibreWireless] receive begin bytes=\(incoming.length) format=\(incoming.fileExtension)")
        transfers.append(CalibreTransferStatus(id: statusID, title: incoming.title, totalBytes: incoming.length))
        if transfers.count > 100 { transfers.removeFirst(transfers.count - 100) }
        try await transport.send(CalibreFrame(0, ["lpath": .string(logicalPath)]))
        while receiver.received < incoming.length {
            let chunk = try await transport.readBinary(upTo: Int(min(Int64(CalibreWireBuffer.packetLength), incoming.length - receiver.received)))
            try Task.checkCancellation()
            try receiver.append(chunk)
            updateTransfer(statusID, received: receiver.received)
        }
        let staged = try receiver.finish()
        updateTransfer(statusID, phase: .importing)
        try Task.checkCancellation()
        let imported: ReadingBook
        if let previous,
           let existing = store.readingBook(id: previous.bookID),
           FileManager.default.fileExists(atPath: StorageLocations.bookFile(existing.contentFilename).path) {
            guard previous.sha256 == staged.sha256 else { throw CalibreWirelessError.changedBook }
            imported = existing
        } else {
            imported = try await LocalBookImportService.importBook(at: staged.url, title: incoming.title, author: incoming.author, store: store)
        }
        var metadata = incoming.metadata
        metadata["lpath"] = .string(logicalPath)
        metadata["size"] = .number(Double(incoming.length))
        metadata["uuid"] = .string(incoming.uuid)
        registry.books.removeAll { $0.matches(incoming, libraryID: sourceLibraryID) }
        registry.books.append(CalibreDeviceBook(libraryID: sourceLibraryID, lpath: logicalPath, calibreUUID: incoming.uuid, fileExtension: incoming.fileExtension, bookID: imported.id, sha256: staged.sha256, metadata: metadata))
        try registry.save(to: registryURL)
        updateTransfer(statusID, phase: .completed)
        AppLogger.info("[CalibreWireless] receive imported bookID=\(imported.id) bytes=\(incoming.length)")
        // Calibre 9.14 expects NO final ACK or BOOK_DONE after these raw bytes.
        // Only local import + registry commit make the UI report completion.
    }

    private func updateTransfer(_ id: UUID, received: Int64? = nil, phase: CalibreTransferStatus.Phase? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if let received { transfers[index].receivedBytes = received }
        if let phase { transfers[index].phase = phase }
    }

    private func deleteBooks(_ arguments: [String: CalibreJSON], store: BookStore, transport: CalibreWirelessTransport) async throws {
        guard let rawPaths = arguments["lpaths"]?.array, rawPaths.count <= 10_000 else { throw CalibreWirelessError.invalidFrame }
        let paths = rawPaths.compactMap(\.string)
        guard paths.count == rawPaths.count else { throw CalibreWirelessError.invalidFrame }
        guard !registry.books.contains(where: { paths.contains($0.lpath) && isBookInUse($0.bookID) }) else {
            let error = CalibreWirelessError.message(localized("書籍正在閱讀中，請關閉閱讀器後再從 Calibre 刪除"))
            try await transport.send(CalibreFrame(20, ["message": .string(error.localizedDescription)]))
            throw error
        }
        var removed: [String] = []
        for path in paths {
            if let entry = registry.books.first(where: { $0.lpath == path }) {
                // A desktop device-list delete can touch only files registered
                // by this receiver, never OPDS references or unrelated imports.
                store.delete(bookId: entry.bookID)
                registry.books.removeAll { $0.bookID == entry.bookID }
                removed.append(entry.calibreUUID)
            } else { removed.append("") }
        }
        try registry.save(to: registryURL)
        try await transport.send(CalibreFrame(0))
        for uuid in removed { try await transport.send(CalibreFrame(0, ["uuid": .string(uuid)])) }
    }

    private func returnBookFile(_ arguments: [String: CalibreJSON], store: BookStore, transport: CalibreWirelessTransport) async throws {
        guard let path = arguments["lpath"]?.string,
              let entry = registry.books.first(where: { $0.lpath == path }),
              let book = store.readingBook(id: entry.bookID),
              let position = arguments["position"]?.integer, position >= 0 else {
            try await transport.send(CalibreFrame(20, ["message": .string(CalibreWirelessError.invalidBook.localizedDescription)]))
            return
        }
        let url = StorageLocations.bookFile(book.contentFilename)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard position <= size else { throw CalibreWirelessError.invalidBook }
        try await transport.send(CalibreFrame(0, ["fileLength": .number(Double(size - position))]))
        try await transport.sendFile(url, position: UInt64(position))
    }
}
