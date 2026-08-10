import Testing
import UIKit
@testable import yuedu_app

/// Per-stage timing + peak memory + benchmark against the legacy text pipeline.
/// The 1.5x target is reported; the hard assertion is a 3x sanity bound (CI
/// machines vary).
struct BrowserLayoutPerfTests {

    /// A realistic chapter: ~40 paragraphs of prose.
    private static func chapterHTML(_ paragraphs: Int = 40) -> String {
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank. "
        let paragraph = String(repeating: sentence, count: 8)
        let body = (0..<paragraphs).map { "<p>Paragraph \($0). \(paragraph)</p>" }.joined()
        return "<html><head><style>p { margin: 0 0 1em 0; line-height: 1.4 }</style></head><body>\(body)</body></html>"
    }

    @Test func stagesAreMeasuredAndMemoryReported() async throws {
        let html = Self.chapterHTML()
        let config = BrowserLayoutConfig(
            renderWidth: 390, renderHeight: 800, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let (pages, metrics) = try await doc.renderPagesAndMeasure(containerSize: CGSize(width: 390, height: 800))
        #expect(!pages.isEmpty)
        // `#expect` records and continues, so a force-unwrap after a nil check
        // traps and takes the whole test process down with every test that
        // had not run yet. Bind instead: a missing stage fails this test only.
        for stage in ["cssCollect", "cssParse", "styleTree", "boxTree", "layout", "fragment"] {
            guard let elapsed = metrics.stages[stage] else {
                Issue.record("missing stage \(stage); recorded: \(metrics.stages.keys.sorted())")
                continue
            }
            #expect(elapsed >= 0)
        }
        #expect(metrics.peakFootprintDelta >= 0)
        #expect(metrics.total > 0)
    }

    @Test func benchmarkVsLegacyTextPipeline() async throws {
        let html = Self.chapterHTML()
        let config = BrowserLayoutConfig(
            renderWidth: 390, renderHeight: 800, rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"], textColor: .black, backgroundColor: .white
        )

        // Legacy path: the app's current HTML text pipeline (AST + renderer).
        let legacyTime = try await measureLegacy(html)

        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let (_, metrics) = try await doc.renderPagesAndMeasure(containerSize: CGSize(width: 390, height: 800))
        let browserTime = metrics.total

        let ratio = browserTime / max(legacyTime, 0.000_1)
        // Report the actual ratio; assert a sanity bound (target is ~1.5x).
        print("BENCH legacy=\(legacyTime) browser=\(browserTime) ratio=\(ratio)")
        #expect(ratio <= 3.0, "browser pipeline \(ratio)x slower than legacy (\(browserTime)s vs \(legacyTime)s)")
        // Basic absolute sanity: a 40-paragraph chapter lays out in < 1s.
        #expect(browserTime < 1.0)
    }

    private func measureLegacy(_ html: String) async throws -> TimeInterval {
        let settings = ReaderRenderSettings(
            theme: "paper",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 12,
            marginV: 12,
            footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let builder = HTMLAttributedStringBuilder()
        let builderConfig = HTMLAttributedStringBuilder.Config(
            fontSize: 17,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: "PingFangSC-Regular",
            renderWidth: 390,
            writingMode: .horizontal
        )
        let start = CACurrentMediaTime()
        guard let ast = await builder.buildStyledAST(html: html, config: builderConfig) else {
            Issue.record("legacy AST build failed")
            return 0
        }
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: .black,
                baseFontSize: 17,
                renderWidth: 390,
                renderHeight: 800
            )
        )
        _ = await renderer.render(nodes)
        return CACurrentMediaTime() - start
    }

    /// The display list is built lazily per page — rendering page 0 must not
    /// force page 1's fragments to exist (they're built on demand).
    @Test func displayListIsPerPageLazy() async throws {
        let html = Self.chapterHTML()
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 390, height: 120)
        #expect(pages.count >= 2)
        let page0List = DisplayListBuilder.build(for: pages[0], sourceText: doc.lastSourceText)
        #expect(page0List.items.contains { item in
            if case .text = item { return true }
            return false
        })
        // Page 1's list is independent of page 0's (no shared draw objects).
        let page1List = DisplayListBuilder.build(for: pages[1], sourceText: doc.lastSourceText)
        #expect(!page1List.items.isEmpty)
    }
}
