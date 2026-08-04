import Testing
import UIKit
@testable import yuedu_app

/// Phase 2B measurement: ContinuousClock-based stage timing, 10 runs per
/// scenario with median/p95 — no integer-ms zeros.
@MainActor
struct BrowserLayoutMeasurementTests {

    struct StageTimings {
        var stages: [String: [Duration]] = [:]
        mutating func append(_ name: String, _ duration: Duration) {
            stages[name, default: []].append(duration)
        }
    }

    @Test func tenRunsMedianP95PerStage() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)
        let html = "<html><head><style>p { margin: 0 0 1em 0; line-height: 1.4 }</style></head><body>\(text)</body></html>"
        let config = BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 400, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )

        var timings = StageTimings()
        let runs = 10
        for _ in 0..<runs {
            let document = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
            let clock = ContinuousClock()
            let start = clock.now
            // Pipeline (parse + cascade + box-tree) — measured as one span;
            // finer stage splits live in LayoutMetrics (renderPagesAndMeasure).
            _ = try document.makeLayout(containerSize: CGSize(width: 300, height: 400))
            timings.append("pipeline", start.duration(to: clock.now))

            let session = BrowserLayoutSession(
                html: html, cssTexts: [], config: config,
                imageLoader: { _ in nil }, generation: 0
            )
            let firstStart = clock.now
            let first = try await session.layoutNextPage()
            timings.append("firstPagePublish", firstStart.duration(to: clock.now))
            #expect(first != nil)

            let fullStart = clock.now
            try await session.finish()
            timings.append("remainingPages", fullStart.duration(to: clock.now))
        }

        // Report median/p95 per stage (microseconds).
        var report: [String] = []
        for stage in ["pipeline", "firstPagePublish", "remainingPages"] {
            let durations = timings.stages[stage] ?? []
            let micros = durations.map { Double($0.components.attoseconds) / 1e12 }  // µs
            let sorted = micros.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            report.append("\(stage): median \(Int(median))µs, p95 \(Int(p95))µs, runs \(sorted.count)")
            // No integer-ms zero: report in µs, and the medians must be > 0.
            #expect(median > 0)
            #expect(p95 >= median)
        }
        try report.joined(separator: "\n").write(
            toFile: "/tmp/measurement-report.txt", atomically: true, encoding: .utf8
        )
        print("MEASUREMENT\n\(report.joined(separator: "\n"))")
    }

    @Test func layoutMetricsReportSubMillisecondStages() async throws {
        // A small chapter: stage timings must NOT collapse to 0ms integers.
        let html = "<html><body><p>Small paragraph.</p></body></html>"
        let config = BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 400, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        let document = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let (_, metrics) = try await document.renderPagesAndMeasure(containerSize: CGSize(width: 300, height: 400))
        // The fragment stage on a tiny chapter is sub-ms; reported as Double
        // seconds (no integer truncation).
        #expect((metrics.stages["fragment"] ?? -1) >= 0)
        #expect(metrics.total > 0)
        #expect(metrics.peakFootprintDelta >= 0)
    }
}
