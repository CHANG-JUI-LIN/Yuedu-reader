import CoreText
import Foundation
import YueduCoreTextTypography

/// Framesetters owned by exactly one executor.
///
/// A chapter's chunks share one `CoreTextChapterFramesetter`, and once slicing hands the chunks
/// over, the main thread owns it: materialization, hit testing and selection all
/// lay out with it. Core Text layout objects (CTFramesetter, CTTypesetter, CTFrame,
/// CTLine, CTRun) are used by one operation, queue or thread at a time, so an
/// executor that builds chunk frames off the main thread keeps its own instance of
/// this cache and never touches `CoreTextChunk.framesetter`.
///
/// Framesetters come from the slicer's factory (same typesetter options), and
/// frames from `CoreTextChunk.makeFrame(using:)`, so lines break identically.
/// Measured 2026-09-21 (simulator, ABBA): creating one costs 1.2 ms for a
/// 3.4k-character TXT chapter and 3.6 ms for a styled one, once per chapter; the
/// frames it builds cost the same as the shared framesetter's. Serializing the
/// shared framesetter instead would make the main thread wait up to one frame
/// build (1.7 ms median there, far more on an efficiency core).
///
/// Not thread-safe by design: confine an instance to its executor.
struct CoreTextFramesetterCache {
    private var entries: [(text: NSAttributedString, framesetter: CoreTextChapterFramesetter)] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Most recently used last. Keyed by the chapter string's identity; the entry
    /// keeps the string alive, so the identity cannot be reused while cached.
    mutating func framesetter(for text: NSAttributedString) -> CoreTextChapterFramesetter {
        if let index = entries.firstIndex(where: { $0.text === text }) {
            let hit = entries.remove(at: index)
            entries.append(hit)
            return hit.framesetter
        }
        let framesetter = SourcePerfTrace.span("coreText.scroll.executorFramesetter", "chars=\(text.length)") {
            CoreTextChapterFramesetter(text)
        }
        entries.append((text, framesetter))
        if entries.count > capacity { entries.removeFirst() }
        return framesetter
    }

    /// Test evidence: which framesetter this executor lays `text` out with.
    func cachedFramesetterIdentity(for text: NSAttributedString) -> ObjectIdentifier? {
        entries.first { $0.text === text }.map { ObjectIdentifier($0.framesetter) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// Builds chunk frames off the main thread for `CoreTextScrollEngine.warmChunksAhead`,
/// one at a time, with framesetters only this actor uses. Results are applied on the
/// main thread through `CoreTextChunk.applyBuiltFrame`.
actor CoreTextFrameWarmer {
    private var framesetters = CoreTextFramesetterCache(capacity: 3)

    func buildFrameData(for chunk: CoreTextChunk) -> CoreTextChunk.BuiltFrame? {
        chunk.buildFrameData(using: framesetters.framesetter(for: chunk.attributedString))
    }

    /// Test evidence: the framesetter this actor lays `text` out with, if cached.
    func framesetterIdentity(for text: NSAttributedString) -> ObjectIdentifier? {
        framesetters.cachedFramesetterIdentity(for: text)
    }
}
