import Foundation
@preconcurrency import Network

/// A single sequential reader owns framing. Network.framework applies TCP
/// backpressure while the service validates/imports a completed book.
actor CalibreWirelessTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.yuedu.calibre-wireless")
    private var buffer = CalibreWireBuffer()
    private var connectionWaiter: CheckedContinuation<Void, Error>?

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func connect() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectionWaiter = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.connectionChanged(state) }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    private func connectionChanged(_ state: NWConnection.State) {
        guard let waiter = connectionWaiter else { return }
        switch state {
        case .ready:
            connectionWaiter = nil
            waiter.resume()
        case .failed(let error), .waiting(let error):
            connectionWaiter = nil
            connection.cancel()
            waiter.resume(throwing: error)
        case .cancelled:
            connectionWaiter = nil
            waiter.resume(throwing: CancellationError())
        default: break
        }
    }

    func cancel() { connection.cancel() }

    func readFrame() async throws -> CalibreFrame {
        while true {
            try Task.checkCancellation()
            if let frame = try buffer.nextFrame() { return frame }
            try buffer.append(await receive())
        }
    }

    func readBinary(upTo count: Int) async throws -> Data {
        try Task.checkCancellation()
        if buffer.data.isEmpty { try buffer.append(await receive()) }
        return buffer.takeBinary(upTo: min(count, CalibreWireBuffer.packetLength))
    }

    private func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: CalibreWireBuffer.packetLength) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: CalibreWirelessError.disconnected) }
                }
            }
        } onCancel: { self.connection.cancel() }
    }

    func send(_ frame: CalibreFrame) async throws { try await sendData(frame.encoded()) }

    func sendData(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { self.connection.cancel() }
    }

    func sendFile(_ url: URL, position: UInt64) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { AppLogger.error("Calibre outgoing file close failed: \(error)") }
        }
        try handle.seek(toOffset: position)
        while let data = try handle.read(upToCount: CalibreWireBuffer.packetLength), !data.isEmpty {
            try await sendData(data)
        }
    }
}
