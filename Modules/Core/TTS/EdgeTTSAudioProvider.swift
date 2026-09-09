import Foundation

protocol EdgeTTSTransport: Sendable {
    func synthesize(request: URLRequest, messages: [String]) async throws -> Data
}

final class EdgeTTSAudioProvider: TTSAudioProvider, Sendable {
    let voice: EdgeTTSVoice
    private let transport: any EdgeTTSTransport
    var displayName: String { localized("微軟線上語音") }

    init(voice: EdgeTTSVoice, transport: any EdgeTTSTransport = EdgeTTSWebSocketTransport()) {
        self.voice = voice
        self.transport = transport
    }

    func audioData(for text: String, title: String, rate: Float) async throws -> Data {
        guard EdgeTTSVoice.voice(id: voice.id) != nil else { throw EdgeTTSError.invalidVoice }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EdgeTTSError.emptyAudio
        }
        var audio = Data()
        for escapedText in EdgeTTSProtocol.escapedTextChunks(text) {
            try Task.checkCancellation()
            let data = try await transport.synthesize(
                request: EdgeTTSProtocol.request(),
                messages: EdgeTTSProtocol.messages(escapedText: escapedText, voice: voice, rate: rate)
            )
            try Task.checkCancellation()
            guard !data.isEmpty else { throw EdgeTTSError.emptyAudio }
            guard TTSAudioPayload.looksLikeAudioContainer(data) else {
                throw EdgeTTSError.invalidResponse
            }
            guard audio.count + data.count <= EdgeTTSProtocol.maxAudioBytes else {
                throw EdgeTTSError.responseTooLarge
            }
            audio.append(data)
        }
        return audio
    }
}

struct EdgeTTSWebSocketTransport: EdgeTTSTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    func synthesize(request: URLRequest, messages: [String]) async throws -> Data {
        let socket = Self.session.webSocketTask(with: request)
        socket.maximumMessageSize = EdgeTTSProtocol.maxAudioBytes
        let deadline = EdgeTTSRequestDeadline(socket: socket)
        defer {
            deadline.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            socket.resume()
            do {
                for message in messages { try await socket.send(.string(message)) }
                var audio = Data()
                while true {
                    try Task.checkCancellation()
                    switch try EdgeTTSProtocol.event(await socket.receive()) {
                    case .audio(let data):
                        guard audio.count + data.count <= EdgeTTSProtocol.maxAudioBytes else {
                            throw EdgeTTSError.responseTooLarge
                        }
                        audio.append(data)
                    case .finished:
                        guard !audio.isEmpty else { throw EdgeTTSError.emptyAudio }
                        return audio
                    case .metadata: continue
                    }
                }
            } catch {
                try Task.checkCancellation()
                if deadline.didExpire { throw URLError(.timedOut) }
                if let response = socket.response as? HTTPURLResponse, response.statusCode != 101 {
                    throw EdgeTTSError.serviceStatus(response.statusCode)
                }
                throw error
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}

/// An absolute network deadline: URLSession's request timeout alone does not bound a
/// WebSocket peer that opens successfully but never sends turn.end. No retries or state waits.
private final class EdgeTTSRequestDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    var didExpire: Bool { lock.withLock { expired } }

    init(socket: URLSessionWebSocketTask) {
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.expired = true }
            socket.cancel(with: .goingAway, reason: nil)
        }
        timer.resume()
    }

    func cancel() { timer.cancel() }
}

enum TTSAudioProviderSelection {
    static func make(template: String, isDirectChapterAudio: Bool) throws -> any TTSAudioProvider {
        if !isDirectChapterAudio, EdgeTTSVoice.isEdgeSource(template) {
            guard let voice = EdgeTTSVoice.voice(sourceIdentifier: template) else {
                throw EdgeTTSError.invalidVoice
            }
            return EdgeTTSAudioProvider(voice: voice)
        }
        return CustomHTTPProvider()
    }
}
