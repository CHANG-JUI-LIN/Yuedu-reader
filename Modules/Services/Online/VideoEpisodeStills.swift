import ImageIO
import os
import UIKit

/// An episode's still for 選集, and how long the episode runs when the stream said.
struct VideoEpisodeStill: Sendable {
    let image: UIImage
    let duration: TimeInterval?
}

/// Episode stills taken from the episodes themselves (maintainer, 2026-11-01: 「做，只截看得到的
/// 幾集」): sources give no stills, so a card on screen resolves its episode's link as the player
/// does (`VideoChapterLinks.stream`) and takes one frame of it (`VideoStillExtractor`).
///
/// The bytes live where network covers do (`CoverImagePipeline`'s memory and `NetworkCovers`
/// on disk, cleared with 封面 in 快取管理 and trimmed with them), keyed by the source and the
/// episode's address — never by the stream, whose signed URL changes, nor by a book id. The
/// pipeline coalesces requests for one episode; a card that scrolls away before its still is
/// taken cancels it (`.cancelWork`), so only episodes someone is looking at are fetched, at
/// most `concurrentStills` at a time.
@MainActor
final class VideoEpisodeStills {
    static let shared = VideoEpisodeStills()

    /// Each still resolves a link (a source's rules, sometimes its player page in a web view)
    /// and opens a stream: two at once keep a row of cards filling without crowding playback.
    static let concurrentStills = 2

    private let pipeline: CoverImagePipeline
    private let gate = VideoStillGate(limit: VideoEpisodeStills.concurrentStills)
    /// The running time of every still decoded this launch, by key. A memory hit in the
    /// pipeline is always a still that went through `remember`, so its time is here.
    private let durations = OSAllocatedUnfairLock<[String: TimeInterval]>(initialState: [:])
    /// Episodes whose still could not be taken this launch (a DASH or audio-only episode, a
    /// player page with no video): scrolling back to one does not resolve it again.
    private var failed: Set<String> = []

    init(pipeline: CoverImagePipeline = .shared) {
        self.pipeline = pipeline
    }

    nonisolated static func key(sourceId: UUID, chapterURL: String) -> String {
        "videoStill|\(sourceId.uuidString)|\(chapterURL)"
    }

    /// The still if memory has it: cheap enough for a view's initializer.
    func cachedStill(forKey key: String) -> VideoEpisodeStill? {
        guard let image = pipeline.cachedNetworkImage(forKey: key) else { return nil }
        return VideoEpisodeStill(image: image, duration: durations.withLock { $0[key] })
    }

    /// `book`'s episode at `chapterIndex`, from memory, disk, or the episode itself. Nil when
    /// it cannot be taken or the caller was cancelled.
    func still(
        forKey key: String,
        book: ReadingBook,
        chapterIndex: Int,
        store: BookStore,
        pixelSize: CGSize
    ) async -> VideoEpisodeStill? {
        if let cached = cachedStill(forKey: key) { return cached }
        guard !failed.contains(key) else { return nil }
        let durations = durations
        let gate = gate
        let image = await pipeline.coalescedNetworkLoad(
            key: key,
            abandonment: .cancelWork,
            decode: { Self.remember($0, forKey: key, in: durations) }
        ) {
            do {
                return try await Self.take(key: key, book: book, chapterIndex: chapterIndex, store: store,
                                           pixelSize: pixelSize, gate: gate, durations: durations)
            } catch {
                if error is CancellationError || Task.isCancelled { return nil }
                await self.recordFailure(key: key, chapterIndex: chapterIndex, error: error)
                return nil
            }
        }
        guard let image else { return nil }
        return VideoEpisodeStill(image: image, duration: durations.withLock { $0[key] })
    }

    private func recordFailure(key: String, chapterIndex: Int, error: Error) {
        failed.insert(key)
        AppLogger.network("[Video] episode still not taken", error: error,
                          context: ["episode": chapterIndex, "key": String(key.suffix(160))], level: .notice)
    }

    private nonisolated static func take(
        key: String,
        book: ReadingBook,
        chapterIndex: Int,
        store: BookStore,
        pixelSize: CGSize,
        gate: VideoStillGate,
        durations: OSAllocatedUnfairLock<[String: TimeInterval]>
    ) async throws -> FetchedNetworkCover {
        try await gate.enter()
        let frame: VideoStillFrame
        do {
            do {
                frame = try await frameOf(book: book, chapterIndex: chapterIndex, store: store, pixelSize: pixelSize)
            } catch where isStaleLink(error) {
                // The link may be one the chapter cache kept from an earlier visit or play, and a
                // CDN's signed links expire: discard it and resolve the episode once more, the
                // one retry the player gives a link that fails to play.
                AppLogger.network("[Video] still's link failed; resolving it again", error: error,
                                  context: ["episode": chapterIndex], level: .notice)
                await VideoChapterLinks.discardResolvedLink(for: book, chapterIndex: chapterIndex, store: store)
                frame = try await frameOf(book: book, chapterIndex: chapterIndex, store: store, pixelSize: pixelSize)
            }
        } catch {
            await gate.leave()
            throw error
        }
        await gate.leave()
        guard let image = remember(frame.jpeg, forKey: key, in: durations) else {
            throw VideoStillError.notEncodable
        }
        return FetchedNetworkCover(image: image, bytes: frame.jpeg)
    }

    private nonisolated static func frameOf(
        book: ReadingBook,
        chapterIndex: Int,
        store: BookStore,
        pixelSize: CGSize
    ) async throws -> VideoStillFrame {
        let resolveStart = SourcePerfTrace.now
        let stream = try await VideoChapterLinks.stream(
            for: book, chapterIndex: chapterIndex, priority: .prefetch, store: store
        )
        SourcePerfTrace.record("video.still.resolve", "episode=\(chapterIndex)", since: resolveStart)
        let extractStart = SourcePerfTrace.now
        let frame = try await VideoStillExtractor.still(of: stream, fitting: pixelSize)
        SourcePerfTrace.record("video.still.extract", "episode=\(chapterIndex) bytes=\(frame.jpeg.count)",
                               since: extractStart)
        return frame
    }

    /// A failure a newly resolved link could cure: the stream refused or never answered, or the
    /// cached content is not a link (a chapter cached before the book was known as a video).
    /// Not one the episode itself causes — DASH, a player page with no video, no picture.
    private nonisolated static func isStaleLink(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        switch error {
        case VideoChapterLinkError.notALink: return true
        case is VideoChapterLinkError: return false
        case VideoStillError.timedOut: return true
        case is VideoStillError: return false
        default: return true
        }
    }

    /// Decodes a still's bytes, already sized for its card, and keeps the running time they
    /// carry. Saved and freshly taken stills both come through here.
    private nonisolated static func remember(
        _ jpeg: Data,
        forKey key: String,
        in durations: OSAllocatedUnfairLock<[String: TimeInterval]>
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        if let duration = VideoStillCoding.duration(in: jpeg) {
            durations.withLock { $0[key] = duration }
        }
        return UIImage(cgImage: image)
    }
}

/// At most `limit` stills being taken; the rest wait their turn, and a wait whose card has
/// scrolled away ends at once rather than when a slot frees.
actor VideoStillGate {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    init(limit: Int) {
        self.limit = limit
    }

    var runningCount: Int { running }
    var waitingCount: Int { waiting.count }

    func enter() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        nextID &+= 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
        // `leave()` handed its slot straight to this one; `running` already counts it.
    }

    /// Every successful `enter` is paired with one `leave`.
    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func withdraw(_ id: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
