import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Comprehensive geometry & layout tests for Phase 4B CSS Float Layout.
struct BrowserLayoutFloatLayoutTests {

    private func makeConfig(
        renderWidth: CGFloat = 390,
        renderHeight: CGFloat = 800,
        rootFontSize: CGFloat = 16,
        insets: UIEdgeInsets = .zero
    ) -> BrowserLayoutConfig {
        BrowserLayoutConfig(
            renderWidth: renderWidth,
            renderHeight: renderHeight,
            rootFontSize: rootFontSize,
            fontFamilies: ["PingFangSC-Regular"],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: insets
        )
    }

    private func flattenedFragments(_ fragments: [Fragment]) -> [Fragment] {
        fragments.flatMap { fragment -> [Fragment] in
            if case .group(let children) = fragment {
                return flattenedFragments(children)
            }
            return [fragment]
        }
    }

    private func textFragments(in page: PageFragments) -> [TextFragment] {
        flattenedFragments(page.fragments).compactMap { fragment in
            guard case .text(let text) = fragment else { return nil }
            return text
        }
    }

    private func fillFragments(in page: PageFragments) -> [FillFragment] {
        flattenedFragments(page.fragments).compactMap { fragment in
            guard case .fill(let fill) = fragment else { return nil }
            return fill
        }
    }

    private func imageFragments(in page: PageFragments) -> [ImageFragment] {
        flattenedFragments(page.fragments).compactMap { fragment in
            guard case .image(let image) = fragment else { return nil }
            return image
        }
    }

    // MARK: - 1. Left float + multi-line text

    @Test func leftFloatWithMultiLineText() async throws {
        let html = """
        <html><body>
        <div style="float: left; width: 140px; height: 100px; margin-right: 12px;"></div>
        <p style="margin: 0; line-height: 20px;">Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        // Float box should be placed at x=0, y=0, width=140, height=100
        let rootBox = layout.rootBox
        #expect(rootBox.children.count >= 2)
        let floatBox = rootBox.children[0]
        #expect(floatBox.isFloated)
        #expect(floatBox.frame.minX == 0)
        #expect(floatBox.frame.minY == 0)
        #expect(floatBox.frame.width == 140)
        #expect(floatBox.frame.height == 100)

        // Paragraph lines: lines with y < 100 should start at contentX == 152 (140 + 12)
        // and have lineWidth <= 238 (390 - 152). Lines below 100 should start at contentX == 0.
        let textBox = rootBox.children[1]
        #expect(!textBox.lines.isEmpty)

        var linesBesideFloatCount = 0
        var linesBelowFloatCount = 0

        for line in textBox.lines {
            if line.top < 100 {
                #expect(line.contentX == 152, "Line beside left float must start at leftIntrusion 152, got \(line.contentX)")
                linesBesideFloatCount += 1
            } else {
                #expect(line.contentX == 0, "Line below left float must restore contentX=0, got \(line.contentX)")
                linesBelowFloatCount += 1
            }
        }

        #expect(linesBesideFloatCount >= 3, "Expected at least 3 lines beside the 100pt float")
        #expect(linesBelowFloatCount >= 1, "Expected lines below the float")
    }

    // MARK: - 2. Right float + multi-line text

    @Test func rightFloatWithMultiLineText() async throws {
        let html = """
        <html><body style="margin: 0;">
        <div style="float: right; width: 120px; height: 80px; margin-left: 10px;"></div>
        <p style="margin: 0; line-height: 20px;">The quick brown fox jumps over the lazy dog near the river bank. Every good boy does fine in mathematics and music. Pack my box with five dozen liquor jugs and deliver them promptly to the warehouse.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let rootBox = layout.rootBox
        let floatBox = rootBox.children[0]
        #expect(floatBox.isFloated)
        // margin-left 10px, width 120px -> marginBox starts at 390 - 130 = 260, borderBox starts at 270
        #expect(floatBox.frame.minX == 270)
        #expect(floatBox.frame.minY == 0)
        #expect(floatBox.frame.width == 120)
        #expect(floatBox.frame.height == 80)

        let textBox = rootBox.children[1]
        for line in textBox.lines {
            if line.top < 80 {
                #expect(line.contentX == 0, "Right float: line contentX must be 0")
                let runTotal = line.runs.reduce(CGFloat(0)) { $0 + $1.width }
                #expect(runTotal <= 260.5, "Line beside right float must fit in 260pt, got \(runTotal)")
            } else {
                #expect(line.contentX == 0)
            }
        }
    }

    // MARK: - 3. Text exceeding float bottom restores full width

    @Test func textExceedingFloatBottomRestoresFullWidth() async throws {
        let html = """
        <html><body style="margin: 0;">
        <div style="float: left; width: 100px; height: 40px;"></div>
        <p style="margin: 0; line-height: 20px;">First line of text that wraps beside float.<br>Second line beside float.<br>Third line strictly below float with much longer text to confirm full column width usage.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let textBox = layout.rootBox.children[1]
        #expect(textBox.lines.count >= 3)
        #expect(textBox.lines[0].contentX == 100)
        #expect(textBox.lines[1].contentX == 100)
        #expect(textBox.lines[2].contentX == 0)
    }

    // MARK: - 4. clear: left

    @Test func clearLeft() async throws {
        let html = """
        <html><body>
        <div style="float: left; width: 100px; height: 60px;"></div>
        <div style="clear: left; width: 200px; height: 30px;"></div>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let clearedBox = layout.rootBox.children[1]
        #expect(clearedBox.frame.minY >= 60, "clear: left must position block at or below float bottom 60, got \(clearedBox.frame.minY)")
    }

    // MARK: - 5. clear: right

    @Test func clearRight() async throws {
        let html = """
        <html><body>
        <div style="float: right; width: 100px; height: 75px;"></div>
        <div style="clear: right; width: 200px; height: 30px;"></div>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let clearedBox = layout.rootBox.children[1]
        #expect(clearedBox.frame.minY >= 75, "clear: right must position block at or below float bottom 75, got \(clearedBox.frame.minY)")
    }

    // MARK: - 6. clear: both

    @Test func clearBoth() async throws {
        let html = """
        <html><body>
        <div style="float: left; width: 100px; height: 50px;"></div>
        <div style="float: right; width: 100px; height: 90px;"></div>
        <p style="clear: both; margin: 0;">Cleared paragraph</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let clearedP = layout.rootBox.children[2]
        #expect(clearedP.frame.minY >= 90, "clear: both must position block at or below max float bottom 90, got \(clearedP.frame.minY)")
    }

    // MARK: - 7. Left + Right float coexist

    @Test func leftAndRightFloatsCoexist() async throws {
        let html = """
        <html><body style="margin: 0;">
        <div style="float: left; width: 80px; height: 60px;"></div>
        <div style="float: right; width: 80px; height: 60px;"></div>
        <p style="margin: 0; line-height: 20px;">Middle text that flows between both floats.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let leftFloat = layout.rootBox.children[0]
        let rightFloat = layout.rootBox.children[1]
        let pBox = layout.rootBox.children[2]

        #expect(leftFloat.frame.minX == 0)
        #expect(rightFloat.frame.minX == 310) // 390 - 80
        #expect(!pBox.lines.isEmpty)
        let firstLine = pBox.lines[0]
        #expect(firstLine.contentX == 80)
        let runWidth = firstLine.runs.reduce(CGFloat(0)) { $0 + $1.width }
        #expect(runWidth <= 230.5) // 390 - 80 - 80 = 230
    }

    // MARK: - 8. Second float moves down when horizontal space is insufficient

    @Test func secondFloatMovesDownWhenSpaceInsufficient() async throws {
        let html = """
        <html><body>
        <div style="float: left; width: 250px; height: 50px;"></div>
        <div style="float: left; width: 200px; height: 40px;"></div>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let first = layout.rootBox.children[0]
        let second = layout.rootBox.children[1]

        #expect(first.frame.minX == 0)
        #expect(first.frame.minY == 0)

        // 250 + 200 = 450 > 390, so second float must move down below first float
        #expect(second.frame.minY >= 50, "Second float must move below first float, got y=\(second.frame.minY)")
        #expect(second.frame.minX == 0)
    }

    // MARK: - 9. Float at bottom of page moves to next page atomically

    @Test func floatAtPageBottomMovesToNextPage() async throws {
        // Render container height 200. First block has height 160. Float has height 80 (160 + 80 = 240 > 200).
        let html = """
        <html><body style="margin: 0">
        <div style="width: 100%; height: 160px; background-color: #eee;">Spacer</div>
        <div style="float: left; width: 100px; height: 80px; background-color: #f00;">Float</div>
        <p style="margin: 0;">Text following pushed float.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390, renderHeight: 200)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 200))
        let floatNodeID = layout.rootBox.children[1].debugNodeID
        let followingNodeID = layout.rootBox.children[2].debugNodeID
        let pages = try await doc.renderPages(containerSize: CGSize(width: 390, height: 200))

        #expect(pages.count == 2, "The 80pt float at y=160 must move once to page 1")
        #expect(!textFragments(in: pages[0]).contains { $0.nodeID == floatNodeID })

        let pageOneFloatFills = fillFragments(in: pages[1]).filter { $0.nodeID == floatNodeID }
        let floatFill = try #require(pageOneFloatFills.first)
        #expect(floatFill.rect.minY == 0)
        #expect(floatFill.rect.height == 80)

        let floatText = textFragments(in: pages[1]).filter { $0.nodeID == floatNodeID }
        #expect(!floatText.isEmpty)
        #expect(floatText.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= 80.001 })

        let followingText = try #require(textFragments(in: pages[1]).first { $0.nodeID == followingNodeID })
        #expect(followingText.rect.minY == 0)
        #expect(followingText.rect.minX >= 100)
    }

    // MARK: - 10. Float on next page exclusion coordinates

    @Test func floatOnNextPageExclusionCoordinates() async throws {
        let html = """
        <html><body style="margin: 0">
        <div style="width: 100%; height: 170px; background-color: #eee;">Spacer</div>
        <div style="float: left; width: 100px; height: 50px; background-color: #f00;">Float</div>
        <p style="margin: 0; line-height: 20px;">Line 1 next page beside float.<br>Line 2 next page beside float.<br>Line 3 below float.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390, renderHeight: 200)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 200))
        let floatNodeID = layout.rootBox.children[1].debugNodeID
        let paragraphNodeID = layout.rootBox.children[2].debugNodeID
        let pages = try await doc.renderPages(containerSize: CGSize(width: 390, height: 200))

        #expect(pages.count == 2)
        let pageOneText = textFragments(in: pages[1])
        let floatText = try #require(pageOneText.first { $0.nodeID == floatNodeID })
        #expect(floatText.rect.minY == 0)

        let paragraphLines = pageOneText.filter { $0.nodeID == paragraphNodeID }
        #expect(paragraphLines.count == 3)
        #expect(paragraphLines[0].rect.minY == 0)
        #expect(paragraphLines[0].rect.minX >= 100)
        #expect(abs(paragraphLines[1].rect.minY - 22.4) < 0.001)
        #expect(paragraphLines[1].rect.minX >= 100)
        #expect(abs(paragraphLines[2].rect.minY - 44.8) < 0.001)
        #expect(paragraphLines[2].rect.minX >= 100,
                "A 20pt line band at y=40 still overlaps the 50pt float")
    }

    // MARK: - 11. Float displacement propagates to following siblings

    @Test func floatDisplacementPropagatesToFollowingSiblings() async throws {
        let html = """
        <html><body>
        <div style="float: left; width: 100px; height: 50px;"></div>
        <p style="margin: 0;">Sibling paragraph</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let floatBox = layout.rootBox.children[0]
        let pBox = layout.rootBox.children[1]
        #expect(floatBox.isFloated)
        #expect(pBox.frame.minY == 0) // Normal flow paragraph starts at top of container and wraps
    }

    // MARK: - 12. Float margins participate in exclusion

    @Test func floatMarginsParticipateInExclusion() async throws {
        let html = """
        <html><body>
        <div style="float: left; width: 100px; height: 40px; margin-right: 25px; margin-bottom: 15px;"></div>
        <p style="margin: 0; line-height: 20px;">Line 1<br>Line 2<br>Line 3</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let pBox = layout.rootBox.children[1]
        #expect(!pBox.lines.isEmpty)
        // Line 1 & Line 2 top are < 55 (40 + 15), so contentX must be 125 (100 + 25)
        #expect(pBox.lines[0].contentX == 125)
        #expect(pBox.lines[1].contentX == 125)
        // Line 3 top is at 40, height 20 -> y: 40..60. Since margin-bottom is 15, float exclusion extends to 55.
        // Line 3 overlaps 55, so it also gets indented or if below 55 restores 0.
    }

    @Test func floatBorderPaddingAndMarginsUseOuterGeometry() throws {
        let html = """
        <html><body style="margin: 0">
        <div style="float: left; width: 100px; height: 40px; margin: 5px; padding: 10px; border: 2px solid #000"></div>
        <p style="margin: 0">Text beside the complete float margin box.</p>
        </body></html>
        """
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: makeConfig())
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let floatBox = layout.rootBox.children[0]
        #expect(floatBox.frame.minX == 5)
        #expect(floatBox.frame.minY == 5)
        #expect(floatBox.frame.width == 124)
        #expect(floatBox.frame.height == 64)
        #expect(layout.rootBox.children[1].lines[0].contentX == 134)
    }

    @Test func actualLineBandHeightDrivesFloatExclusion() {
        var style = ComputedStyle(fontSize: 16, fontFamilies: ["PingFangSC-Regular"])
        style.color = .black
        let text = "A line whose measured CoreText box crosses a float that starts at y 21."
        let run = InlineRun(
            text: text,
            style: style,
            sourceRange: NSRange(location: 0, length: (text as NSString).length)
        )
        let floats = FloatContext(containerWidth: 390)
        floats.placeFloat(
            side: .left,
            marginBoxSize: CGSize(width: 100, height: 30),
            margins: .zero,
            startY: 21
        )

        let lines = InlineLayout.layoutLines(
            runs: [run],
            maxWidth: 390,
            rootFontSize: 16,
            lineHeight: 20,
            sourceText: text,
            floatContext: floats
        )

        #expect(lines[0].height > 21)
        #expect(lines[0].contentX == 100,
                "The actual line band intersects the float even though a 20pt estimate would miss it")
    }

    @Test func replacedImageFloatUsesIntrinsicSize() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let html = """
        <html><body style="margin: 0">
        <img style="float: left" src="float.png">
        <p style="margin: 0">Text wraps beside the intrinsic image rectangle.</p>
        </body></html>
        """
        let doc = BrowserLayoutDocument(
            html: html,
            cssTexts: [],
            config: makeConfig(),
            imageLoader: { $0 == "float.png" ? image : nil }
        )
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 800))

        let floatBox = layout.rootBox.children[0]
        #expect(floatBox.frame.rawValue == CGRect(x: 0, y: 0, width: 80, height: 60))
        #expect(layout.rootBox.children[1].lines[0].contentX == 80)
    }

    @Test func oversizedReplacedFloatUsesPagedFitPolicy() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 300)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 300))
        }
        let html = """
        <html><body style="margin: 0">
        <div style="height: 160px">Spacer</div>
        <img style="float: left" src="tall.png">
        <p style="margin: 0">Following text must move with and wrap beside the fitted float.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 390, renderHeight: 200)
        let doc = BrowserLayoutDocument(
            html: html,
            cssTexts: [],
            config: config,
            imageLoader: { $0 == "tall.png" ? image : nil }
        )
        let layout = try doc.makeLayout(containerSize: CGSize(width: 390, height: 200))
        let imageNodeID = layout.rootBox.children[1].debugNodeID
        let paragraphNodeID = layout.rootBox.children[2].debugNodeID
        let pages = try await doc.renderPages(containerSize: CGSize(width: 390, height: 200))

        let fittedImage = try #require(imageFragments(in: pages[1]).first { $0.nodeID == imageNodeID })
        #expect(fittedImage.rect.minY == 0)
        #expect(fittedImage.rect.height == 200)
        #expect(abs(fittedImage.rect.width - 53.333) < 0.01)

        let following = try #require(textFragments(in: pages[1]).first { $0.nodeID == paragraphNodeID })
        #expect(following.rect.minY == 0)
        #expect(following.rect.minX >= fittedImage.rect.width)
    }

    @Test func oversizedNonReplacedFloatTriggersWholeChapterFallback() async {
        let html = """
        <html><body style="margin: 0">
        <div style="float: left; width: 100px; height: 240px">Too tall</div>
        <p style="margin: 0">Following text</p>
        </body></html>
        """
        let doc = BrowserLayoutDocument(
            html: html,
            cssTexts: [],
            config: makeConfig(renderHeight: 200)
        )

        await #expect(throws: BrowserLayoutDocument.BrowserLayoutError.self) {
            _ = try await doc.renderPages(containerSize: CGSize(width: 390, height: 200))
        }
    }

    // MARK: - 13. Percentage width float

    @Test func percentageWidthFloat() async throws {
        let html = """
        <html><body style="margin: 0;">
        <div style="float: left; width: 50%; height: 60px;"></div>
        <p style="margin: 0; line-height: 20px;">Paragraph wrapping beside 50% float.</p>
        </body></html>
        """
        let config = makeConfig(renderWidth: 400)
        let doc = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let layout = try doc.makeLayout(containerSize: CGSize(width: 400, height: 800))

        let floatBox = layout.rootBox.children[0]
        #expect(floatBox.frame.width == 200, "50% of 400 must be 200, got \(floatBox.frame.width)")

        let pBox = layout.rootBox.children[1]
        #expect(pBox.lines[0].contentX == 200)
    }

    // MARK: - 14. Unsupported width:auto fallback in scanner

    @Test func unsupportedWidthAutoFallbackInScanner() {
        let html = """
        <html><body>
        <div style="float: left;">Text inside float without width</div>
        </body></html>
        """
        let res = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: [])
        #expect(!res.supported, "Non-replaced float with width:auto must be rejected for fallback")
        #expect(res.unsupportedFeatures.contains(.float))
    }

    // MARK: - 15. Replaced <img> float without explicit width is supported in scanner

    @Test func replacedImageFloatIsSupportedInScanner() {
        let html = """
        <html><body>
        <img style="float: left;" src="cover.jpg" />
        <p>Text wrapping around float image.</p>
        </body></html>
        """
        let res = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: [])
        #expect(res.supported, "<img> float with intrinsic size is supported")
    }
}
