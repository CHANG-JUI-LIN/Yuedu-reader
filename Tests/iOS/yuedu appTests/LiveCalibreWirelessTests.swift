import Combine
import Foundation
@preconcurrency import Network
import Testing
@testable import yuedu_app

/// Opt-in acceptance against the real desktop Calibre wireless device service.
/// After READY_FOR_SEND, the operator must send exactly one existing EPUB using
/// Calibre's Send to device button. At READY_FOR_EJECT, eject from the desktop,
/// then confirm its disconnected state through the separate operator gate.
/// This test never generates Calibre protocol commands.
@Suite("Live Calibre wireless acceptance", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_WIRELESS_HOST"] != nil))
@MainActor
struct LiveCalibreWirelessTests {
    @Test("Desktop Send to device imports a readable EPUB and reconnects with the same reading identity")
    func desktopSendAndReconnect() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try #require(environment["YUEDU_LIVE_CALIBRE_WIRELESS_HOST"])
        let portText = environment["YUEDU_LIVE_CALIBRE_WIRELESS_PORT"] ?? "9090"
        let port = try #require(UInt16(portText))
        let password = environment["YUEDU_LIVE_CALIBRE_WIRELESS_PASSWORD"] ?? ""
        let expectedTitle = environment["YUEDU_LIVE_CALIBRE_WIRELESS_EXPECTED_TITLE"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCalibreWireless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent("books.json")
        let registryURL = root.appendingPathComponent("device.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let service = CalibreWirelessService(registryURL: registryURL)
        defer {
            service.disconnect()
            // Only this isolated store's newly imported files are removed.
            for book in store.books { store.delete(bookId: book.id) }
        }
        let relay = try LiveCalibreWireRelay(host: host, port: port)
        defer { Task { await relay.shutdown() } }
        let localPort = try await liveDeadline(seconds: 30, stage: "start transparent relay") { try await relay.start() }
        service.connect(host: "127.0.0.1", port: localPort, password: password, store: store)
        try await waitForConnection(service, stage: "initial authentication")
        let emptyList = try await waitForDesktopList(relay, stage: "desktop initial device scan")
        #expect(emptyList.isEmpty)
        print("[LiveCalibreWireless] READY_FOR_SEND host=\(host) port=\(port) deadlineSeconds=180; send exactly one EPUB from desktop Calibre now")

        let completedID = try await liveDeadline(seconds: 180, stage: "desktop Send to device") {
            for await (transfers, state) in Publishers.CombineLatest(service.$transfers, service.$state).values {
                if case .failed(let message) = state { throw LiveCalibreWireError.failure(message) }
                if let transfer = transfers.first(where: { $0.phase == .completed }) { return transfer.id }
            }
            throw LiveCalibreWireError.closed
        }
        let completed = try #require(service.transfers.first(where: { $0.id == completedID }))
        #expect(completed.receivedBytes == completed.totalBytes)
        #expect(completed.totalBytes > 0)
        #expect(store.books.count == 1)
        let imported = try #require(store.books.first)
        #expect(imported.isInBookshelf)
        #expect(imported.remoteSource == nil)
        #expect(imported.contentFilename.lowercased().hasSuffix(".epub"))
        if let expectedTitle { #expect(imported.title == expectedTitle) }
        let file = StorageLocations.bookFile(imported.contentFilename)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(Int64(size ?? 0) == completed.totalBytes)
        let publication = try await PublicationSession.open(sourceURL: file, cacheDirectory: root.appendingPathComponent("publication"))
        _ = try #require(publication.chapters.first)
        let firstChapter = try await publication.chapterHTML(at: 0)
        #expect(!firstChapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let bookmark = Bookmark(chapterIndex: 0, chapterTitle: "Live Calibre acceptance",
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: 5),
            note: "Keep across wireless reconnect", excerpt: "Live transfer")
        store.addBookmark(bookId: imported.id, bookmark: bookmark)
        store.updatePosition(bookId: imported.id, position: 0.375, forceSave: true)
        let originalRegistry = try CalibreDeviceRegistry.load(from: registryURL)
        let originalEntry = try #require(originalRegistry.books.first)
        #expect(originalRegistry.books.count == 1)
        #expect(originalEntry.bookID == imported.id)
        print("[LiveCalibreWireless] RECEIVED_READABLE_EPUB bookID=\(imported.id) calibreUUID=\(originalEntry.calibreUUID) bytes=\(completed.totalBytes) chapters=\(publication.chapters.count)")

        print("[LiveCalibreWireless] READY_FOR_EJECT; use desktop Calibre Eject device now")
        try await liveDeadline(seconds: 180, stage: "desktop eject ACK and peer TCP closure") {
            for await event in relay.events {
                if case .failure(let message) = event.kind { throw LiveCalibreWireError.failure(message) }
                if case .ejectionAcknowledgedAndDesktopClosed = event.kind { return }
            }
            throw LiveCalibreWireError.closed
        }
        // Calibre 9.14 driver.eject() closes the socket after receiving the ACK,
        // but DeviceManager.connected_device_removed() clears the global device
        // flag on a later scan. Even TCP EOF is not a protocol "ready" signal.
        // The operator confirms desktop disconnection before the first reconnect;
        // no timer, busy-response retry, or inferred readiness substitutes for it.
        // Official source: smart_device_app/driver.py:1529 and gui2/device.py:293.
        await relay.shutdown()
        print("[LiveCalibreWireless] DESKTOP_EJECT_ACK_AND_CLOSE_CONFIRMED")
        let reconnectGate = try LiveCalibreReconnectGate()
        defer { Task { await reconnectGate.close() } }
        let gatePort = try await liveDeadline(seconds: 30, stage: "start operator reconnect gate") { try await reconnectGate.start() }
        print("[LiveCalibreWireless] READY_FOR_RECONNECT_CONFIRMATION host=127.0.0.1 port=\(gatePort) token=\(reconnectGate.token); after confirming desktop is disconnected, send this token plus newline to this test-only TCP port")
        try await liveDeadline(seconds: 180, stage: "operator confirms desktop disconnected") { try await reconnectGate.waitForConfirmation() }
        await reconnectGate.close()
        print("[LiveCalibreWireless] OPERATOR_CONFIRMED_RECONNECT")

        let restartedStore = BookStore(metadataFileURL: metadataURL)
        let restored = try #require(restartedStore.readingBook(id: imported.id))
        #expect(restartedStore.books.map(\.id) == [imported.id])
        #expect(restored.currentPosition == 0.375)
        #expect(restored.bookmarks == [bookmark])
        let reconnected = CalibreWirelessService(registryURL: registryURL)
        defer { reconnected.disconnect() }
        let secondRelay = try LiveCalibreWireRelay(host: host, port: port)
        defer { Task { await secondRelay.shutdown() } }
        let nextPort = try await liveDeadline(seconds: 30, stage: "start reconnect relay") { try await secondRelay.start() }
        reconnected.connect(host: "127.0.0.1", port: nextPort, password: password, store: restartedStore)
        try await waitForConnection(reconnected, stage: "reconnect authentication")
        let actualDeviceList = try await waitForDesktopList(secondRelay, stage: "desktop reconnect book scan")
        #expect(actualDeviceList.count == 1)
        let advertised = try #require(actualDeviceList.first)
        #expect(advertised["uuid"]?.string == originalEntry.calibreUUID)
        #expect(advertised["lpath"]?.string == originalEntry.lpath)
        #expect(advertised["title"]?.string == imported.title)
        let reloadedRegistry = try CalibreDeviceRegistry.load(from: registryURL)
        #expect(reloadedRegistry.books.map(\.bookID) == [imported.id])
        #expect(restartedStore.books.map(\.id) == [imported.id])
        #expect(restartedStore.readingBook(id: imported.id)?.currentPosition == 0.375)
        #expect(restartedStore.readingBook(id: imported.id)?.bookmarks == [bookmark])
        #expect(reconnected.transfers.isEmpty)
        print("[LiveCalibreWireless] RECONNECT_DEVICE_LIST_CONFIRMED count=1 bookID=\(imported.id) calibreUUID=\(originalEntry.calibreUUID) progress=0.375 bookmarks=1")
        // Calibre still performs free-space and book-list synchronization after
        // the first verified metadata scan. Let its operator end the full device
        // session instead of cutting that remaining work off at our assertions.
        print("[LiveCalibreWireless] READY_FOR_FINAL_EJECT; use desktop Calibre Eject device now")
        try await liveDeadline(seconds: 180, stage: "final desktop eject ACK and peer TCP closure") {
            for await event in secondRelay.events {
                if case .failure(let message) = event.kind { throw LiveCalibreWireError.failure(message) }
                if case .ejectionAcknowledgedAndDesktopClosed = event.kind { return }
            }
            throw LiveCalibreWireError.closed
        }
        reconnected.disconnect()
        await secondRelay.shutdown()
        print("[LiveCalibreWireless] FINAL_DESKTOP_EJECT_ACK_AND_CLOSE_CONFIRMED")
        print("[LiveCalibreWireless] PASS real-desktop-send/readable-EPUB/reconnect-list/stable-ID/progress/bookmarks")
    }

    private func waitForConnection(_ service: CalibreWirelessService, stage: String) async throws {
        try await liveDeadline(seconds: 45, stage: stage) {
            for await state in service.$state.values {
                switch state {
                case .connected: return
                case .failed(let message): throw LiveCalibreWireError.failure(message)
                default: break
                }
            }
            throw LiveCalibreWireError.closed
        }
    }

    private func waitForDesktopList(_ relay: LiveCalibreWireRelay, stage: String) async throws -> [[String: CalibreJSON]] {
        try await liveDeadline(seconds: 45, stage: stage) {
            for await event in relay.events {
                switch event.kind {
                case .bookListProcessed(let entries): return entries
                case .failure(let message): throw LiveCalibreWireError.failure(message)
                default: break
                }
            }
            throw LiveCalibreWireError.closed
        }
    }
}

private enum LiveCalibreWireError: LocalizedError {
    case timeout(String), failure(String), closed
    var errorDescription: String? {
        switch self {
        case .timeout(let stage): "Live Calibre wireless timeout: \(stage)"
        case .failure(let message): message
        case .closed: "Live Calibre wireless connection closed"
        }
    }
}

/// The only timer in this harness is an explicit failure deadline. Progress and
/// success always depend on Combine/network events, never elapsed time.
@MainActor
private func liveDeadline<T: Sendable>(seconds: Int, stage: String,
    operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LiveCalibreWireError.timeout(stage)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw LiveCalibreWireError.closed }
        return result
    }
}

private struct LiveCalibreWireEvent: Sendable {
    enum Kind: Sendable {
        case bookListProcessed([[String: CalibreJSON]])
        case commandCompleted(Int)
        case ejectionAcknowledgedAndDesktopClosed
        case failure(String)
    }
    let sequence: Int
    let kind: Kind
}

/// Transparent, bounded TCP relay used only to observe what the real desktop
/// requested and what the production service actually transmitted. Every byte
/// is forwarded unchanged; no handshake, file or response is synthesized here.
private actor LiveCalibreWireRelay {
    nonisolated let events: AsyncStream<LiveCalibreWireEvent>
    private let eventSink: AsyncStream<LiveCalibreWireEvent>.Continuation
    private let listener: NWListener
    private let serverEndpoint: NWEndpoint
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var toDesktop: LiveCalibreRawSocket?
    private var toDevice: LiveCalibreRawSocket?
    private var pumps: [Task<Void, Never>] = []
    private var closed = false
    private(set) var sequence = 0
    private var serverBuffer = CalibreWireBuffer()
    private var deviceBuffer = CalibreWireBuffer()
    private var incomingBinary: Int64 = 0
    private var outgoingBinary: Int64 = 0
    private struct PendingCommand {
        let opcode: Int
        let ejecting: Bool
    }
    private var commands: [PendingCommand] = []
    private var metadataRemaining = 0
    private var metadata: [[String: CalibreJSON]] = []
    private var awaitingListConfirmation: [[String: CalibreJSON]]?
    private var ejectionRequested = false
    private var ejectionAcknowledged = false
    private var desktopClosedAfterEjection = false
    private var reportedEjection = false

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw LiveCalibreWireError.failure("Invalid wireless port") }
        listener = try NWListener(using: .tcp, on: .any)
        serverEndpoint = .hostPort(host: .init(host), port: endpointPort)
        let stream = AsyncStream<LiveCalibreWireEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = stream.stream
        eventSink = stream.continuation
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerChanged(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { await self?.attach(connection) } }
                listener.start(queue: DispatchQueue(label: "LiveCalibreWireRelay"))
            }
        } onCancel: { self.listener.cancel() }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue { startWaiter?.resume(returning: port); startWaiter = nil }
        case .failed(let error):
            startWaiter?.resume(throwing: error); startWaiter = nil
            publish(.failure(error.localizedDescription))
        case .cancelled:
            startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
        default: break
        }
    }

    private func attach(_ connection: NWConnection) async {
        guard toDevice == nil, !closed else { connection.cancel(); return }
        let device = LiveCalibreRawSocket(connection)
        let desktop = LiveCalibreRawSocket(NWConnection(to: serverEndpoint, using: .tcp))
        toDevice = device
        toDesktop = desktop
        do {
            try await device.connect()
            try await desktop.connect()
            pumps = [
                Task { await self.pump(source: desktop, destination: device, fromServer: true) },
                Task { await self.pump(source: device, destination: desktop, fromServer: false) }
            ]
        } catch {
            publish(.failure(error.localizedDescription))
            await shutdown()
        }
    }

    private func pump(source: LiveCalibreRawSocket, destination: LiveCalibreRawSocket, fromServer: Bool) async {
        do {
            while !Task.isCancelled {
                let bytes = try await source.receive()
                // Register the command before allowing the app to reply.
                if fromServer { try inspectServer(bytes) }
                try await destination.send(bytes)
                if !fromServer { try inspectDevice(bytes) }
            }
        } catch {
            await streamEnded(fromServer: fromServer, error: error)
        }
    }

    private func streamEnded(fromServer: Bool, error: Error) async {
        guard !closed else { return }
        if ejectionRequested, case LiveCalibreWireError.closed = error {
            if fromServer {
                // Do not manufacture peer EOF by cancelling the upstream socket
                // when the production client closes immediately after its ACK.
                desktopClosedAfterEjection = true
                reportEjectionIfComplete()
                return
            } else if ejectionAcknowledged {
                // The app correctly closes its end after ACK. Keep the desktop
                // receive pump alive until Calibre itself closes the real socket.
                return
            }
        }
        publish(.failure(error.localizedDescription))
        await shutdown()
    }

    private func reportEjectionIfComplete() {
        guard ejectionAcknowledged, desktopClosedAfterEjection, !reportedEjection else { return }
        reportedEjection = true
        publish(.ejectionAcknowledgedAndDesktopClosed)
    }

    private func inspectServer(_ bytes: Data) throws {
        try serverBuffer.append(bytes)
        while !serverBuffer.data.isEmpty {
            if incomingBinary > 0 {
                incomingBinary -= Int64(serverBuffer.takeBinary(upTo: Int(min(incomingBinary, Int64(serverBuffer.data.count)))).count)
                continue
            }
            guard let frame = try serverBuffer.nextFrame() else { return }
            if let entries = awaitingListConfirmation {
                awaitingListConfirmation = nil
                publish(.bookListProcessed(entries))
            }
            if frame.opcode == 8 { incomingBinary = frame.arguments["length"]?.integer ?? 0 }
            let ejecting = frame.opcode == 12 && frame.arguments["ejecting"] == .bool(true)
            if ejecting { ejectionRequested = true }
            if ![7, 16, 18].contains(frame.opcode) { commands.append(PendingCommand(opcode: frame.opcode, ejecting: ejecting)) }
        }
    }

    private func inspectDevice(_ bytes: Data) throws {
        try deviceBuffer.append(bytes)
        while !deviceBuffer.data.isEmpty {
            if outgoingBinary > 0 {
                outgoingBinary -= Int64(deviceBuffer.takeBinary(upTo: Int(min(outgoingBinary, Int64(deviceBuffer.data.count)))).count)
                continue
            }
            guard let frame = try deviceBuffer.nextFrame() else { return }
            if metadataRemaining > 0 {
                guard frame.opcode == 0 else { throw LiveCalibreWireError.failure("Device did not stream book metadata") }
                metadata.append(frame.arguments)
                metadataRemaining -= 1
                if metadataRemaining == 0 { awaitingListConfirmation = metadata }
                continue
            }
            guard !commands.isEmpty else { throw LiveCalibreWireError.failure("Unexpected unsolicited device reply") }
            let command = commands.removeFirst()
            if command.opcode == 6 {
                guard frame.opcode == 0, let count = frame.arguments["count"]?.integer, count >= 0, count < 10_000 else {
                    throw LiveCalibreWireError.failure("Invalid real device book count response")
                }
                metadata = []
                metadataRemaining = Int(count)
                if count == 0 { awaitingListConfirmation = [] }
            } else if command.opcode == 14 {
                outgoingBinary = frame.arguments["fileLength"]?.integer ?? 0
            }
            if command.ejecting {
                guard frame.opcode == 0 else { throw LiveCalibreWireError.failure("Production client rejected the desktop eject command") }
                ejectionAcknowledged = true
                reportEjectionIfComplete()
            }
            publish(.commandCompleted(command.opcode))
        }
    }

    private func publish(_ kind: LiveCalibreWireEvent.Kind) {
        sequence += 1
        eventSink.yield(LiveCalibreWireEvent(sequence: sequence, kind: kind))
    }

    func shutdown() async {
        guard !closed else { return }
        closed = true
        listener.cancel()
        pumps.forEach { $0.cancel() }
        if let toDevice { await toDevice.close() }
        if let toDesktop { await toDesktop.close() }
        eventSink.finish()
    }
}

private actor LiveCalibreRawSocket {
    private let connection: NWConnection
    private var readyWaiter: CheckedContinuation<Void, Error>?
    init(_ connection: NWConnection) { self.connection = connection }

    func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiter = continuation
                connection.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
                connection.start(queue: DispatchQueue(label: "LiveCalibreRawSocket"))
            }
        } onCancel: { self.connection.cancel() }
    }

    private func changed(_ state: NWConnection.State) {
        guard let waiter = readyWaiter else { return }
        switch state {
        case .ready: readyWaiter = nil; waiter.resume()
        case .waiting(let error), .failed(let error): readyWaiter = nil; waiter.resume(throwing: error)
        case .cancelled: readyWaiter = nil; waiter.resume(throwing: CancellationError())
        default: break
        }
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: CalibreWireBuffer.packetLength) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: LiveCalibreWireError.closed) }
                }
            }
        } onCancel: { self.connection.cancel() }
    }

    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { self.connection.cancel() }
    }

    func close() { connection.cancel() }
}

/// Test-only operator signal, on a separate loopback port and protected by a
/// fresh per-run token. It carries no Calibre traffic and never edits a server.
private actor LiveCalibreReconnectGate {
    nonisolated let token = UUID().uuidString
    private let listener: NWListener
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var confirmationWaiter: CheckedContinuation<Void, Error>?
    private var confirmed = false
    private var sockets: [LiveCalibreRawSocket] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { await self?.confirm(connection) } }
                listener.start(queue: DispatchQueue(label: "LiveCalibreReconnectGate"))
            }
        } onCancel: { self.listener.cancel() }
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue { startWaiter?.resume(returning: port); startWaiter = nil }
        case .failed(let error):
            startWaiter?.resume(throwing: error); startWaiter = nil
            confirmationWaiter?.resume(throwing: error); confirmationWaiter = nil
        case .cancelled:
            startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
            confirmationWaiter?.resume(throwing: CancellationError()); confirmationWaiter = nil
        default: break
        }
    }

    func waitForConfirmation() async throws {
        if confirmed { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { confirmationWaiter = $0 }
        } onCancel: { self.listener.cancel() }
    }

    private func confirm(_ connection: NWConnection) async {
        let socket = LiveCalibreRawSocket(connection)
        sockets.append(socket)
        do {
            try await socket.connect()
            var input = Data()
            while !input.contains(10), input.count <= 128 {
                input.append(try await socket.receive())
            }
            let supplied = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard input.count <= 128, supplied == token else {
                try await socket.send(Data("REJECTED\n".utf8))
                await socket.close()
                return
            }
            try await socket.send(Data("RECONNECT_ALLOWED\n".utf8))
            confirmed = true
            confirmationWaiter?.resume()
            confirmationWaiter = nil
        } catch {
            confirmationWaiter?.resume(throwing: error)
            confirmationWaiter = nil
        }
        await socket.close()
    }

    func close() async {
        listener.cancel()
        for socket in sockets { await socket.close() }
        sockets.removeAll()
    }
}
