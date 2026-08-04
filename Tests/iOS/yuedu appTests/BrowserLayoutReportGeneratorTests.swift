import Testing
import UIKit
@testable import yuedu_app

/// Generates the Phase 1.5 report artifacts (snapshots, fragment dumps,
/// per-stage timings, peak memory) into `docs/browser-layout/phase1.5-report/`.
/// Run manually; the outputs are committed for review.
struct BrowserLayoutReportGeneratorTests {

    @Test func generateReport() async throws {
        // #filePath = <root>/Tests/iOS/yuedu appTests/BrowserLayoutReportGeneratorTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // yuedu appTests
            .deletingLastPathComponent()   // iOS
            .deletingLastPathComponent()   // Tests
        let dir = root.appendingPathComponent("docs/browser-layout/phase1.5-report", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let css = """
        body { margin: 0; }
        .outer { width: 80%; margin: 20px auto; padding: 12px; border: 2px solid; background-color: #f0f0f0; }
        .inner { width: 50%; margin-left: auto; padding: 8px; border-left: 4px solid #cc0000; }
        .inner p { margin: 0; font-size: 14px; }
        """
        let html = """
        <html><head><style>\(css)</style></head><body>
        <div class="outer"><div class="inner"><p>The box model, computed naturally.</p></div></div>
        <p>Second paragraph with <a href="http://example.com/x">a link</a> inside.</p>
        </body></html>
        """
        let config = BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 400, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let (pages, metrics) = try await doc.renderPagesAndMeasure(containerSize: CGSize(width: 300, height: 400))

        // 1. Fragment tree dump
        try doc.dumpFragments(pages).write(
            to: dir.appendingPathComponent("fragment-dump.txt"), atomically: true, encoding: .utf8
        )
        // 2. Source text
        try doc.lastSourceText.write(
            to: dir.appendingPathComponent("source-text.txt"), atomically: true, encoding: .utf8
        )
        // 3. Snapshot image
        let list = DisplayListBuilder.build(for: pages[0], sourceText: doc.lastSourceText)
        let image = DisplayListRenderer.render(list, size: CGSize(width: 300, height: 400))
        try image.pngData()?.write(to: dir.appendingPathComponent("page-0.png"))

        // 4. Metrics + parity summary
        let parity = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        let ordered = BrowserLayoutTestSupport.rangesAreOrdered(pages)
        var report: [String] = ["# Browser Layout Phase 1.5 Report", ""]
        report.append("## Per-stage timing (seconds)")
        for stage in ["cssCollect", "cssParse", "styleTree", "boxTree", "layout", "fragment"] {
            report.append("- \(stage): \(String(format: "%.4f", metrics.stages[stage] ?? 0))")
        }
        report.append("- total: \(String(format: "%.4f", metrics.total))")
        report.append("- peak footprint delta: \(metrics.peakFootprintDelta) bytes")
        report.append("")
        report.append("## Source-range parity")
        report.append("- ranges ordered (no loss/dup/reorder): \(ordered)")
        report.append("- visible text (\(parity.count) chars): \(parity.debugDescription)")
        report.append("")
        report.append("## Pages: \(pages.count)")
        for page in pages {
            report.append("- page[\(page.index)] rect=\(page.pageRect) fragments=\(page.fragments.count)")
        }
        try report.joined(separator: "\n").write(
            to: dir.appendingPathComponent("metrics.md"), atomically: true, encoding: .utf8
        )

        // Print for the session summary.
        print("REPORT-METRICS \(metrics)")
        print("REPORT-PARITY ordered=\(ordered) visible=\(parity.debugDescription) pages=\(pages.count)")
        #expect(ordered)
    }
}
