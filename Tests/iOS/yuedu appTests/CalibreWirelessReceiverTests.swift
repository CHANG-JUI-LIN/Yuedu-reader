import Combine
import Foundation
@preconcurrency import Network
import Testing
import UIKit
@testable import yuedu_app

@Suite("Calibre wireless receiver", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct CalibreWirelessReceiverTests {
    @Test("A persisted Calibre drive display name never becomes the raw handshake device name",
          arguments: ["無線裝置: iPhone 17 Pro Max", "Wireless device: iPhone 17 Pro Max", "Travel Library"])
    func reconnectKeepsRawDeviceName(_ driveName: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalibreDeviceNameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("device.json")
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let deviceUUID = UUID().uuidString
        var registry = CalibreDeviceRegistry()
        registry.deviceInfo = ["device_store_uuid": .string(deviceUUID), "device_name": .string(driveName)]
        try registry.save(to: registryURL)
        let rawName = UIDevice.current.name

        for _ in 0..<2 {
            let service = CalibreWirelessService(registryURL: registryURL)
            defer { service.disconnect() }
            let server = try CalibreTestServer()
            defer { Task { await server.stop() } }
            let port = try await server.start()
            service.connect(host: "127.0.0.1", port: port, password: "", store: store)
            let desktop = try await server.accept()
            try await desktop.connect()
            try await desktop.send(CalibreFrame(9, [
                "serverProtocolVersion": .number(1), "passwordChallenge": .string(""),
                "validExtensions": .array([.string("epub")]),
                "currentLibraryUUID": .string("name-test-library"), "currentLibraryName": .string("Name Test")
            ]))
            let handshake = try await desktop.readFrame()
            #expect(handshake.opcode == 0)
            #expect(handshake.arguments["deviceName"] == .string(rawName))

            try await desktop.send(CalibreFrame(3))
            let information = try await desktop.readFrame()
            let driveInfo = try #require(information.arguments["device_info"]?.object)
            #expect(driveInfo["device_name"] == .string(driveName))
            #expect(driveInfo["device_store_uuid"] == .string(deviceUUID))
            // Calibre's display label and explicit drive renames still roundtrip
            // unchanged; neither is reused as the next raw client deviceName.
            try await desktop.send(CalibreFrame(1, driveInfo))
            let infoAck = try await desktop.readFrame()
            #expect(infoAck.opcode == 0)
            try await desktop.send(CalibreFrame(2, ["name": .string(driveName)]))
            let nameAck = try await desktop.readFrame()
            #expect(nameAck.opcode == 0)
            service.disconnect()
            await desktop.cancel()
            await server.stop()
            let persisted = try CalibreDeviceRegistry.load(from: registryURL)
            #expect(persisted.deviceInfo["device_name"] == .string(driveName))
            #expect(persisted.deviceInfo["device_store_uuid"] == .string(deviceUUID))
            #expect(store.books.isEmpty)
        }
    }

    @Test("Real TCP transfer imports only the complete file and remains idempotent across reconnects")
    func receivesListsAndDeduplicatesTXT() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalibreReceiverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let registryURL = root.appendingPathComponent("device.json")
        let service = CalibreWirelessService(registryURL: registryURL)
        defer {
            service.disconnect()
            for book in store.books { store.delete(bookId: book.id) }
        }
        let server = try CalibreTestServer()
        defer { Task { await server.stop() } }
        let port = try await server.start()
        service.connect(host: "127.0.0.1", port: port, password: "secret", store: store)
        let desktop = try await server.accept()
        try await desktop.connect()
        try await handshake(desktop)
        let text = Data("第一章 測試\n這是從 Calibre 傳來的文字。[0,{}] 必須保留。\n".utf8)
        let metadata: [String: CalibreJSON] = ["title": .string("無線傳書測試"), "authors": .array([.string("Calibre Author")]), "uuid": .string("calibre-test-book"), "lpath": .string("calibre-test-book.txt")]
        let header = CalibreFrame(8, ["lpath": .string("calibre-test-book.txt"), "length": .number(Double(text.count)), "willStreamBinary": .bool(true), "metadata": .object(metadata)])
        try await desktop.send(header)
        let accepted = try await desktop.readFrame()
        #expect(accepted.opcode == 0)
        #expect(store.books.isEmpty)
        // Two writes exercise file-length ownership without using timing waits.
        try await desktop.sendData(Data(text.prefix(7)))
        #expect(store.books.isEmpty)
        var tailAndCommand = Data(text.dropFirst(7))
        tailAndCommand.append(try CalibreFrame(3).encoded())
        try await desktop.sendData(tailAndCommand)
        let deviceInfo = try await desktop.readFrame()
        // Any invented final OK/BOOK_DONE would occupy this reply slot.
        #expect(deviceInfo.arguments["device_info"]?.object != nil)
        let imported = try #require(store.books.first)
        #expect(store.books.count == 1)
        #expect(try Data(contentsOf: StorageLocations.bookFile(imported.contentFilename)) == text)
        #expect(service.transfers.last?.phase == .completed)
        let bookmark = Bookmark(chapterIndex: 0, chapterTitle: "第一章", position: CoreTextReadingPosition(spineIndex: 0, charOffset: 5), excerpt: "測試")
        store.addBookmark(bookId: imported.id, bookmark: bookmark)
        store.updatePosition(bookId: imported.id, position: 0.5, forceSave: true)

        // One-way metadata commands must not inject replies before the next query.
        try await desktop.send(CalibreFrame(7, ["count": .number(1), "willStreamMetadata": .bool(true)]))
        try await desktop.send(CalibreFrame(16, ["data": .object(metadata), "index": .number(0), "count": .number(1)]))
        try await desktop.send(CalibreFrame(3))
        let followingInfo = try await desktop.readFrame()
        #expect(followingInfo.arguments["device_info"]?.object != nil)

        try await desktop.send(header)
        let duplicateAccepted = try await desktop.readFrame()
        #expect(duplicateAccepted.opcode == 0)
        try await desktop.sendData(text)
        try await desktop.send(CalibreFrame(3))
        let duplicateComplete = try await desktop.readFrame()
        #expect(duplicateComplete.arguments["device_info"]?.object != nil)
        #expect(store.books.map(\.id) == [imported.id])
        #expect(store.books.first?.currentPosition == 0.5)
        #expect(store.books.first?.bookmarks == [bookmark])

        service.disconnect()
        await desktop.cancel()
        await server.stop()
        let nextService = CalibreWirelessService(registryURL: registryURL)
        defer { nextService.disconnect() }
        let nextServer = try CalibreTestServer()
        defer { Task { await nextServer.stop() } }
        let nextPort = try await nextServer.start()
        nextService.connect(host: "127.0.0.1", port: nextPort, password: "secret", store: store)
        let nextDesktop = try await nextServer.accept()
        try await nextDesktop.connect()
        try await handshake(nextDesktop)
        try await nextDesktop.send(CalibreFrame(6, ["canStream": .bool(true), "willUseCachedMetadata": .bool(false)]))
        let count = try await nextDesktop.readFrame()
        let listedBook = try await nextDesktop.readFrame()
        #expect(count.arguments["count"]?.integer == 1)
        #expect(listedBook.arguments["uuid"] == metadata["uuid"])
        #expect(listedBook.arguments["lpath"] == metadata["lpath"])
        try await nextDesktop.send(CalibreFrame(14, ["lpath": .string("calibre-test-book.txt"), "position": .number(3), "canStreamBinary": .bool(true)]))
        let returnedFile = try await nextDesktop.readFrame()
        let returnedLength = try #require(returnedFile.arguments["fileLength"]?.integer)
        #expect(returnedLength == text.count - 3)
        var returnedBytes = Data()
        while returnedBytes.count < returnedLength {
            returnedBytes.append(try await nextDesktop.readBinary(upTo: Int(returnedLength) - returnedBytes.count))
        }
        #expect(returnedBytes == Data(text.dropFirst(3)))
        await nextDesktop.cancel()
        await nextServer.stop()
    }

    @Test("Disconnecting a partial receive does not create a shelf record or device registry entry")
    func partialTCPReceiveIsDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalibreCancelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("device.json")
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let service = CalibreWirelessService(registryURL: registryURL)
        defer { service.disconnect() }
        let server = try CalibreTestServer()
        defer { Task { await server.stop() } }
        let port = try await server.start()
        service.connect(host: "127.0.0.1", port: port, password: "secret", store: store)
        let desktop = try await server.accept()
        try await desktop.connect()
        try await handshake(desktop)
        try await desktop.send(CalibreFrame(8, ["lpath": .string("partial.txt"), "length": .number(20_000), "metadata": .object(["uuid": .string("partial")]), "willStreamBinary": .bool(true)]))
        let accepted = try await desktop.readFrame()
        #expect(accepted.opcode == 0)
        try await desktop.sendData(Data("incomplete".utf8))
        await desktop.cancel()
        _ = await service.$state.values.first { state in
            if case .failed = state { true } else { false }
        }
        #expect(store.books.isEmpty)
        #expect(try CalibreDeviceRegistry.load(from: registryURL).books.isEmpty)
        #expect(service.transfers.last?.phase != .completed)
        service.disconnect()
        await server.stop()
    }

    private func handshake(_ desktop: CalibreWirelessTransport) async throws {
        try await desktop.send(CalibreFrame(9, ["serverProtocolVersion": .number(1), "passwordChallenge": .string("2026-09-10T12:00:00+00:00"), "validExtensions": .array([.string("epub"), .string("txt"), .string("pdf")]), "currentLibraryUUID": .string("test-library"), "currentLibraryName": .string("Test Library")]))
        let response = try await desktop.readFrame()
        #expect(response.arguments["passwordHash"] == .string("74f13475f71d6e993fda62bf704e51fbfaddd213"))
        try await desktop.send(CalibreFrame(3))
        let device = try await desktop.readFrame()
        let info = try #require(device.arguments["device_info"]?.object)
        try await desktop.send(CalibreFrame(1, info))
        let persisted = try await desktop.readFrame()
        #expect(persisted.opcode == 0)
    }
}

private actor CalibreTestServer {
    private let listener: NWListener
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var acceptWaiter: CheckedContinuation<CalibreWirelessTransport, Error>?
    private var pending: CalibreWirelessTransport?

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { await self?.accepted(connection) } }
                listener.start(queue: DispatchQueue(label: "CalibreTestServer"))
            }
        } onCancel: { self.listener.cancel() }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue { startWaiter?.resume(returning: port); startWaiter = nil }
        case .failed(let error):
            startWaiter?.resume(throwing: error); startWaiter = nil
            acceptWaiter?.resume(throwing: error); acceptWaiter = nil
        case .cancelled:
            startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
            acceptWaiter?.resume(throwing: CancellationError()); acceptWaiter = nil
        default: break
        }
    }

    private func accepted(_ connection: NWConnection) {
        let transport = CalibreWirelessTransport(connection: connection)
        if let waiter = acceptWaiter { acceptWaiter = nil; waiter.resume(returning: transport) }
        else { pending = transport }
    }

    func accept() async throws -> CalibreWirelessTransport {
        if let pending { self.pending = nil; return pending }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { acceptWaiter = $0 }
        } onCancel: { self.listener.cancel() }
    }

    func stop() { listener.cancel() }
}
