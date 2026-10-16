import Combine
import Foundation
import os
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

// MARK: - Fixture

private struct ProbeCounts: Equatable, Sendable {
    var locates = 0
    var reads = 0
    var decodes = 0
    var mainThreadCalls = 0
    var readsByName: [String: Int] = [:]
}

/// The pipeline's file-system work, counted and holdable. "A hit does no I/O" becomes a
/// number, and a race is staged by holding a read open instead of sleeping.
private final class CoverIOProbe: Sendable {
    private struct State: Sendable {
        var counts = ProbeCounts()
        var holds: [String: DispatchSemaphore] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let root: URL
    /// The name of every *held* read, once it has its bytes and is about to wait.
    let heldReads: AsyncStream<String>
    private let heldReadsContinuation: AsyncStream<String>.Continuation

    init(root: URL) {
        self.root = root
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        heldReads = stream
        heldReadsContinuation = continuation
    }

    var counts: ProbeCounts { state.withLock { $0.counts } }

    /// Reads of `name` take the file's bytes as they are now, report it on
    /// `heldReads`, then wait for `release(name)`: a load that read old bytes and has
    /// not finished yet.
    func hold(_ name: String) {
        state.withLock { $0.holds[name] = DispatchSemaphore(value: 0) }
    }

    func release(_ name: String) {
        let hold = state.withLock { $0.holds.removeValue(forKey: name) }
        // More signals than any test has reads waiting; the semaphore is discarded.
        for _ in 0..<8 { hold?.signal() }
    }

    var io: CoverImageIO {
        CoverImageIO(
            locate: { source in
                self.note { $0.locates += 1 }
                switch source {
                case .bookCover(let filename):
                    return StorageLocations.coverFileLocation(filename, in: self.root)
                case .defaultCover(let fileName):
                    return CoverFixture.defaultCoverURL(fileName, in: self.root)
                case .indexedCover(let path):
                    return URL(fileURLWithPath: path)
                }
            },
            read: { url in
                let name = url.lastPathComponent
                self.note {
                    $0.reads += 1
                    $0.readsByName[name, default: 0] += 1
                }
                let data = try Data(contentsOf: url)
                if let hold = self.state.withLock({ $0.holds[name] }) {
                    self.heldReadsContinuation.yield(name)
                    hold.wait()
                }
                return data
            },
            decode: { data, size in
                self.note { $0.decodes += 1 }
                return CoverImageDecoder.thumbnail(from: data, filling: size)
            }
        )
    }

    private func note(_ update: @Sendable (inout ProbeCounts) -> Void) {
        let onMainThread = Thread.isMainThread
        state.withLock { state in
            update(&state.counts)
            if onMainThread { state.counts.mainThreadCalls += 1 }
        }
    }
}

private final class TestClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: TimeInterval(1_000))

    var now: @Sendable () -> TimeInterval {
        { self.value.withLock { $0 } }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 += seconds }
    }
}

/// One temporary directory, one pipeline reading it, one writer writing it. Nothing
/// here touches the app's own covers.
private final class CoverFixture {
    let root: URL
    let probe: CoverIOProbe
    let clock = TestClock()
    let pipeline: CoverImagePipeline
    let store: BookCoverFileStore

    init(maxConcurrentLoads: Int = 2, failureLifetime: TimeInterval = 30) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverImagePipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probe = CoverIOProbe(root: root)
        pipeline = CoverImagePipeline(
            io: probe.io,
            maxConcurrentLoads: maxConcurrentLoads,
            failureLifetime: failureLifetime,
            now: clock.now,
            logsSummaries: false
        )
        store = BookCoverFileStore(root: root, pipeline: pipeline)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ filename: String) -> URL {
        StorageLocations.coverFileLocation(filename, in: root)
    }

    func request(_ filename: String, _ longEdge: Int) -> CoverImageRequest {
        CoverImageRequest(source: .bookCover(filename: filename), size: rung(longEdge))
    }

    func writeDefaultCover(_ data: Data, named name: String) throws {
        let url = Self.defaultCoverURL(name, in: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    static func defaultCoverURL(_ name: String, in root: URL) -> URL {
        root.appendingPathComponent("DefaultCovers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    var cacheRoots: CacheStorageRoots {
        CacheStorageRoots(
            chapters: root.appendingPathComponent("online_cache", isDirectory: true),
            ttsAudio: root.appendingPathComponent("tts_audio_cache", isDirectory: true),
            mangaImages: root.appendingPathComponent("manga", isDirectory: true),
            covers: root.appendingPathComponent("Covers", isDirectory: true),
            diagnostics: root.appendingPathComponent("diagnostics", isDirectory: true),
            remoteBooks: root.appendingPathComponent("RemoteLibrary", isDirectory: true)
        )
    }
}

private func rung(_ longEdge: Int) -> CoverPixelSize {
    CoverPixelSize.all.first { $0.longEdge == longEdge }!
}

private enum Swatch {
    static func png(_ color: UIColor, width: CGFloat = 60, height: CGFloat = 90) -> Data {
        solid(color, width: width, height: height).pngData()!
    }

    static func solid(_ color: UIColor, width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Red, blue, or grey (neither), from the image's average colour.
    static func tone(of image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "none" }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drew = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return "none" }
        let red = Int(pixel[0])
        let blue = Int(pixel[2])
        if red > blue + 60 { return "red" }
        if blue > red + 60 { return "blue" }
        return "grey"
    }
}

private extension CoverImageResult {
    var isSuperseded: Bool {
        if case .superseded = self { return true }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var unavailableReason: CoverUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Yields until `condition` holds. A condition on the pipeline's own state, not a clock:
/// it returns as soon as the other tasks get there.
private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<200_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Never reached: \(what)")
}

// MARK: - Pipeline

@Suite("Cover image pipeline")
struct CoverImagePipelineTests {

    // A
    @Test("A memory hit reads, decodes and resolves nothing")
    func memoryHitDoesNoFileWork() async throws {
        let fixture = try CoverFixture()
        try fixture.store.write(Swatch.png(.red), filename: "a_cover.jpg")
        let request = fixture.request("a_cover.jpg", 240)

        #expect(await fixture.pipeline.image(for: request).image != nil)
        let afterLoad = fixture.probe.counts
        #expect(afterLoad.locates == 1)
        #expect(afterLoad.reads == 1)
        #expect(afterLoad.decodes == 1)

        for _ in 0..<50 {
            #expect(await fixture.pipeline.image(for: request).image != nil)
            #expect(fixture.pipeline.cachedResult(for: request)?.image != nil)
            #expect(fixture.pipeline.cachedImage(for: request) != nil)
        }
        #expect(fixture.probe.counts == afterLoad)
        let counters = fixture.pipeline.counters
        #expect(counters.memoryHits == 50)
        #expect(counters.fileReads == 1)
        #expect(counters.decodes == 1)
    }

    @Test("Resolving where a cover lives creates and checks nothing")
    func coverLocationIsPathWorkOnly() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-created-\(UUID().uuidString)", isDirectory: true)
        let downloaded = StorageLocations.coverFileLocation("x_cover.jpg", in: root)
        let custom = StorageLocations.coverFileLocation(
            "x\(StorageLocations.customCoverFilenameMarker)1.jpg",
            in: root
        )
        #expect(downloaded.deletingLastPathComponent().lastPathComponent == "Covers")
        #expect(custom.deletingLastPathComponent().lastPathComponent == "CustomCovers")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // The directory-creating form resolves to the very same file.
        #expect(StorageLocations.coverFileLocation("x_cover.jpg") == StorageLocations.coverFile("x_cover.jpg"))
    }

    @Test("An indexed cover is read from its absolute path")
    func indexedCoverReadsItsPath() async throws {
        let fixture = try CoverFixture()
        let url = fixture.root.appendingPathComponent("Works/covers/e1.jpg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Swatch.png(.red).write(to: url)
        let source = CoverImageSource.indexedCover(path: url.path)
        #expect(CoverImageIO.live.locate(source) == url)

        let image = try #require(await fixture.pipeline.image(for: CoverImageRequest(source: source, size: rung(240))).image)
        #expect(Swatch.tone(of: image) == "red")
        // Not a downloaded cover: 快取管理 emptying those leaves it alone.
        #expect(!source.isDownloadedBookCover)
    }

    // B
    @Test("Concurrent requests for one cover share one read and one decode")
    func concurrentRequestsCoalesce() async throws {
        let fixture = try CoverFixture()
        try fixture.store.write(Swatch.png(.red), filename: "b_cover.jpg")
        let request = fixture.request("b_cover.jpg", 640)
        let pipeline = fixture.pipeline
        fixture.probe.hold("b_cover.jpg")
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()

        let first = Task { await pipeline.image(for: request) }
        let held = await heldReads.next()
        #expect(held == "b_cover.jpg")
        let others = (0..<7).map { _ in Task { await pipeline.image(for: request) } }
        await waitUntil("seven requests joined the load in flight") {
            pipeline.counters.coalescedWaiters == 7
        }
        fixture.probe.release("b_cover.jpg")

        let image = try #require(await first.value.image)
        for other in others {
            #expect(await other.value.image === image)
        }
        #expect(fixture.probe.counts.reads == 1)
        #expect(fixture.probe.counts.decodes == 1)
        #expect(pipeline.counters.loadsStarted == 1)
        #expect(await pipeline.inflightKeyCount() == 0)
    }

    // C
    @MainActor
    @Test("Reading and decoding a cover never happen on the main thread")
    func loadWorkRunsOffTheMainThread() async throws {
        let fixture = try CoverFixture()
        try fixture.store.write(Swatch.png(.red), filename: "c_cover.jpg")
        try fixture.writeDefaultCover(Swatch.png(.blue), named: "c.png")
        MainActor.assertIsolated()

        #expect(await fixture.pipeline.image(for: fixture.request("c_cover.jpg", 240)).image != nil)
        let defaultCover = CoverImageRequest(source: .defaultCover(fileName: "c.png"), size: rung(240))
        #expect(await fixture.pipeline.image(for: defaultCover).image != nil)

        #expect(fixture.probe.counts.reads == 2)
        #expect(fixture.probe.counts.decodes == 2)
        #expect(fixture.probe.counts.mainThreadCalls == 0)
    }

    // D
    @MainActor
    @Test("Rewriting a cover under the same filename shows the new picture")
    func overwriteShowsTheNewPicture() async throws {
        let fixture = try CoverFixture()
        let name = "d_cover.jpg"
        try fixture.store.write(Swatch.png(.red), filename: name)
        let request = fixture.request(name, 240)
        #expect(Swatch.tone(of: try #require(await fixture.pipeline.image(for: request).image)) == "red")

        var received: [CoverInvalidation] = []
        let subscription = fixture.pipeline.invalidations.sink { received.append($0) }
        defer { subscription.cancel() }
        try fixture.store.write(Swatch.png(.blue), filename: name)

        #expect(received == [.sources([.bookCover(filename: name)])])
        #expect(fixture.pipeline.cachedResult(for: request) == nil)
        #expect(Swatch.tone(of: try #require(await fixture.pipeline.image(for: request).image)) == "blue")
    }

    // E
    @MainActor
    @Test("A load holding the bytes from before an overwrite publishes nothing")
    func overwriteDuringLoadIsNotRepublished() async throws {
        let fixture = try CoverFixture()
        let name = "e1_cover.jpg"
        try fixture.store.write(Swatch.png(.red), filename: name)
        let request = fixture.request(name, 240)
        let pipeline = fixture.pipeline
        fixture.probe.hold(name)
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()

        let stale = Task.detached { await pipeline.image(for: request) }
        let held = await heldReads.next()
        #expect(held == name)
        try fixture.store.write(Swatch.png(.blue), filename: name)
        fixture.probe.release(name)

        #expect(await stale.value.isSuperseded)
        #expect(pipeline.cachedResult(for: request) == nil)
        #expect(pipeline.counters.supersededResults == 1)
        #expect(Swatch.tone(of: try #require(await pipeline.image(for: request).image)) == "blue")
    }

    @MainActor
    @Test("A load holding a cover since deleted publishes nothing, and the next finds it missing")
    func deleteDuringLoadIsNotRepublished() async throws {
        let fixture = try CoverFixture()
        let name = "e2_cover.jpg"
        try fixture.store.write(Swatch.png(.red), filename: name)
        let request = fixture.request(name, 240)
        let pipeline = fixture.pipeline
        fixture.probe.hold(name)
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()

        let stale = Task.detached { await pipeline.image(for: request) }
        let held = await heldReads.next()
        #expect(held == name)
        fixture.store.remove(filename: name)
        fixture.probe.release(name)

        #expect(await stale.value.isSuperseded)
        #expect(pipeline.cachedResult(for: request) == nil)
        #expect(await pipeline.image(for: request).unavailableReason == .missing)
    }

    // E + I
    @MainActor
    @Test("Clearing the cover cache mid-load drops downloaded covers only; picked covers survive")
    func clearingTheCoverCacheMidLoad() async throws {
        let fixture = try CoverFixture()
        let downloaded = "i_cover.jpg"
        let custom = "i\(StorageLocations.customCoverFilenameMarker)1.jpg"
        try fixture.store.write(Swatch.png(.red), filename: downloaded)
        try fixture.store.write(Swatch.png(.blue), filename: custom)
        let downloadedRequest = fixture.request(downloaded, 240)
        let customRequest = fixture.request(custom, 240)
        let pipeline = fixture.pipeline

        fixture.probe.hold(downloaded)
        fixture.probe.hold(custom)
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()
        let downloadedLoad = Task.detached { await pipeline.image(for: downloadedRequest) }
        let customLoad = Task.detached { await pipeline.image(for: customRequest) }
        let firstHeld = await heldReads.next()
        let secondHeld = await heldReads.next()
        #expect(Set([firstHeld, secondHeld].compactMap { $0 }) == [downloaded, custom])

        var received: [CoverInvalidation] = []
        let subscription = pipeline.invalidations.sink { received.append($0) }
        defer { subscription.cancel() }
        let service = CacheManagementService(
            roots: fixture.cacheRoots,
            diagnosticLog: nil,
            coverPipeline: pipeline
        )
        try service.clear(.covers)
        fixture.probe.release(downloaded)
        fixture.probe.release(custom)

        #expect(await downloadedLoad.value.isSuperseded)
        #expect(await customLoad.value.image != nil)
        #expect(received == [.downloadedBookCovers])
        #expect(!FileManager.default.fileExists(atPath: fixture.url(downloaded).path))
        #expect(FileManager.default.fileExists(atPath: fixture.url(custom).path))
        #expect(await pipeline.image(for: downloadedRequest).unavailableReason == .missing)
        #expect(Swatch.tone(of: try #require(await pipeline.image(for: customRequest).image)) == "blue")
    }

    // F
    @Test("A consumer that leaves does not cancel the others, and nothing is left behind")
    func leavingConsumerDoesNotCancelOthers() async throws {
        let fixture = try CoverFixture()
        let name = "f_cover.jpg"
        try fixture.store.write(Swatch.png(.red), filename: name)
        let request = fixture.request(name, 240)
        let pipeline = fixture.pipeline
        fixture.probe.hold(name)
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()

        let leaving = Task { await pipeline.image(for: request) }
        let held = await heldReads.next()
        #expect(held == name)
        let staying = Task { await pipeline.image(for: request) }
        await waitUntil("the second consumer joined") { pipeline.counters.coalescedWaiters == 1 }

        leaving.cancel()
        // Answered while the read is still held: it stopped waiting rather than waiting it out.
        #expect(await leaving.value.isCancelled)
        fixture.probe.release(name)
        #expect(await staying.value.image != nil)
        #expect(fixture.probe.counts.reads == 1)
        #expect(await pipeline.inflightKeyCount() == 0)
    }

    @Test("Work nobody waits for any more never reaches the disk")
    func abandonedQueuedWorkNeverReads() async throws {
        let fixture = try CoverFixture(maxConcurrentLoads: 1)
        try fixture.store.write(Swatch.png(.red), filename: "busy_cover.jpg")
        try fixture.store.write(Swatch.png(.blue), filename: "queued_cover.jpg")
        let busyRequest = fixture.request("busy_cover.jpg", 240)
        let queuedRequest = fixture.request("queued_cover.jpg", 240)
        let pipeline = fixture.pipeline
        fixture.probe.hold("busy_cover.jpg")
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()

        let busy = Task { await pipeline.image(for: busyRequest) }
        let held = await heldReads.next()
        #expect(held == "busy_cover.jpg")
        let queued = Task { await pipeline.image(for: queuedRequest) }
        await waitUntil("the second load was queued") { pipeline.counters.loadsStarted == 2 }
        queued.cancel()
        #expect(await queued.value.isCancelled)

        fixture.probe.release("busy_cover.jpg")
        #expect(await busy.value.image != nil)
        await waitUntil("the queue skipped the abandoned load") {
            pipeline.counters.cancelledBeforeStart == 1
        }
        #expect(fixture.probe.counts.readsByName["queued_cover.jpg"] == nil)
        #expect(await pipeline.inflightKeyCount() == 0)
    }

    // G
    @MainActor
    @Test("A missing cover is remembered briefly and shows as soon as it is written")
    func missingCoverRecoversOnWrite() async throws {
        let fixture = try CoverFixture()
        let name = "g1_cover.jpg"
        let request = fixture.request(name, 240)

        #expect(await fixture.pipeline.image(for: request).unavailableReason == .missing)
        #expect(await fixture.pipeline.image(for: request).unavailableReason == .missing)
        #expect(fixture.probe.counts.reads == 1)
        #expect(fixture.pipeline.counters.negativeHits == 1)

        try fixture.store.write(Swatch.png(.red), filename: name)
        #expect(Swatch.tone(of: try #require(await fixture.pipeline.image(for: request).image)) == "red")
    }

    @Test("A corrupt cover is retried only once its failure expires, and a rewrite repairs it")
    func corruptCoverExpiresAndRecovers() async throws {
        let fixture = try CoverFixture(failureLifetime: 30)
        let name = "g2_cover.jpg"
        let url = fixture.url(name)
        // Written behind the pipeline's back, as no app flow would.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: url)
        let request = fixture.request(name, 240)

        #expect(await fixture.pipeline.image(for: request).unavailableReason == .undecodable)
        #expect(await fixture.pipeline.image(for: request).unavailableReason == .undecodable)
        #expect(fixture.probe.counts.reads == 1)

        fixture.clock.advance(by: 31)
        #expect(await fixture.pipeline.image(for: request).unavailableReason == .undecodable)
        #expect(fixture.probe.counts.reads == 2)

        try fixture.store.write(Swatch.png(.blue), filename: name)
        #expect(await fixture.pipeline.image(for: request).image != nil)
    }

    @MainActor
    @Test("A cover restored from iCloud replaces one found missing")
    func restoredCoverIsPickedUp() async throws {
        let fixture = try CoverFixture()
        let name = "r_cover.jpg"
        let request = fixture.request(name, 240)
        #expect(await fixture.pipeline.image(for: request).unavailableReason == .missing)

        var received: [CoverInvalidation] = []
        let subscription = fixture.pipeline.invalidations.sink { received.append($0) }
        defer { subscription.cancel() }
        // What the restore does: an atomic write it made itself, then the URL.
        try FileManager.default.createDirectory(
            at: fixture.url(name).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Swatch.png(.red).write(to: fixture.url(name), options: .atomic)
        fixture.pipeline.invalidateBookCover(at: fixture.url(name))
        // A restored book file is not a cover.
        fixture.pipeline.invalidateBookCover(at: fixture.root.appendingPathComponent("book.epub"))

        #expect(received == [.sources([.bookCover(filename: name)])])
        #expect(await fixture.pipeline.image(for: request).image != nil)
    }

    // H
    @Test("Writing a cover recreates a directory removed since launch")
    func writeRecreatesARemovedDirectory() throws {
        let fixture = try CoverFixture()
        let downloaded = "h_cover.jpg"
        let custom = "h\(StorageLocations.customCoverFilenameMarker)1.jpg"
        try fixture.store.write(Swatch.png(.red), filename: downloaded)
        let directory = fixture.url(downloaded).deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try fixture.store.write(Swatch.png(.blue), filename: downloaded)
        try fixture.store.write(Swatch.png(.blue), filename: custom)
        #expect(FileManager.default.fileExists(atPath: fixture.url(downloaded).path))
        #expect(FileManager.default.fileExists(atPath: fixture.url(custom).path))
    }

    // J
    @Test("Different sizes, sources and versions never share a bitmap")
    func requestsDoNotShareBitmaps() async throws {
        let fixture = try CoverFixture()
        let name = "j_cover.jpg"
        try fixture.store.write(Swatch.png(.red, width: 600, height: 900), filename: name)
        try fixture.writeDefaultCover(Swatch.png(.blue, width: 600, height: 900), named: name)
        let pipeline = fixture.pipeline

        let small = try #require(await pipeline.image(for: fixture.request(name, 240)).image)
        let large = try #require(await pipeline.image(for: fixture.request(name, 960)).image)
        #expect(small !== large)
        #expect(try #require(small.cgImage).height == 240)
        // The file is smaller than the rung: decoded at its own size, never upsampled.
        #expect(try #require(large.cgImage).height == 900)

        let sameName = CoverImageRequest(source: .defaultCover(fileName: name), size: rung(240))
        #expect(Swatch.tone(of: try #require(await pipeline.image(for: sameName).image)) == "blue")
        #expect(Swatch.tone(of: small) == "red")

        // A new version does not join a load of the old one still in flight.
        let request = fixture.request(name, 480)
        fixture.probe.hold(name)
        var heldReads = fixture.probe.heldReads.makeAsyncIterator()
        let old = Task { await pipeline.image(for: request) }
        let oldRead = await heldReads.next()
        #expect(oldRead == name)
        pipeline.invalidate([.bookCover(filename: name)])
        let new = Task { await pipeline.image(for: request) }
        // A second read of its own, not a join.
        let newRead = await heldReads.next()
        #expect(newRead == name)
        fixture.probe.release(name)

        #expect(await old.value.isSuperseded)
        #expect(await new.value.image != nil)
        #expect(pipeline.counters.coalescedWaiters == 0)
    }

    @Test("Slot sizes map onto a few decode sizes")
    func slotSizesMapToRungs() {
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 45, height: 65), scale: 3)?.longEdge == 240)
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 45, height: 65), scale: 2)?.longEdge == 160)
        // Fractional grid columns do not mint new keys.
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 122.33, height: 183.5), scale: 3)?.longEdge == 640)
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 122.34, height: 183.51), scale: 3)?.longEdge == 640)
        // 書籍資訊's hero.
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 176, height: 264), scale: 3)?.longEdge == 960)
        // A slot wider than 2:3 is still covered edge to edge.
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 100, height: 100), scale: 2)?.longEdge == 320)
        #expect(CoverPixelSize.fitting(pointSize: CGSize(width: 900, height: 1350), scale: 3) == .largest)
        #expect(CoverPixelSize.fitting(pointSize: .zero, scale: 3) == nil)
    }

    @Test("A cover is decoded just large enough to fill its slot")
    func decodeSizeFillsTheSlot() {
        #expect(CoverImageDecoder.fillingLongEdge(pixelWidth: 1400, pixelHeight: 2100, box: rung(640)) == 640)
        // Landscape art has to cover the slot's height.
        #expect(CoverImageDecoder.fillingLongEdge(pixelWidth: 2000, pixelHeight: 1000, box: rung(640)) == 1280)
        #expect(CoverImageDecoder.fillingLongEdge(pixelWidth: 300, pixelHeight: 450, box: rung(640)) == 450)
    }

    @MainActor
    @Test("A 預設封面 library change drops only default-cover bitmaps")
    func defaultCoverInvalidationIsScoped() async throws {
        let fixture = try CoverFixture()
        try fixture.store.write(Swatch.png(.red), filename: "k_cover.jpg")
        try fixture.writeDefaultCover(Swatch.png(.blue), named: "k.png")
        let bookCover = fixture.request("k_cover.jpg", 240)
        let defaultCover = CoverImageRequest(source: .defaultCover(fileName: "k.png"), size: rung(240))
        _ = await fixture.pipeline.image(for: bookCover)
        _ = await fixture.pipeline.image(for: defaultCover)

        fixture.pipeline.invalidateDefaultCovers()

        #expect(fixture.pipeline.cachedImage(for: defaultCover) == nil)
        #expect(fixture.pipeline.cachedImage(for: bookCover) != nil)
    }
}

// MARK: - Bookshelf slot and transition

@MainActor
@Suite("Bookshelf cover slot")
struct BookshelfCoverArtworkTests {
    private func render(
        _ book: ReadingBook,
        plan: BookshelfCoverPlan,
        pipeline: CoverImagePipeline,
        size: CGSize
    ) throws -> UIImage {
        let renderer = ImageRenderer(
            content: BookshelfCoverArtwork(book: book, plan: plan, displaySize: size)
                .frame(width: size.width, height: size.height)
                .environment(\.coverImagePipeline, pipeline)
                .environment(\.displayScale, 2)
        )
        renderer.scale = 2
        return try #require(renderer.uiImage)
    }

    private func book(coverImagePath: String?) -> ReadingBook {
        var book = ReadingBook(title: "書架測試", author: "作者", contentFilename: "x.txt")
        book.coverImagePath = coverImagePath
        return book
    }

    @Test("A cover already in memory paints in the first pass: no placeholder, no read")
    func cachedCoverPaintsInTheFirstPass() async throws {
        let fixture = try CoverFixture()
        try fixture.store.write(Swatch.png(.red), filename: "v_cover.jpg")
        let book = book(coverImagePath: "v_cover.jpg")
        let slot = CGSize(width: 45, height: 65)
        let size = try #require(CoverPixelSize.fitting(pointSize: slot, scale: 2))
        _ = await fixture.pipeline.image(
            for: CoverImageRequest(source: .bookCover(filename: "v_cover.jpg"), size: size)
        )
        let reads = fixture.probe.counts.reads

        let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: .light, forcesDefaultCover: false)
        let rendered = try render(book, plan: plan, pipeline: fixture.pipeline, size: slot)

        #expect(Swatch.tone(of: rendered) == "red")
        #expect(fixture.probe.counts.reads == reads)
        #expect(fixture.probe.counts.mainThreadCalls == 0)
    }

    @Test("A cover not decoded yet shows the placeholder, and nothing reads it on the main thread")
    func uncachedCoverShowsThePlaceholder() throws {
        let fixture = try CoverFixture()
        try fixture.store.write(Swatch.png(.red), filename: "w_cover.jpg")
        let book = book(coverImagePath: "w_cover.jpg")
        let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: .light, forcesDefaultCover: false)

        let rendered = try render(book, plan: plan, pipeline: fixture.pipeline, size: CGSize(width: 45, height: 65))

        #expect(Swatch.tone(of: rendered) == "grey")
        // `ImageRenderer` starts the slot's task, so a load may already be under
        // way; it must be on the executor. Body-time I/O would be counted here.
        #expect(fixture.probe.counts.mainThreadCalls == 0)
    }

    @Test("A saved cover known to be missing falls back to the generated cover")
    func missingSavedCoverFallsBack() async throws {
        let fixture = try CoverFixture()
        let book = book(coverImagePath: "gone_cover.jpg")
        let slot = CGSize(width: 45, height: 65)
        let size = try #require(CoverPixelSize.fitting(pointSize: slot, scale: 2))
        let missing = await fixture.pipeline.image(
            for: CoverImageRequest(source: .bookCover(filename: "gone_cover.jpg"), size: size)
        )
        #expect(missing.unavailableReason == .missing)
        // Built by hand so the test does not depend on this device's 預設封面 library.
        let plan = BookshelfCoverPlan(
            ownCover: .bookCover(filename: "gone_cover.jpg"),
            catalogFallback: nil,
            defaultCover: nil,
            title: book.title,
            author: book.author
        )

        let rendered = try render(book, plan: plan, pipeline: fixture.pipeline, size: slot)
        let generatedRenderer = ImageRenderer(
            content: GeneratedBookCover(title: book.title, author: book.author)
                .frame(width: slot.width, height: slot.height)
                .environment(\.displayScale, 2)
        )
        generatedRenderer.scale = 2
        let generated = try #require(generatedRenderer.uiImage)

        #expect(rendered.pngData() == generated.pngData())
    }

    @Test("The shelf's order: saved cover, catalog cover, 預設封面, generated")
    func shelfPlanOrder() {
        var book = book(coverImagePath: "saved_cover.jpg")
        var plan = BookshelfCoverPlan.shelf(for: book, colorScheme: .light, forcesDefaultCover: false)
        #expect(plan.ownCover == .bookCover(filename: "saved_cover.jpg"))
        #expect(plan.catalogFallback == nil)

        // 強制使用預設封面 ignores the book's own artwork everywhere.
        plan = .shelf(for: book, colorScheme: .light, forcesDefaultCover: true)
        #expect(plan.ownCover == nil)
        #expect(plan.catalogFallback == nil)

        // A remote-library book falls back to its catalog cover, not straight to 預設封面.
        let format = RemoteLibraryFormat(
            url: URL(string: "https://library.example/b.epub")!,
            fileExtension: "epub",
            mimeType: "application/epub+zip"
        )
        book.remoteSource = RemoteBookReference(connectionID: "c", entryID: "e", format: format)
        book.coverUrl = "https://library.example/c.jpg"
        plan = .shelf(for: book, colorScheme: .light, forcesDefaultCover: false)
        #expect(plan.ownCover == .bookCover(filename: "saved_cover.jpg"))
        #expect(plan.catalogFallback == .init(defaultCoverSeed: book.id.uuidString))
        #expect(BookshelfCoverPlan.shelf(for: book, colorScheme: .light, forcesDefaultCover: true)
            .catalogFallback == nil)

        // 書籍資訊 shows the saved cover even when forced, then the book's own address.
        let info = BookshelfCoverPlan.bookInfo(for: book)
        #expect(info.ownCover == .bookCover(filename: "saved_cover.jpg"))
        #expect(info.catalogFallback == .init(defaultCoverSeed: nil))
    }

    @Test("The transition snapshot of a cover not decoded yet reads nothing")
    func transitionSnapshotIsMemoryOnly() {
        let settings = GlobalSettings.shared
        let forced = settings.useDefaultCoverForAllBooks
        settings.useDefaultCoverForAllBooks = false
        defer { settings.useDefaultCoverForAllBooks = forced }
        let filename = "\(UUID().uuidString)_cover.jpg"
        let book = book(coverImagePath: filename)

        #expect(BookshelfCoverStyle.image(for: book, colorScheme: .light) == nil)
        // Like the card, which still shows its placeholder: a plain card, no upgrade.
        #expect(BookshelfCoverStyle.snapshot(
            for: book, colorScheme: .light, sourceSize: CGSize(width: 45, height: 65)
        ) == nil)
        #expect(BookshelfCoverStyle.snapshotUpgrade(for: book, colorScheme: .light) == nil)
        // Any read would have found the file missing and remembered it.
        #expect(!CoverImagePipeline.shared.isKnownUnavailable(.bookCover(filename: filename)))
    }

    @Test("The transition takes a sharper rendering of the same artwork, and nothing else")
    func transitionUpgradeRules() {
        let thumbnail = Swatch.solid(.red, width: 160, height: 240)
        let sharper = Swatch.solid(.red, width: 853, height: 1280)
        let otherShape = Swatch.solid(.red, width: 1280, height: 853)
        let smaller = Swatch.solid(.red, width: 80, height: 120)
        let id = UUID()

        #expect(ReaderTransitionSource(bookID: id, snapshotUpgrade: { sharper }).bestAvailableSnapshot() == nil)
        #expect(ReaderTransitionSource(bookID: id, snapshot: thumbnail, snapshotUpgrade: { nil })
            .bestAvailableSnapshot() === thumbnail)
        let upgraded = ReaderTransitionSource(bookID: id, snapshot: thumbnail, snapshotUpgrade: { sharper })
        #expect(upgraded.bestAvailableSnapshot() === sharper)
        #expect(upgraded.replacingDirection(.rightSpine).bestAvailableSnapshot() === sharper)
        #expect(ReaderTransitionSource(bookID: id, snapshot: thumbnail, snapshotUpgrade: { otherShape })
            .bestAvailableSnapshot() === thumbnail)
        #expect(ReaderTransitionSource(bookID: id, snapshot: thumbnail, snapshotUpgrade: { smaller })
            .bestAvailableSnapshot() === thumbnail)
    }
}
