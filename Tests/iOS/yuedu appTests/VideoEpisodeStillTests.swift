import CoreImage
import Foundation
import Network
import Testing
import UIKit
@testable import yuedu_app

/// 選集's episode stills (maintainer, 2026-11-01: 「做，只截看得到的幾集」). The clips are black
/// for their first second and blue after it, ten seconds in all, so a still taken a fifth of
/// the way in is blue and one taken at the first frame is black.
@Suite("Video episode stills")
struct VideoEpisodeStillTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/VideoStill", isDirectory: true)
    private static let card = CGSize(width: 672, height: 378)

    private func still(_ name: String) async throws -> VideoStillFrame {
        let stream = VideoStream(url: Self.fixtures.appendingPathComponent(name), headers: [:])
        return try await VideoStillExtractor.still(of: stream, fitting: Self.card)
    }

    private func image(_ frame: VideoStillFrame) throws -> CGImage {
        try #require(UIImage(data: frame.jpeg)?.cgImage)
    }

    /// The colour at the frame's centre.
    private func centre(_ image: CGImage) -> (red: Double, green: Double, blue: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .none
        context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                        width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    @Test("a file's still is taken past its first frame, with its running time")
    func fileStill() async throws {
        let frame = try await still("video-still-landscape.mp4")
        let image = try image(frame)
        #expect(image.width == 320 && image.height == 180, "never scaled up past the stream's own size")
        let colour = centre(image)
        #expect(colour.blue > 0.6 && colour.red < 0.3, "the first second is black; a fifth in is blue")
        #expect(abs((frame.duration ?? 0) - 10) < 0.5)
        #expect(VideoStillCoding.duration(in: frame.jpeg) == frame.duration)
    }

    /// Served, not read from disk: iOS's player never readies an HLS playlist from a file
    /// (measured 2026-11-01: `.unknown` after 8 s, where the same playlist over HTTP is ready
    /// in under one).
    @Test("an HLS playlist behind a Referer check gives a still, every request carrying the stream's headers")
    func playlistStill() async throws {
        let referer = "https://v.example/play/1"
        let server = try VideoStillFixtureServer(directory: Self.fixtures, referer: referer)
        let base = try await server.start()
        defer { server.stop() }
        let stream = VideoStream(url: base.appendingPathComponent("video-still-hls.m3u8"), headers: ["Referer": referer])
        let frame = try await VideoStillExtractor.still(of: stream, fitting: Self.card)
        let colour = centre(try image(frame))
        #expect(colour.blue > 0.6 && colour.red < 0.3)
        #expect(abs((frame.duration ?? 0) - 10) < 0.5)
        let requests = server.requests
        #expect(requests.contains { $0.path.hasSuffix(".m4s") }, "a segment was fetched, not only the playlist")
        #expect(requests.allSatisfy { $0.referer == referer }, "\(requests)")
    }

    @Test("a portrait episode stays portrait")
    func portraitStill() async throws {
        let image = try image(try await still("video-still-portrait.mp4"))
        #expect(image.height > image.width)
    }

    @Test("an audio-only episode has no still")
    func audioOnly() async throws {
        await #expect(throws: VideoStillError.noFrame) {
            _ = try await still("video-still-audio-only.m4a")
        }
    }

    @Test("a large frame is scaled down until it just covers the card")
    func scaledToCover() throws {
        let large = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let jpeg = try #require(VideoStillCoding.jpeg(of: large, fitting: Self.card, duration: 2712.5))
        let image = try #require(UIImage(data: jpeg)?.cgImage)
        #expect(image.width == 672 && image.height == 378)
        #expect(VideoStillCoding.duration(in: jpeg) == 2712.5)
        #expect(VideoStillCoding.duration(in: try #require(VideoStillCoding.jpeg(of: large, fitting: Self.card, duration: nil))) == nil)
    }

    @Test("a quarter-turn track stands upright")
    func rotation() {
        #expect(VideoStillExtractor.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == .right)
        #expect(VideoStillExtractor.orientation(of: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)) == .left)
        #expect(VideoStillExtractor.orientation(of: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)) == .down)
        #expect(VideoStillExtractor.orientation(of: .identity) == .up)
    }

    @Test("running time in whole minutes, never 0")
    func minutes() {
        #expect(VideoEpisodeRunningTime.minutes(20) == 1)
        #expect(VideoEpisodeRunningTime.minutes(81) == 1)
        #expect(VideoEpisodeRunningTime.minutes(150) == 3)
        #expect(VideoEpisodeRunningTime.minutes(2712.5) == 45)
    }

    @Test("a still is keyed by its source and episode address, not by a stream or a book")
    func key() {
        let source = UUID()
        #expect(VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1")
            == VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1"))
        #expect(VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1")
            != VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/2"))
        #expect(VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1")
            != VideoEpisodeStills.key(sourceId: UUID(), chapterURL: "/ep/1"))
    }

    @Test("episodes run in thirties under the row, named by their episode numbers")
    func ranges() {
        let runs = VideoEpisodeRange.ranges(of: Array(10..<47)) { $0 - 9 }
        #expect(runs.map { "\($0.firstNumber)·\($0.lastNumber)" } == ["1·30", "31·37"])
        #expect(runs[1].episodes.first == 40 && runs[1].id == 40)
        #expect(VideoEpisodeRange.ranges(of: Array(0..<30)) { $0 + 1 }.count == 1)
        #expect(VideoEpisodeRange.ranges(of: []) { $0 }.isEmpty)
    }

    @Test("an unshelved video keeps one id per work across visits")
    func unshelvedID() {
        let source = UUID()
        let id = UUID.unshelvedVideoID(sourceId: source, bookURL: "https://v.example/1")
        #expect(id == UUID.unshelvedVideoID(sourceId: source, bookURL: "https://v.example/1"))
        #expect(id != UUID.unshelvedVideoID(sourceId: source, bookURL: "https://v.example/2"))
        #expect(id != UUID.unshelvedVideoID(sourceId: UUID(), bookURL: "https://v.example/1"))
        #expect(ReadingBook(id: id, title: "x", contentFilename: "").id == id)
    }

    @Test("a still waiting for a slot stops waiting when its card leaves")
    func gateWaitIsCancellable() async throws {
        let gate = VideoStillGate(limit: 1)
        try await gate.enter()
        let waiter = Task { try await gate.enter() }
        while await gate.waitingCount == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.waitingCount == 0)
        #expect(await gate.runningCount == 1)
        await gate.leave()
        #expect(await gate.runningCount == 0)
    }

    @Test("a slot freed goes to the next still waiting")
    func gateHandsOver() async throws {
        let gate = VideoStillGate(limit: 1)
        try await gate.enter()
        let waiter = Task { try await gate.enter() }
        while await gate.waitingCount == 0 { await Task.yield() }
        await gate.leave()
        try await waiter.value
        #expect(await gate.runningCount == 1)
        #expect(await gate.waitingCount == 0)
    }
}

/// A loopback CDN for the stills' fixtures that refuses (403) any request without the expected
/// Referer, as the sources' video CDNs do, and serves byte ranges. Readiness is signalled by
/// Network.framework, never by sleeping.
private final class VideoStillFixtureServer: @unchecked Sendable {
    struct Request: CustomStringConvertible {
        let path: String
        let referer: String?
        var description: String { "\(path) referer=\(referer ?? "-")" }
    }

    private let directory: URL
    private let referer: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VideoEpisodeStillTests.FixtureServer")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private var received: [Request] = []

    init(directory: URL, referer: String) throws {
        self.directory = directory
        self.referer = referer
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [Request] { lock.withLock { received } }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        self.finishStart(.failure(URLError(.cannotConnectToHost)))
                        return
                    }
                    self.finishStart(.success(url))
                case .failed(let error): self.finishStart(.failure(error))
                case .cancelled: self.finishStart(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receiveHeaders(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let open = lock.withLock { let value = connections; connections.removeAll(); return value }
        open.forEach { $0.cancel() }
        finishStart(.failure(CancellationError()))
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let callback = lock.withLock { let value = continuation; continuation = nil; return value }
        callback?.resume(with: result)
    }

    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let chunk { request.append(chunk) }
            guard error == nil, request.count < 64 * 1024 else { connection.cancel(); return }
            if let boundary = request.range(of: Data("\r\n\r\n".utf8)),
               let text = String(data: request[..<boundary.lowerBound], encoding: .utf8) {
                self.respond(connection, headers: text)
            } else if !complete {
                self.receiveHeaders(connection, accumulated: request)
            } else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, headers rawHeaders: String) {
        let lines = rawHeaders.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        lock.withLock { received.append(Request(path: path, referer: headers["referer"])) }

        let file = directory.appendingPathComponent(String(path.drop { $0 == "/" }))
        guard headers["referer"] == referer else { return send(connection, status: "403 Forbidden", body: Data()) }
        guard let data = try? Data(contentsOf: file) else { return send(connection, status: "404 Not Found", body: Data()) }
        let type = switch file.pathExtension {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "m4s": "video/iso.segment"
        default: "video/mp4"
        }
        var extra = ["Content-Type": type, "Accept-Ranges": "bytes"]
        if let range = headers["range"], range.hasPrefix("bytes="),
           let bounds = Self.bounds(String(range.dropFirst("bytes=".count)), count: data.count) {
            extra["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(data.count)"
            return send(connection, status: "206 Partial Content", body: data.subdata(in: bounds.lowerBound..<(bounds.upperBound + 1)), headers: extra)
        }
        send(connection, status: "200 OK", body: data, headers: extra)
    }

    /// `a-b` or `a-`, clamped to the file.
    private static func bounds(_ spec: String, count: Int) -> ClosedRange<Int>? {
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start < count else { return nil }
        let end = min(Int(parts[1]) ?? count - 1, count - 1)
        return end >= start ? start...end : nil
    }

    private func send(_ connection: NWConnection, status: String, body: Data, headers: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        var response = Data((head + "\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
