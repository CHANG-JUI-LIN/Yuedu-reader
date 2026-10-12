import CoreText
import os
import UIKit
import YueduCoreText

/// Paints continuous-scroll fragments into bitmaps off the main thread, for both
/// layout backends: CoreText chunks (TXT, online books, EPUB chapters on the
/// legacy engine) and the browser engine's paint fragments (EPUB).
///
/// 12.trace (2026-09-21, TXT, iPhone 16 Pro Max): 36 of the 38 reading hitches
/// were frames in which the main thread painted a fragment, mostly on an
/// efficiency core; of 5,434 frames without paint only 2 hitched. 13.trace, the
/// same reading with CoreText fragments painted here: all 5,888 paints ran off
/// the main thread and 2 reading hitches were left, both SwiftUI updates. The
/// main thread therefore only decides which fragments it wants and installs
/// finished bitmaps. A visible fragment whose bitmap has not arrived shows the
/// reader background — the chosen trade-off is that a scroll frame never waits
/// for paint, not even when opening or jumping.
///
/// The worker owns every Core Text layout object it draws with. They are used by
/// one thread at a time, and the main thread keeps its own for hit testing,
/// selection and paint bounds:
/// - CoreText: frames from the chunk's own recipe (`makeFrame(using:)`) and the
///   slicer's framesetter factory, so line breaks are identical.
/// - Browser: lines rebuilt from each run's immutable drawing text
///   (`displayListWithOwnTextLines()`), so glyphs are identical.
final class ReaderFragmentRasterizer: @unchecked Sendable {
    /// Identifies one request. The host cancels it when the fragment leaves the
    /// paint window or its surface is evicted; priority is its distance from the
    /// viewport, refreshed on every host update.
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var distance: CGFloat = 0
        var isCancelled: Bool { lock.withLock { cancelled } }
        var priority: CGFloat {
            get { lock.withLock { distance } }
            set { lock.withLock { distance = newValue } }
        }
        func cancel() { lock.withLock { cancelled = true } }
    }

    struct CoreTextContent {
        /// Only immutable `let` properties are read off the main thread.
        let chunk: CoreTextChunk
        /// Main-thread snapshot. `frame` is nil: the worker builds its own.
        let content: CoreTextChunkPainter.Content
        let lineIndices: IndexSet
        let underline: ReaderTextUnderlineDecoration?
        let part: Int
    }

    struct BrowserContent {
        /// Immutable; its display list is local to `renderingRect`.
        let fragment: BrowserPaintFragment
        let skipBackground: Bool
        let spine: Int
        /// Highlight line boxes in document space; the fragment holds only part of a line.
        let highlightSpans: HighlightLineSpans
    }

    enum Content {
        case coreText(CoreTextContent)
        case browser(BrowserContent)
    }

    struct Job {
        let ticket: Ticket
        /// The painted area in the fragment owner's coordinates: the chunk for
        /// CoreText, the fragment's own display list space for browser content.
        let renderingRect: CGRect
        let format: UIGraphicsImageRendererFormat
        let content: Content
    }

    private struct Pending {
        let job: Job
        let completion: @Sendable (CGImage?) -> Void
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "YueduReader", category: "ReaderPerformance")
    private let queue = DispatchQueue(label: "com.yuedu.reader.fragment-raster", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var draining = false
    private var mainThreadRenders = 0
    /// Worker-owned; touched only on `queue`. Small, most-recent-last.
    private var framesetters = CoreTextFramesetterCache(capacity: 3)
    private var frames: [(chunk: CoreTextChunk, frame: CTFrame)] = []

    /// Evidence for tests: paint must never run on the main thread.
    var mainThreadRenderCount: Int { lock.withLock { mainThreadRenders } }

    /// `completion` is called exactly once per job on the main queue — with
    /// `nil` when the job was cancelled before it started.
    func submit(_ job: Job, completion: @escaping @Sendable (CGImage?) -> Void) {
        let startDrain: Bool = lock.withLock {
            pending.append(Pending(job: job, completion: completion))
            guard !draining else { return false }
            draining = true
            return true
        }
        if startDrain { queue.async { self.drain() } }
    }

    /// Drops the worker's frame caches (memory warning). Queued jobs rebuild on demand.
    func purgeCaches() {
        queue.async {
            self.framesetters.removeAll()
            self.frames.removeAll()
        }
    }

    private func drain() {
        while let next = takeNext() {
            let image = next.job.ticket.isCancelled ? nil : render(next.job)
            let completion = next.completion
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Cancelled jobs first (they cost nothing), then nearest to the viewport.
    private func takeNext() -> Pending? {
        lock.withLock {
            guard !pending.isEmpty else {
                draining = false
                return nil
            }
            let index = pending.indices.min { a, b in
                let ca = pending[a].job.ticket.isCancelled, cb = pending[b].job.ticket.isCancelled
                if ca != cb { return ca }
                return pending[a].job.ticket.priority < pending[b].job.ticket.priority
            }!
            return pending.remove(at: index)
        }
    }

    private func render(_ job: Job) -> CGImage? {
        if Thread.isMainThread { lock.withLock { mainThreadRenders += 1 } }
        let renderer = UIGraphicsImageRenderer(size: job.renderingRect.size, format: job.format)
        switch job.content {
        case .coreText(let text):
            let interval = Self.signposter.beginInterval("render.coreTextFragment",
                "spine=\(text.chunk.chapterIndex) offset=\(text.chunk.charRange.location) part=\(text.part) lines=\(text.lineIndices.count)")
            defer { Self.signposter.endInterval("render.coreTextFragment", interval) }
            var content = text.content
            if !content.isImageOnly { content.frame = frame(for: text.chunk) }
            let bounds = CGRect(x: 0, y: 0, width: text.chunk.width, height: text.chunk.height)
            return renderer.image { context in
                context.cgContext.translateBy(x: -job.renderingRect.minX, y: -job.renderingRect.minY)
                CoreTextChunkPainter.paint(content, bounds: bounds, lineIndices: text.lineIndices,
                                           underline: text.underline, in: context.cgContext)
            }.cgImage
        case .browser(let browser):
            let id = browser.fragment.id
            let interval = Self.signposter.beginInterval("render.browserFragment",
                "spine=\(browser.spine) node=\(id.node) offset=\(id.sourceOffset) kind=\(id.kind) part=\(id.part)")
            defer { Self.signposter.endInterval("render.browserFragment", interval) }
            let list = browser.fragment.displayListWithOwnTextLines()
            return renderer.image { context in
                ReaderDisplayListDrawer.draw(list, in: context.cgContext,
                    skipAuthoredBackgroundPaint: browser.skipBackground,
                    textPaintPhase: browser.fragment.textPaintPhase,
                    highlightSpans: browser.highlightSpans,
                    origin: browser.fragment.renderingRect.origin)
            }.cgImage
        }
    }

    private func frame(for chunk: CoreTextChunk) -> CTFrame {
        if let index = frames.firstIndex(where: { $0.chunk === chunk }) {
            let hit = frames.remove(at: index)
            frames.append(hit)
            return hit.frame
        }
        let frame = chunk.makeFrame(using: framesetters.framesetter(for: chunk.attributedString))
        frames.append((chunk, frame))
        if frames.count > 8 { frames.removeFirst() }
        return frame
    }
}
