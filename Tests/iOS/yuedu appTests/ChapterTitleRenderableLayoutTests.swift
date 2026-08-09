import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite("Chapter title block renderables", .serialized)
struct ChapterTitleRenderableLayoutTests {
    @Test("paginator extracts one title plan and suppresses its source glyphs")
    func paginatorExtraction() throws {
        let (attributed, plan) = makeAttributedTitleWithRenderPlan()
        let result = CoreTextPaginator.extractChapterTitleRenderablesForTesting(
            attributedString: attributed,
            frameSize: CGSize(width: 320, height: 480)
        )

        let renderable = try #require(result.renderables.first)
        #expect(result.renderables.count == 1)
        #expect(renderable.chapterTitlePlan == plan)
        #expect(result.suppressedRanges == [
            NSRange(location: 0, length: attributed.length)
        ])
    }

    @Test("scroll slicer carries the same title renderable contract")
    func scrollExtraction() throws {
        let (attributed, plan) = makeAttributedTitleWithRenderPlan()
        let size = CGSize(width: 320, height: 480)
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributed as CFAttributedString
        )
        let range = CFRange(location: 0, length: attributed.length)
        let frame = CoreTextPaginator.makeFrame(
            framesetter: framesetter,
            range: range,
            path: CGPath(rect: CGRect(origin: .zero, size: size), transform: nil),
            writingMode: .horizontal
        )

        let renderables = CoreTextChunkSlicer.extractBlockRenderables(
            frame: frame,
            chunkSize: size,
            attributedString: attributed,
            charRange: range,
            writingMode: .horizontal
        )

        #expect(renderables.count == 1)
        #expect(renderables.first?.chapterTitlePlan == plan)
        #expect(renderables.first?.sourceRanges == [
            NSRange(location: 0, length: attributed.length)
        ])
    }

    @Test("vertical rect maps the canvas into right to left column space")
    func verticalRect() {
        let rect = ChapterTitleCanvasGeometry.resolve(
            canvasSize: CGSize(width: 300, height: 100),
            container: CGRect(x: 20, y: 30, width: 300, height: 500),
            writingMode: .verticalRTL
        )

        #expect(rect.width == 100)
        #expect(rect.height == 300)
        #expect(rect.maxX == 320)
        #expect(rect.minY == 30)
    }

    private func makeAttributedTitleWithRenderPlan() -> (
        NSAttributedString,
        ChapterTitleRenderPlan
    ) {
        let plan = ChapterTitleRenderPlan(
            accessibilityText: "第一章 初入江湖",
            canvasSize: CGSize(width: 320, height: 100),
            layers: []
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = plan.canvasSize.height
        paragraph.maximumLineHeight = plan.canvasSize.height
        let attributed = NSMutableAttributedString(
            string: plan.accessibilityText + "\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 1),
                .foregroundColor: UIColor.clear,
                .paragraphStyle: paragraph,
            ]
        )
        attributed.addAttribute(
            ChapterTitleAttributedBuilder.designRenderPlanAttribute,
            value: plan,
            range: NSRange(location: 0, length: attributed.length)
        )
        return (attributed, plan)
    }
}
