@testable import YueduCoreText
import Foundation
import os
import Testing
import UIKit
@testable import yuedu_app

/// A chapter's 段評 bubbles are drawn while it renders, and it renders off the main thread:
/// `NodeAttributedStringRenderer.render` is nonisolated async, which in the app target runs on
/// the global executor even when awaited from the main actor. `NonisolatedNonsendingByDefault`
/// (approachable concurrency, already on for the test targets) would run it on the caller's
/// actor instead, and every bubble of a chapter opened from the UI would be drawn on the main
/// thread with no diagnostic; the renderer's entry points would then need `@concurrent`.
/// Measured 2026-10-25: 0 of ~900 main-thread samples in a bubble span over 150 bubbles.
@Suite("Comment bubble render thread", .serialized)
@MainActor
struct CommentBubbleRenderThreadTests {

    /// Reads, from its own thread, the main thread's open `SourcePerfTrace` spans
    /// (`MainThreadActivity`), counting the samples taken inside a bubble span.
    final class MainBubbleSpanSampler: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (samples: 0, inBubble: 0, stop: false))
        private let finished = DispatchSemaphore(value: 0)

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    let inBubble = MainThreadActivity.snapshot().contains { $0.hasPrefix("commentBubble.") }
                    let stop = state.withLock { state -> Bool in
                        state.samples += 1
                        if inBubble { state.inBubble += 1 }
                        return state.stop
                    }
                    if stop { break }
                    usleep(100)
                }
                finished.signal()
            }
        }

        func stop() -> (samples: Int, inBubble: Int) {
            state.withLock { $0.stop = true }
            finished.wait()
            return state.withLock { ($0.samples, $0.inBubble) }
        }
    }

    nonisolated private static let paragraphCount = 150
    nonisolated private static let prose = String(repeating: "風穿過山林，江水映著月光，行人仍沿著古道前進。", count: 5)

    @Test("the sampler sees a bubble drawn on the main thread")
    func samplerSeesMainThreadBubble() throws {
        let bubble = try #require(CommentBubbleSVGRecognizer.recognize(src: "svg:", svgContent: Self.bubbleSVG(count: 7, run: UUID())))
        let sampler = MainBubbleSpanSampler()
        sampler.start()
        let start = SourcePerfTrace.now
        while SourcePerfTrace.now - start < 0.05 {
            _ = CommentBubbleSVGRecognizer.draw(svg: bubble, pointSize: 22, themeTextColor: .black)
        }
        let sampled = sampler.stop()
        #expect(sampled.inBubble > 0, "\(sampled.samples) samples")
    }

    @Test("a chapter rendered from the main actor draws its bubbles off the main thread")
    func chapterBubblesDrawOffMain() async throws {
        let global = GlobalSettings.shared
        let savedFollow = global.commentBubbleFollowsSourceSVG
        defer { global.commentBubbleFollowsSourceSVG = savedFollow }
        // Follow the source, so every paragraph parses and draws its own SVG.
        global.commentBubbleFollowsSourceSVG = true

        let nodes = Self.chapter(run: UUID())
        let renderer = NodeAttributedStringRenderer(config: .init(from: Self.renderSettings, textColor: .black, renderWidth: 360))
        let metrics = RenderLeafMetrics()
        let sampler = MainBubbleSpanSampler()
        sampler.start()
        _ = await ReaderDocumentTrace.$renderLeaves.withValue(metrics) { await renderer.render(nodes) }
        let sampled = sampler.stop()

        #expect(metrics.callCount("bubbleDraw") == Self.paragraphCount)
        #expect(sampled.samples > 0)
        #expect(sampled.inBubble == 0, "\(sampled.inBubble) of \(sampled.samples) main-thread samples were inside a bubble span")
    }

    /// 起點's bubble shape, unique per test run so no parsed template or drawn image is reused.
    nonisolated private static func chapter(run: UUID) -> [RenderableNode] {
        (0..<paragraphCount).map { index in
            var style = RenderStyle.none
            style.isTextSizedImage = true
            let svg = bubbleSVG(count: index + 1, run: run)
            return .paragraph([
                .text(prose),
                .anchor(href: "https://example.com/review/\(index)", children: [
                    .image(src: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString(),
                           alt: String(index + 1), style: style)
                ])
            ], style: .body)
        }
    }

    nonisolated private static func bubbleSVG(count: Int, run: UUID) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" data-run=\"\(run.uuidString)\" width=\"200\" height=\"150\" viewBox=\"0 0 1300 1280\">"
            + "<g transform=\"rotate(180 650 640) scale(-1 1) translate(-1300 0)\">"
            + "<path d=\"M1210 640C1210 900 960 1070 650 1070S90 900 90 640 340 210 650 210 1210 380 1210 640ZM760 1060l-110 160-110-160Z\" fill=\"#B3B3B3\"/></g>"
            + "<text x=\"650\" y=\"760\" font-size=\"420\" text-anchor=\"middle\" fill=\"#FFFFFF\">\(count)</text></svg>"
    }

    nonisolated private static var renderSettings: ReaderRenderSettings {
        ReaderRenderSettings(theme: "test", textColor: .black, backgroundColor: .white,
                             fontSize: 22, lineHeightMultiple: 1.4, lineSpacing: 0,
                             paragraphSpacing: 6, letterSpacing: 0, marginH: 0, marginV: 0,
                             footerHeight: 0, contentInsets: .zero, writingMode: .horizontal)
    }
}
