import Combine
import Foundation
import ImageIO
import OSLog
import UIKit

// MARK: - Vocabulary

/// Where a cover's pixels come from. Two sources never share a bitmap, whatever
/// their file names.
enum CoverImageSource: Hashable, Sendable {
    /// A book's saved cover, `ReadingBook.coverImagePath`, which `StorageLocations`
    /// routes to `Covers` or `CustomCovers` by the filename marker.
    case bookCover(filename: String)
    /// An image in the user's 預設封面 library.
    case defaultCover(fileName: String)
    /// A cover another store keeps, by absolute path: the WebDAV index's covers in
    /// `Caches/Works/covers` (unified library 2d), drawn on Explore's home (5c).
    case indexedCover(path: String)

    /// Downloaded covers sit in the directory 設定 → 快取管理 empties wholesale.
    /// Covers the user picked (`CustomCovers`) and the 預設封面 library do not.
    var isDownloadedBookCover: Bool {
        guard case .bookCover(let filename) = self else { return false }
        return !StorageLocations.isCustomCoverFilename(filename)
    }

    fileprivate var keyComponent: String {
        switch self {
        case .bookCover(let filename): return "book-cover|\(filename)"
        case .defaultCover(let fileName): return "default-cover|\(fileName)"
        case .indexedCover(let path): return "indexed-cover|\(path)"
        }
    }

    /// Log-safe: the kind of source, never its name or path.
    fileprivate var diagnosticKind: String {
        switch self {
        case .bookCover(let filename):
            return StorageLocations.isCustomCoverFilename(filename) ? "custom" : "downloaded"
        case .defaultCover:
            return "default"
        case .indexedCover:
            return "indexed"
        }
    }
}

/// How large a cover is decoded: the long edge, in pixels, of the portrait 2:3 box
/// the bitmap has to fill.
///
/// Only a few rungs exist. A grid column 122.33pt wide must not mint its own cache
/// key, and invalidating a source has to reach every size it was ever decoded at.
struct CoverPixelSize: Hashable, Comparable, Sendable {
    let longEdge: Int

    private init(longEdge: Int) {
        self.longEdge = longEdge
    }

    /// A shelf row (45×65pt) needs 240 at 3x, a three-column iPhone grid 640, a
    /// two-column iPad grid 960. The top rung serves the open-book transition, which
    /// grows the cover toward full screen, and Now Playing artwork.
    static let all: [CoverPixelSize] = [160, 240, 320, 480, 640, 960, 1280]
        .map(CoverPixelSize.init(longEdge:))

    /// The ceiling `BookCoverLoader.decodedCover` has always used, for callers that
    /// know no slot size.
    static let standard = CoverPixelSize(longEdge: 640)
    static let largest = CoverPixelSize(longEdge: 1280)

    /// The smallest rung whose 2:3 box covers a slot of `pointSize` drawn at `scale`,
    /// or nil for a slot that has not been laid out yet.
    static func fitting(pointSize: CGSize, scale: CGFloat) -> CoverPixelSize? {
        guard pointSize.width > 0, pointSize.height > 0, scale > 0 else { return nil }
        // A 2:3 box with long edge L is L·2/3 wide, so a slot wider than 2:3 needs
        // L ≥ width·1.5 to be covered edge to edge.
        let needed = (max(pointSize.height, pointSize.width * 1.5) * scale).rounded(.down)
        return all.first { CGFloat($0.longEdge) >= needed } ?? largest
    }

    static func < (lhs: CoverPixelSize, rhs: CoverPixelSize) -> Bool {
        lhs.longEdge < rhs.longEdge
    }
}

struct CoverImageRequest: Hashable, Sendable {
    let source: CoverImageSource
    let size: CoverPixelSize

    fileprivate var memoryKey: NSString {
        "\(source.keyComponent)|\(size.longEdge)" as NSString
    }
}

enum CoverUnavailableReason: Sendable, Equatable {
    /// No file at the path.
    case missing
    /// The file exists but could not be read, or a network fetch failed.
    case unreadable
    /// The bytes are not an image ImageIO can decode.
    case undecodable
}

enum CoverImageResult: Sendable {
    case image(UIImage)
    case unavailable(CoverUnavailableReason)
    /// The source changed on disk while this load was running, so its bitmap was
    /// dropped instead of published. The views showing that source receive a
    /// `CoverInvalidation` and ask again.
    case superseded
    /// The caller stopped waiting, or nobody wanted the work before it started.
    case cancelled

    var image: UIImage? {
        if case .image(let image) = self { return image }
        return nil
    }
}

/// Sent on the main thread when cover files change on disk, so a view holding a
/// bitmap for an affected source drops it and loads again.
enum CoverInvalidation: Sendable, Equatable {
    case sources(Set<CoverImageSource>)
    /// 快取管理 emptied the downloaded-cover directory.
    case downloadedBookCovers
    /// The 預設封面 library changed.
    case defaultCovers

    func affects(_ source: CoverImageSource) -> Bool {
        switch self {
        case .sources(let sources):
            return sources.contains(source)
        case .downloadedBookCovers:
            return source.isDownloadedBookCover
        case .defaultCovers:
            if case .defaultCover = source { return true }
            return false
        }
    }
}

/// Exact event counts. Always kept: a few integer increments under a lock the
/// pipeline takes anyway. Tests assert on them; the diagnostics log summarizes them.
struct CoverPipelineCounters: Sendable, Equatable {
    var memoryHits = 0
    var negativeHits = 0
    var misses = 0
    var loadsStarted = 0
    var coalescedWaiters = 0
    var fileReads = 0
    var decodes = 0
    var readNanoseconds: UInt64 = 0
    var decodeNanoseconds: UInt64 = 0
    var supersededResults = 0
    var cancelledBeforeStart = 0
}

/// Everything the pipeline does to the outside world. Injectable so tests can count
/// reads and decodes exactly and run against a temporary directory.
struct CoverImageIO: Sendable {
    /// Pure path arithmetic: no directory creation, no `stat`.
    var locate: @Sendable (CoverImageSource) -> URL
    var read: @Sendable (URL) throws -> Data
    var decode: @Sendable (Data, CoverPixelSize) -> UIImage?

    static let live = CoverImageIO(
        locate: { source in
            switch source {
            case .bookCover(let filename):
                return StorageLocations.coverFileLocation(filename)
            case .defaultCover(let fileName):
                return DefaultCoverStorageManager.imageLocation(fileName: fileName)
            case .indexedCover(let path):
                return URL(fileURLWithPath: path)
            }
        },
        // Not memory-mapped: a mapped file truncated by a writer mid-decode faults.
        read: { url in try Data(contentsOf: url) },
        decode: { data, size in CoverImageDecoder.thumbnail(from: data, filling: size) }
    )
}

// MARK: - Decoding

/// Turns encoded cover bytes into a bitmap that is already decoded and no larger
/// than its slot needs, so the first draw on the main thread has nothing left to do.
enum CoverImageDecoder {
    /// Nil when ImageIO cannot read the bytes. Deliberately no `UIImage(data:)`
    /// fallback: that image decodes lazily, at full size, on the main thread, the
    /// cost this type exists to keep off the shelf.
    static func thumbnail(from data: Data, filling size: CoverPixelSize) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }

        var maxPixelSize = size.longEdge
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            // EXIF orientations 5–8 are quarter turns: the upright image swaps its sides.
            let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let upright = (5...8).contains(orientation) ? (height, width) : (width, height)
            maxPixelSize = fillingLongEdge(pixelWidth: upright.0, pixelHeight: upright.1, box: size)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// The long edge at which an image of this size covers `box`'s 2:3 portrait
    /// frame edge to edge (`scaledToFill`). Never larger than the image itself.
    static func fillingLongEdge(pixelWidth: Int, pixelHeight: Int, box: CoverPixelSize) -> Int {
        guard pixelWidth > 0, pixelHeight > 0 else { return box.longEdge }
        let boxHeight = CGFloat(box.longEdge)
        let boxWidth = boxHeight * 2 / 3
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let scale = min(1, max(boxWidth / width, boxHeight / height))
        // The epsilon keeps floating-point noise (640.0000001) from rounding up a pixel.
        return max(1, Int((max(width, height) * scale - 0.001).rounded(.up)))
    }
}

// MARK: - Execution

/// Runs the blocking half of a load, the file read and the decode, on a small
/// OperationQueue: never on the main thread, and never more than `maxConcurrent`
/// at once however fast the shelf is flung. Work every consumer abandoned before it
/// started is dropped without touching the disk.
final class CoverLoadExecutor: Sendable {
    private let queue: OperationQueue

    init(maxConcurrent: Int) {
        let queue = OperationQueue()
        queue.name = "Yuedu.CoverLoad"
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .userInitiated
        self.queue = queue
    }

    func run(
        priority: Operation.QueuePriority,
        onCancelledBeforeStart: @escaping @Sendable () -> Void,
        _ work: @escaping @Sendable () -> CoverImageResult
    ) async -> CoverImageResult {
        // Resumed exactly once: by the work when it runs, or by the completion block
        // when the queue skipped it because it was cancelled before it started.
        let pending = OSAllocatedUnfairLock<CheckedContinuation<CoverImageResult, Never>?>(initialState: nil)
        @Sendable func deliver(_ result: CoverImageResult) -> Bool {
            let continuation = pending.withLock { slot -> CheckedContinuation<CoverImageResult, Never>? in
                defer { slot = nil }
                return slot
            }
            continuation?.resume(returning: result)
            return continuation != nil
        }

        let operation = BlockOperation {
            _ = deliver(work())
        }
        operation.queuePriority = priority
        operation.completionBlock = {
            if deliver(.cancelled) { onCancelledBeforeStart() }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.withLock { $0 = continuation }
                queue.addOperation(operation)
            }
        } onCancel: {
            // Only stops work still waiting in the queue; a read already in progress
            // finishes (one file, bounded) and publishes if its version is current.
            operation.cancel()
        }
    }
}

/// Coalesces concurrent loads of one key: the work runs once and every waiter gets
/// its result. The network path (keyed by URL and session) and the file path (keyed
/// by source, size and version) share it, so there is one mechanism, not two.
///
/// A waiter whose task is cancelled, a cell scrolled away, stops waiting at once
/// without disturbing anyone else. What happens when the *last* waiter leaves is the
/// key's `Abandonment`.
actor CoverInflightStore {
    enum Abandonment: Sendable {
        /// File loads: cancel the work. If it has not reached the disk it never will;
        /// decoding covers nobody is going to draw is not free.
        case cancelWork
        /// Network fetches: let it finish and cache, as it always has. Scrolling
        /// back to a slow CDN cover should not start the download over.
        case finishWork
    }

    private struct Entry {
        let id: UInt64
        let task: Task<Void, Never>
        let abandonment: Abandonment
        var waiters: [UInt64: CheckedContinuation<CoverImageResult, Never>]
    }

    private var entries: [String: Entry] = [:]
    private var nextID: UInt64 = 0

    /// Keys with work still running. Tests use it to prove nothing is left behind.
    var activeKeyCount: Int { entries.count }

    func result(
        for key: String,
        abandonment: Abandonment,
        onStart: @escaping @Sendable () -> Void = {},
        onJoin: @escaping @Sendable () -> Void = {},
        work: @escaping @Sendable () async -> CoverImageResult
    ) async -> CoverImageResult {
        nextID &+= 1
        let waiterID = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(
                    waiterID: waiterID,
                    continuation: continuation,
                    key: key,
                    abandonment: abandonment,
                    onStart: onStart,
                    onJoin: onJoin,
                    work: work
                )
            }
        } onCancel: {
            Task { await self.abandon(waiterID: waiterID, key: key) }
        }
    }

    private func register(
        waiterID: UInt64,
        continuation: CheckedContinuation<CoverImageResult, Never>,
        key: String,
        abandonment: Abandonment,
        onStart: @Sendable () -> Void,
        onJoin: @Sendable () -> Void,
        work: @escaping @Sendable () async -> CoverImageResult
    ) {
        // Already cancelled on arrival: start nothing on its behalf.
        if Task.isCancelled {
            continuation.resume(returning: .cancelled)
            return
        }
        if var entry = entries[key] {
            entry.waiters[waiterID] = continuation
            entries[key] = entry
            onJoin()
            return
        }
        nextID &+= 1
        let entryID = nextID
        onStart()
        // Inherits this actor: `work` itself is nonisolated and runs off it, and the
        // bookkeeping after it runs back on it.
        let task = Task {
            let result = await work()
            self.finish(key: key, entryID: entryID, result: result)
        }
        entries[key] = Entry(
            id: entryID,
            task: task,
            abandonment: abandonment,
            waiters: [waiterID: continuation]
        )
    }

    private func finish(key: String, entryID: UInt64, result: CoverImageResult) {
        // A key abandoned and then requested again belongs to newer work.
        guard let entry = entries[key], entry.id == entryID else { return }
        entries[key] = nil
        for continuation in entry.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func abandon(waiterID: UInt64, key: String) {
        guard var entry = entries[key],
              let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: .cancelled)
        if entry.waiters.isEmpty, entry.abandonment == .cancelWork {
            entries[key] = nil
            entry.task.cancel()
        } else {
            entries[key] = entry
        }
    }
}

// MARK: - Pipeline

/// Every cover bitmap the app draws from disk or network, under one memory budget.
///
/// Three layers, kept apart on purpose:
/// - **Memory lookup** (`cachedImage`, `cachedResult`): reads only what is already
///   decoded, or a recent failure. No path, no `stat`, no read, no decode. Cheap
///   enough for a view body.
/// - **Loading** (`image(for:)`): coalesced per source, size and version; the read
///   and decode run on `CoverLoadExecutor`, off the main thread and bounded.
/// - **Invalidation** (`invalidate…`): when a cover file changes on disk, drops its
///   bitmaps and failure record, makes loads already reading it publish nothing, and
///   tells the views showing it.
///
/// Thread safety: `state` is an unfair lock guarding every mutable field. `memory`
/// is an `NSCache`, which is internally synchronized; its inserts and removals are
/// additionally made under `state` so a version check and the publish it guards are
/// one step (see `publish`). `invalidations` only ever sends on the main thread.
/// That is what the `@unchecked Sendable` rests on: `NSCache` and the Combine subject
/// are not annotated `Sendable`, although both are used as described.
final class CoverImagePipeline: @unchecked Sendable {
    static let shared = CoverImagePipeline()

    /// Network covers, saved book covers and 預設封面 bitmaps together. The same
    /// 128 MB `BookCoverLoader` has always had; 預設封面 used to keep a separate
    /// uncosted cache on top of it.
    static let memoryCostLimit = 128 * 1024 * 1024
    static let memoryCountLimit = 600

    /// A failure is trusted this long before a new request reads the file again.
    /// Every writer the app has invalidates explicitly; this bound is for anything
    /// that changes a file without going through them, so a failure is never
    /// remembered forever. It only affects new requests: a view already showing the
    /// fallback does not poll.
    static let defaultFailureLifetime: TimeInterval = 30
    /// Failure records kept at most; the oldest go first.
    static let failureCapacity = 256

    private struct FailureRecord: Sendable {
        let reason: CoverUnavailableReason
        let version: UInt64
        let recordedAt: TimeInterval
    }

    private struct State: Sendable {
        /// Bumped by every invalidation; versions are values of it.
        var epoch: UInt64 = 0
        var downloadedBookCoversEpoch: UInt64 = 0
        var defaultCoversEpoch: UInt64 = 0
        /// Only sources invalidated one by one; a directory-wide epoch supersedes them.
        var sourceEpochs: [CoverImageSource: UInt64] = [:]
        var failures: [CoverImageSource: FailureRecord] = [:]
        /// 預設封面 bitmaps in `memory`, so a library change can drop exactly those.
        var defaultCoverKeys: Set<String> = []
        var counters = CoverPipelineCounters()
        var lastSummaryAt: TimeInterval = 0
    }

    private let memory: NSCache<NSString, UIImage>
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let inflight = CoverInflightStore()
    private let executor: CoverLoadExecutor
    private let io: CoverImageIO
    private let failureLifetime: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let invalidationSubject = PassthroughSubject<CoverInvalidation, Never>()
    /// Delivered on the main thread. Stored, not computed, so every view body hands
    /// `onReceive` the same publisher and SwiftUI keeps its one subscription.
    let invalidations: AnyPublisher<CoverInvalidation, Never>
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yuedu.app",
        category: "CoverPipeline"
    )
    /// `-yd_cover_pipeline_diagnostics YES` (launch argument) or the same defaults key:
    /// a `⏱ cover.pipeline` counter summary at most every 5 seconds while covers load.
    /// Signposts are always emitted; they cost next to nothing unless Instruments records.
    private let logsSummaries: Bool

    init(
        io: CoverImageIO = .live,
        maxConcurrentLoads: Int = 2,
        memoryCostLimit: Int = CoverImagePipeline.memoryCostLimit,
        memoryCountLimit: Int = CoverImagePipeline.memoryCountLimit,
        failureLifetime: TimeInterval = CoverImagePipeline.defaultFailureLifetime,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        logsSummaries: Bool = UserDefaults.standard.bool(forKey: "yd_cover_pipeline_diagnostics")
    ) {
        let memory = NSCache<NSString, UIImage>()
        // Entries carry their decoded-bitmap byte size as cost. NSCache still empties
        // itself under memory pressure regardless of the limit.
        memory.totalCostLimit = memoryCostLimit
        memory.countLimit = memoryCountLimit
        self.memory = memory
        self.io = io
        self.executor = CoverLoadExecutor(maxConcurrent: maxConcurrentLoads)
        self.failureLifetime = failureLifetime
        self.now = now
        self.logsSummaries = logsSummaries
        self.invalidations = invalidationSubject.eraseToAnyPublisher()
    }

    // MARK: Memory lookup

    /// The decoded bitmap for exactly this request, if memory has it.
    func cachedImage(for request: CoverImageRequest) -> UIImage? {
        memory.object(forKey: request.memoryKey)
    }

    /// What memory knows about `request`, a bitmap or a recent failure, without
    /// touching the disk. Nil means "not loaded yet", not "missing".
    func cachedResult(for request: CoverImageRequest) -> CoverImageResult? {
        if let image = memory.object(forKey: request.memoryKey) { return .image(image) }
        return state.withLock { state in
            self.liveFailure(for: request.source, in: state).map { .unavailable($0) }
        }
    }

    /// The largest decoded size memory holds for `source`, for callers that only need
    /// "what this cover looks like" and can scale, like the open-book transition.
    func largestCachedImage(for source: CoverImageSource) -> UIImage? {
        for size in CoverPixelSize.all.reversed() {
            if let image = memory.object(forKey: CoverImageRequest(source: source, size: size).memoryKey) {
                return image
            }
        }
        return nil
    }

    /// True while a recent load of `source` found it missing or unusable.
    func isKnownUnavailable(_ source: CoverImageSource) -> Bool {
        state.withLock { state in self.liveFailure(for: source, in: state) != nil }
    }

    var counters: CoverPipelineCounters {
        state.withLock { $0.counters }
    }

    /// Keys with work still in flight, network and file alike.
    func inflightKeyCount() async -> Int {
        await inflight.activeKeyCount
    }

    // MARK: Loading

    /// Loads `request` off the main thread: memory first, then a coalesced read and
    /// decode on the bounded executor. Returns `.cancelled` at once if the calling
    /// task is cancelled; other callers waiting for the same load are unaffected.
    func image(
        for request: CoverImageRequest,
        priority: Operation.QueuePriority = .normal
    ) async -> CoverImageResult {
        if let known = recordLookup(request) { return known }
        let version = state.withLock { state -> UInt64 in
            state.counters.misses += 1
            return Self.version(of: request.source, in: state)
        }
        return await inflight.result(
            for: "file|\(request.memoryKey)|v\(version)",
            abandonment: .cancelWork,
            onStart: { self.count { $0.loadsStarted += 1 } },
            onJoin: {
                self.count { $0.coalescedWaiters += 1 }
                self.signposter.emitEvent("CoverCoalesced")
            },
            work: {
                await self.executor.run(
                    priority: priority,
                    onCancelledBeforeStart: { self.count { $0.cancelledBeforeStart += 1 } }
                ) {
                    self.load(request, version: version)
                }
            }
        )
    }

    /// Blocking variant for the few callers that need a cover right now and are not
    /// drawing a scrolling list: Now Playing artwork, the reader's 現代 chrome, the
    /// download Live Activity, the 預設封面 settings grid. Same cache, decoder and
    /// invalidation as `image(for:)`. Never call it from the bookshelf.
    func loadImmediately(_ request: CoverImageRequest) -> CoverImageResult {
        if let known = recordLookup(request) { return known }
        let version = state.withLock { state -> UInt64 in
            state.counters.misses += 1
            return Self.version(of: request.source, in: state)
        }
        return load(request, version: version)
    }

    // MARK: Network covers

    // Network covers share the memory budget and the coalescing, not the versioning:
    // nothing on disk backs them.

    func cachedNetworkImage(forKey key: String) -> UIImage? {
        memory.object(forKey: Self.networkMemoryKey(key))
    }

    func storeNetworkImage(_ image: UIImage, forKey key: String) {
        memory.setObject(image, forKey: Self.networkMemoryKey(key), cost: Self.bitmapCost(of: image))
    }

    func coalescedNetworkLoad(
        key: String,
        _ fetch: @escaping @Sendable () async -> UIImage?
    ) async -> UIImage? {
        let result = await inflight.result(
            for: "network|\(key)",
            abandonment: .finishWork,
            onJoin: { self.signposter.emitEvent("CoverCoalesced") },
            work: {
                guard let image = await fetch() else { return .unavailable(.unreadable) }
                return .image(image)
            }
        )
        return result.image
    }

    // MARK: Invalidation

    /// The files behind `sources` changed: rewritten, replaced or deleted. Drops every
    /// size decoded from them and their failure records, makes any load already
    /// reading them publish nothing, and tells the views showing them to load again.
    func invalidate(_ sources: Set<CoverImageSource>) {
        guard !sources.isEmpty else { return }
        state.withLock { state in
            state.epoch &+= 1
            for source in sources {
                state.sourceEpochs[source] = state.epoch
                state.failures[source] = nil
                for size in CoverPixelSize.all {
                    let key = CoverImageRequest(source: source, size: size).memoryKey
                    self.memory.removeObject(forKey: key)
                    state.defaultCoverKeys.remove(key as String)
                }
            }
        }
        broadcast(.sources(sources))
    }

    /// For writers that only know a URL (iCloud restore): invalidates the book cover
    /// stored there, if that is what the URL is. Path comparison only.
    func invalidateBookCover(at url: URL) {
        let source = CoverImageSource.bookCover(filename: url.lastPathComponent)
        guard io.locate(source).standardizedFileURL.path == url.standardizedFileURL.path else { return }
        invalidate([source])
    }

    /// 快取管理 emptied the downloaded-cover directory. Every downloaded cover is
    /// stale at once, including ones mid-load. The other bitmaps are still valid;
    /// dropping them too is only memory reclaim, and views already showing them keep
    /// the bitmap they hold.
    func invalidateDownloadedBookCovers() {
        state.withLock { state in
            state.epoch &+= 1
            state.downloadedBookCoversEpoch = state.epoch
            state.sourceEpochs = state.sourceEpochs.filter { !$0.key.isDownloadedBookCover }
            state.failures = state.failures.filter { !$0.key.isDownloadedBookCover }
            self.memory.removeAllObjects()
            state.defaultCoverKeys.removeAll()
        }
        broadcast(.downloadedBookCovers)
    }

    /// The 預設封面 library changed.
    func invalidateDefaultCovers() {
        state.withLock { state in
            state.epoch &+= 1
            state.defaultCoversEpoch = state.epoch
            state.sourceEpochs = state.sourceEpochs.filter { !Self.isDefaultCover($0.key) }
            state.failures = state.failures.filter { !Self.isDefaultCover($0.key) }
            for key in state.defaultCoverKeys {
                self.memory.removeObject(forKey: key as NSString)
            }
            state.defaultCoverKeys.removeAll()
        }
        broadcast(.defaultCovers)
    }

    /// Pure memory reclaim: drops every decoded bitmap, changes no version, notifies
    /// no one. A view showing a cover keeps drawing the bitmap it holds.
    func purgeMemory() {
        state.withLock { state in
            self.memory.removeAllObjects()
            state.defaultCoverKeys.removeAll()
        }
    }

    // MARK: - Internals

    private static func networkMemoryKey(_ key: String) -> NSString {
        "network|\(key)" as NSString
    }

    private static func isDefaultCover(_ source: CoverImageSource) -> Bool {
        if case .defaultCover = source { return true }
        return false
    }

    private static func version(of source: CoverImageSource, in state: State) -> UInt64 {
        let own = state.sourceEpochs[source] ?? 0
        switch source {
        case .bookCover:
            return source.isDownloadedBookCover ? max(own, state.downloadedBookCoversEpoch) : own
        case .defaultCover:
            return max(own, state.defaultCoversEpoch)
        case .indexedCover:
            return own
        }
    }

    private func liveFailure(for source: CoverImageSource, in state: State) -> CoverUnavailableReason? {
        guard let record = state.failures[source],
              record.version == Self.version(of: source, in: state),
              now() - record.recordedAt < failureLifetime else { return nil }
        return record.reason
    }

    private func recordLookup(_ request: CoverImageRequest) -> CoverImageResult? {
        guard let known = cachedResult(for: request) else { return nil }
        count { counters in
            if case .image = known {
                counters.memoryHits += 1
            } else {
                counters.negativeHits += 1
            }
        }
        return known
    }

    private func count(_ update: @Sendable (inout CoverPipelineCounters) -> Void) {
        state.withLock { update(&$0.counters) }
    }

    /// Runs on the executor's thread (or the caller's, for `loadImmediately`).
    private func load(_ request: CoverImageRequest, version: UInt64) -> CoverImageResult {
        // Rewritten while this sat in the queue: its bytes would be dropped at
        // publish anyway, so don't read them.
        let isCurrent = state.withLock { Self.version(of: request.source, in: $0) == version }
        guard isCurrent else {
            count { $0.supersededResults += 1 }
            return .superseded
        }

        let kind = request.source.diagnosticKind
        let signpostID = signposter.makeSignpostID()
        let url = io.locate(request.source)

        let readInterval = signposter.beginInterval("CoverRead", id: signpostID, "\(kind, privacy: .public)")
        let readStart = DispatchTime.now().uptimeNanoseconds
        let data: Data
        do {
            data = try io.read(url)
        } catch {
            signposter.endInterval("CoverRead", readInterval)
            let elapsed = DispatchTime.now().uptimeNanoseconds - readStart
            count {
                $0.fileReads += 1
                $0.readNanoseconds += elapsed
            }
            let missing = Self.isMissingFile(error)
            if missing {
                // A legitimate state (after 快取管理, on a restored device): the card
                // falls back. Trace, so a scroll through a cleared shelf cannot crowd
                // real failures out of the diagnostics log.
                AppLogger.cache("⟐ cover file missing", context: ["kind": kind], level: .trace)
            } else {
                AppLogger.cache("⟐ cover file unreadable", error: error, context: ["kind": kind])
            }
            return publish(.unavailable(missing ? .missing : .unreadable), for: request, version: version)
        }
        let readElapsed = DispatchTime.now().uptimeNanoseconds - readStart
        signposter.endInterval("CoverRead", readInterval)

        let decodeInterval = signposter.beginInterval(
            "CoverDecode",
            id: signpostID,
            "\(kind, privacy: .public) \(request.size.longEdge)"
        )
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let image = io.decode(data, request.size)
        let decodeElapsed = DispatchTime.now().uptimeNanoseconds - decodeStart
        signposter.endInterval("CoverDecode", decodeInterval)

        count {
            $0.fileReads += 1
            $0.readNanoseconds += readElapsed
            $0.decodes += 1
            $0.decodeNanoseconds += decodeElapsed
        }
        guard let image else {
            AppLogger.cache(
                "⟐ cover file not decodable",
                context: ["kind": kind, "bytes": data.count],
                level: .warning
            )
            return publish(.unavailable(.undecodable), for: request, version: version)
        }
        return publish(.image(image), for: request, version: version)
    }

    private func publish(
        _ result: CoverImageResult,
        for request: CoverImageRequest,
        version: UInt64
    ) -> CoverImageResult {
        let recordedAt = now()
        let published = state.withLock { state -> CoverImageResult in
            // The version check and the insert happen under the lock `invalidate`
            // takes, so an invalidation lands entirely before this (and the result is
            // dropped) or entirely after it (and removes what this inserted). There
            // is no window between checking and publishing.
            guard Self.version(of: request.source, in: state) == version else {
                state.counters.supersededResults += 1
                return .superseded
            }
            switch result {
            case .image(let image):
                self.memory.setObject(image, forKey: request.memoryKey, cost: Self.bitmapCost(of: image))
                state.failures[request.source] = nil
                if case .defaultCover = request.source {
                    state.defaultCoverKeys.insert(request.memoryKey as String)
                }
            case .unavailable(let reason):
                state.failures[request.source] = FailureRecord(
                    reason: reason,
                    version: version,
                    recordedAt: recordedAt
                )
                if state.failures.count > Self.failureCapacity,
                   let oldest = state.failures.min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key {
                    state.failures[oldest] = nil
                }
            case .superseded, .cancelled:
                break
            }
            return result
        }
        if case .superseded = published {
            signposter.emitEvent("CoverSuperseded")
        }
        logSummaryIfDue()
        return published
    }

    private func broadcast(_ invalidation: CoverInvalidation) {
        let subject = invalidationSubject
        if Thread.isMainThread {
            subject.send(invalidation)
        } else {
            DispatchQueue.main.async { subject.send(invalidation) }
        }
    }

    private func logSummaryIfDue() {
        guard logsSummaries else { return }
        let current = now()
        let summary = state.withLock { state -> CoverPipelineCounters? in
            guard current - state.lastSummaryAt >= 5 else { return nil }
            state.lastSummaryAt = current
            return state.counters
        }
        guard let summary else { return }
        AppLogger.cache(
            "⏱ cover.pipeline hits=\(summary.memoryHits) negative=\(summary.negativeHits)"
            + " misses=\(summary.misses) loads=\(summary.loadsStarted)"
            + " coalesced=\(summary.coalescedWaiters) reads=\(summary.fileReads)"
            + " decodes=\(summary.decodes)"
            + " readMs=\(summary.readNanoseconds / 1_000_000)"
            + " decodeMs=\(summary.decodeNanoseconds / 1_000_000)"
            + " superseded=\(summary.supersededResults)"
            + " cancelledBeforeStart=\(summary.cancelledBeforeStart)"
        )
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError,
           cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    /// What a bitmap holds in memory once decoded, the number the budget counts in.
    /// Not the file size: a 90 KB JPEG decodes to a megabyte.
    static func bitmapCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
