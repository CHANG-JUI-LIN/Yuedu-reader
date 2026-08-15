import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// Stage 0 of `Technotes/ViewportScrollArchitecture.md`: the slicer must report a cost
/// breakdown that actually adds up, because every later stage is argued from these numbers.
/// A miswired accumulator (a call site left unmeasured, an accumulator reset between chunks,
/// double counting) produces plausible-looking milliseconds, so the accounting is asserted
/// rather than eyeballed in the Console.
@Suite("CoreText slice metrics", .serialized)
struct CoreTextSliceMetricsTests {

    /// Multi-paragraph body long enough that the slicer produces more than one chunk at the
    /// caps used below, so per-chunk accumulation is exercised rather than a single pass.
    private static func body(paragraphs: Int) -> NSAttributedString {
        let attr = NSMutableAttributedString()
        for index in 0..<paragraphs {
            attr.append(NSAttributedString(
                string: "Paragraph \(index) carries enough words to wrap across several lines "
                    + "so the slicer has real line breaking to perform.\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.black,
                ]
            ))
        }
        return attr
    }

    @Test("horizontal slicing attributes its cost to every CoreText operation class")
    func horizontalSlicingAttributesCost() throws {
        let attr = Self.body(paragraphs: 60)

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 220,
            heightCap: 240
        )
        let metrics = output.metrics

        try #require(output.chunks.count > 1)
        #expect(metrics.characterCount == attr.length)
        #expect(metrics.chunkCount == output.chunks.count)

        // Every chunk costs at least one measurement, one frame, one extraction and one init.
        // Anything less means a call site is not being counted.
        #expect(metrics.suggestFrameSizeCalls >= output.chunks.count)
        #expect(metrics.createFrameCalls >= output.chunks.count)
        #expect(metrics.extractCalls >= output.chunks.count)
        #expect(metrics.chunkInitCalls == output.chunks.count)

        #expect(metrics.framesetterSeconds > 0)
        #expect(metrics.suggestFrameSizeSeconds > 0)
        #expect(metrics.createFrameSeconds > 0)
        #expect(metrics.totalSeconds > 0)

        // Buckets are disjoint slices of one wall clock, so their sum can never exceed it.
        // A nested measurement (measuring a frame build inside an extract, say) would break this.
        #expect(metrics.attributedSeconds <= metrics.totalSeconds)
    }

    @Test("vertical slicing reports the probe frame it builds for every chunk")
    func verticalSlicingReportsProbeFrames() throws {
        let attr = Self.body(paragraphs: 60)

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 320,
            heightCap: 240,
            writingMode: .verticalRTL
        )
        let metrics = output.metrics

        try #require(output.chunks.count > 1)
        #expect(metrics.chunkCount == output.chunks.count)
        // vertical builds a probe frame and then the real frame for each chunk
        #expect(metrics.createFrameCalls >= output.chunks.count * 2)
        // ...and extracts inline annotations as well as block renderables
        #expect(metrics.extractCalls >= output.chunks.count * 2)
        #expect(metrics.chunkInitCalls == output.chunks.count)
        #expect(metrics.attributedSeconds <= metrics.totalSeconds)
    }

    @Test("an empty chapter reports zero layout work instead of stale counters")
    func emptyChapterReportsNoLayoutWork() {
        let output = CoreTextChunkSlicer.slice(
            attributedString: NSAttributedString(string: ""),
            chapterIndex: 0,
            contentWidth: 220
        )
        let metrics = output.metrics

        #expect(output.chunks.isEmpty)
        #expect(metrics.characterCount == 0)
        #expect(metrics.chunkCount == 0)
        #expect(metrics.suggestFrameSizeCalls == 0)
        #expect(metrics.createFrameCalls == 0)
        #expect(metrics.millisecondsPerKilocharacter == 0)
    }

    @Test("log detail keeps a deterministic content-free schema")
    func logDetailKeepsDeterministicSchema() {
        var metrics = CoreTextSliceMetrics()
        metrics.characterCount = 20_000
        metrics.chunkCount = 4
        metrics.framesetterSeconds = 0.003
        metrics.suggestFrameSizeSeconds = 0.248
        metrics.suggestFrameSizeCalls = 9
        metrics.createFrameSeconds = 0.121
        metrics.createFrameCalls = 5
        metrics.extractSeconds = 0.029
        metrics.extractCalls = 4
        metrics.chunkInitSeconds = 0.008
        metrics.chunkInitCalls = 4
        metrics.totalSeconds = 0.42

        #expect(
            metrics.logDetail
                == "chars=20000 chunks=4 framesetter=3.0ms suggest=248.0ms/9 frame=121.0ms/5 "
                    + "extract=29.0ms/4 attach=8.0ms/4 other=11.0ms perKChar=21.00ms"
        )
    }
}
