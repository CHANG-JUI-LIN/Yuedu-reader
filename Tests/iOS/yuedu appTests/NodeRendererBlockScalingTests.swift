@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// Crashlytics 7fa0d0f7: an online chapter whose body is one `<div>` holding thousands of `<p>`
/// spent 90 s of main-thread CPU in `renderBlock`. Its child loop asked
/// `result.string.hasSuffix("\n")` before every block child, and `NSMutableAttributedString.string`
/// bridges (transcodes) the whole accumulated text each time — O(children × length).
/// Rendering twice the paragraphs must cost about twice the time, not four times.
@Suite("Node renderer block scaling", .serialized)
@MainActor
struct NodeRendererBlockScalingTests {
    nonisolated private static let prose = String(repeating: "風穿過山林，江水映著月光，行人仍沿著古道前進。", count: 2)

    @Test("one container with many CJK paragraphs renders in linear time")
    func manyParagraphsInOneBlockScaleLinearly() async throws {
        // Warm caches (fonts, paragraph styles) so the first measurement is not penalised.
        _ = try await render(paragraphs: 500)

        let small = 5000
        let smallMs = try await bestOf(3) { try await render(paragraphs: small) }
        let largeMs = try await bestOf(3) { try await render(paragraphs: small * 2) }
        let ratio = largeMs / smallMs
        print("BLOCK_SCALING paragraphs=\(small) ms=\(String(format: "%.1f", smallMs)) paragraphs=\(small * 2) ms=\(String(format: "%.1f", largeMs)) ratio=\(String(format: "%.2f", ratio))")
        #expect(ratio <= 2.5, "2× paragraphs took \(ratio)× the time — quadratic work in the block child loop")
    }

    @Test("block children after inline content still start their own paragraph")
    func blockChildAfterInlineContentGetsBreak() async {
        let renderer = Self.makeRenderer()
        let output = await renderer.render([
            .block(tag: "div", children: [
                .text("前導"),
                .paragraph([.text("第一段")], style: .body),
                .paragraph([.text("第二段")], style: .body)
            ], style: .none)
        ])
        let paragraphs = output.string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(paragraphs == ["前導", "第一段", "第二段"])
        #expect(!output.string.contains("\n\n"))
    }

    private func render(paragraphs count: Int) async throws -> Double {
        let renderer = Self.makeRenderer()
        let children = (0..<count).map { index in
            RenderableNode.paragraph([.text("\(index)\(Self.prose)")], style: .body)
        }
        let start = SourcePerfTrace.now
        let output = await renderer.render([.block(tag: "div", children: children, style: .none)])
        let elapsed = (SourcePerfTrace.now - start) * 1000
        #expect(output.length >= count * Self.prose.utf16.count)
        return elapsed
    }

    private func bestOf(_ runs: Int, _ body: () async throws -> Double) async throws -> Double {
        var best = Double.infinity
        for _ in 0..<runs { best = min(best, try await body()) }
        return best
    }

    private static func makeRenderer() -> NodeAttributedStringRenderer {
        NodeAttributedStringRenderer(config: .init(
            from: ReaderRenderSettings(theme: "test", textColor: .black, backgroundColor: .white,
                                       fontSize: 22, lineHeightMultiple: 1.4, lineSpacing: 0,
                                       paragraphSpacing: 6, letterSpacing: 0, marginH: 0, marginV: 0,
                                       footerHeight: 0, contentInsets: .zero, writingMode: .horizontal),
            textColor: .black, renderWidth: 360
        ))
    }
}
