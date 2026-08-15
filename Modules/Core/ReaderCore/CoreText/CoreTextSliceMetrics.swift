import Foundation

/// Per-call cost breakdown of one `CoreTextChunkSlicer.slice()`.
///
/// Stage 0 of the viewport lazy-layout migration (`Technotes/ViewportScrollArchitecture.md`).
/// That migration has exactly one success criterion — chapter load time must decouple from
/// chapter length — and it can only be argued from numbers. A single wall-clock total is not
/// enough: the refactor's whole premise is that we currently pay `SuggestFrameSize` and
/// `CreateFrame` for text nobody is looking at, so the baseline has to attribute the time to
/// each CoreText operation class separately.
///
/// Accumulators are locals of a single `slice()` call, threaded through by `inout`. Chapters
/// slice concurrently on detached tasks, so a shared/global counter would both race and blend
/// chapters together.
struct CoreTextSliceMetrics: Sendable {

    /// UTF-16 length of the chapter handed to the slicer — the x-axis of "cost vs chapter length".
    var characterCount: Int = 0
    /// Chunks the slicer produced.
    var chunkCount: Int = 0

    /// `CTFramesetterCreateWithAttributedString` (via `CoreTextFramesetterFactory`).
    var framesetterSeconds: Double = 0

    /// `CTFramesetterSuggestFrameSizeWithConstraints`. Not a cheap estimate — it line-breaks —
    /// which is exactly why §3.1 of the technote counts up to 4 of these per chunk.
    var suggestFrameSizeSeconds: Double = 0
    var suggestFrameSizeCalls: Int = 0

    /// `CTFramesetterCreateFrame` (via `CoreTextPaginator.makeFrame`), including the probe
    /// frames built for float notches, `visibleStringRange` correction, and vertical compaction.
    var createFrameSeconds: Double = 0
    var createFrameCalls: Int = 0

    /// `extractBlockRenderables` + `extractInlineAnnotations` — the per-line walk over a built frame.
    var extractSeconds: Double = 0
    var extractCalls: Int = 0

    /// `CoreTextChunk.init`, whose cost is the eager `CoreTextChunkAttachmentExtractor.extract`
    /// it performs whenever it is handed a frame.
    var chunkInitSeconds: Double = 0
    var chunkInitCalls: Int = 0

    /// Wall time of the whole `slice()` call. Always ≥ the sum of the buckets above; the
    /// remainder is the slicer's own bookkeeping (paragraph-boundary scan, attribute
    /// enumeration for block/float image heights).
    var totalSeconds: Double = 0

    /// Bucketed time that is attributed to a named CoreText operation.
    var attributedSeconds: Double {
        framesetterSeconds + suggestFrameSizeSeconds + createFrameSeconds
            + extractSeconds + chunkInitSeconds
    }

    // MARK: - Measurement

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    mutating func recordFramesetter(since start: TimeInterval) {
        framesetterSeconds += Self.now - start
    }

    mutating func measuringSuggestFrameSize<T>(_ body: () -> T) -> T {
        let start = Self.now
        let value = body()
        suggestFrameSizeSeconds += Self.now - start
        suggestFrameSizeCalls += 1
        return value
    }

    mutating func measuringCreateFrame<T>(_ body: () -> T) -> T {
        let start = Self.now
        let value = body()
        createFrameSeconds += Self.now - start
        createFrameCalls += 1
        return value
    }

    mutating func measuringExtract<T>(_ body: () -> T) -> T {
        let start = Self.now
        let value = body()
        extractSeconds += Self.now - start
        extractCalls += 1
        return value
    }

    mutating func measuringChunkInit<T>(_ body: () -> T) -> T {
        let start = Self.now
        let value = body()
        chunkInitSeconds += Self.now - start
        chunkInitCalls += 1
        return value
    }

    // MARK: - Reporting

    /// Deterministic, content-free detail for the `⏱` line. Carries no book text or title —
    /// only counts and durations.
    var logDetail: String {
        [
            "chars=\(characterCount)",
            "chunks=\(chunkCount)",
            "framesetter=\(Self.ms(framesetterSeconds))",
            "suggest=\(Self.ms(suggestFrameSizeSeconds))/\(suggestFrameSizeCalls)",
            "frame=\(Self.ms(createFrameSeconds))/\(createFrameCalls)",
            "extract=\(Self.ms(extractSeconds))/\(extractCalls)",
            "attach=\(Self.ms(chunkInitSeconds))/\(chunkInitCalls)",
            "other=\(Self.ms(max(0, totalSeconds - attributedSeconds)))",
            "perKChar=\(String(format: "%.2fms", millisecondsPerKilocharacter))",
        ].joined(separator: " ")
    }

    /// Cost per 1000 UTF-16 units — the number that decides the migration. Today it should
    /// stay roughly flat as chapters get longer (cost is linear in length); once layout is
    /// viewport-driven it should fall as chapters get longer, because a long chapter pays for
    /// the same one viewport a short one does.
    var millisecondsPerKilocharacter: Double {
        guard characterCount > 0 else { return 0 }
        return totalSeconds * 1000 / (Double(characterCount) / 1000)
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1fms", seconds * 1000)
    }
}
