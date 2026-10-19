import CoreText
import UIKit

/// Renders paged-mode pages off the main thread: `CoreTextPageEngine`'s prefetch of
/// the pages around the current one and its chapter-boundary snapshots.
///
/// The worker owns every Core Text layout object it draws with, as the scroll
/// mode's `ReaderFragmentRasterizer` does. The main thread keeps the layout's own
/// framesetter and page frames for live drawing, hit testing, annotations and TTS.
/// Sharing them is not safe even with a frame per render: frames laid out from one
/// framesetter interfere when drawn on two threads at once, and a ruby line can keep
/// a misplaced annotation for good (2026-10-18/19, `CoreTextSharedLayoutConcurrencyTests`;
/// macOS repro: 49 of 1,400 renders wrong with a frame per render from the shared
/// framesetter, 0 with a framesetter of the worker's own).
///
/// The worker's framesetter is built from the layout's attributed string by
/// `CoreTextFramesetterFactory`, the paginator's factory, so its lines are the
/// layout's. Building one costs about 8ms for a horizontal chapter and 120ms for a
/// vertical one (6.7k characters, simulator), once per chapter.
final class CoreTextPagePrerenderer: @unchecked Sendable {
    enum Priority: Int, Comparable {
        /// A page around the current one, which a turn may show next.
        case page
        /// A chapter's first or last page, for cross-chapter animation.
        case chapterBoundary

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Request: Sendable {
        let layout: CoreTextPaginator.ChapterLayout
        let pageIndex: Int
        let size: CGSize
        let backgroundColor: CGColor
        let bars: ReaderPageBars?
    }

    private struct Pending {
        let request: Request
        let priority: Priority
        let completion: @Sendable (UIImage) -> Void
    }

    private let queue = DispatchQueue(label: "com.yuedu.reader.page-prerender", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var draining = false
    /// Worker-owned; touched only on `queue`. The current chapter and its neighbours.
    private var framesetters = CoreTextFramesetterCache(capacity: 3)

    /// Renders on the worker, after every queued request of a higher priority and
    /// those of the same priority queued before it.
    func render(_ request: Request, priority: Priority) async -> UIImage {
        await withCheckedContinuation { continuation in
            let startDrain: Bool = lock.withLock {
                pending.append(Pending(request: request, priority: priority) { continuation.resume(returning: $0) })
                guard !draining else { return false }
                draining = true
                return true
            }
            if startDrain { queue.async { self.drain() } }
        }
    }

    /// Renders on the worker now, ahead of the queue. For tests that race the worker
    /// against the main thread.
    func renderNow(_ request: Request) -> UIImage {
        queue.sync { image(for: request) }
    }

    /// Test evidence: which framesetter the worker lays `text` out with.
    func cachedFramesetterIdentity(for text: NSAttributedString) -> ObjectIdentifier? {
        queue.sync { framesetters.cachedFramesetterIdentity(for: text) }
    }

    /// Drops the worker's framesetters (memory warning). Later requests rebuild them.
    func purgeCaches() {
        queue.async { self.framesetters.removeAll() }
    }

    private func drain() {
        while let next = takeNext() {
            next.completion(image(for: next.request))
        }
    }

    private func takeNext() -> Pending? {
        lock.withLock {
            guard let index = pending.indices.min(by: { pending[$0].priority < pending[$1].priority }) else {
                draining = false
                return nil
            }
            return pending.remove(at: index)
        }
    }

    private func image(for request: Request) -> UIImage {
        let layout = request.layout
        let frame = CoreTextPageView.makePageFrame(
            layout: layout,
            pageIndex: request.pageIndex,
            framesetter: framesetters.framesetter(for: layout.attributedString)
        )
        return CoreTextPageEngine.renderImage(
            layout: layout,
            pageIndex: request.pageIndex,
            size: request.size,
            bgColor: request.backgroundColor,
            bars: request.bars,
            frameSource: .own(frame)
        )
    }
}
