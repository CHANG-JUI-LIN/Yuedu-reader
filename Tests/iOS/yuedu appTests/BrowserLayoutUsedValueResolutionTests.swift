import Testing
import UIKit
@testable import yuedu_app

/// Synthetic coverage for CSS computed-value → used-value timing.
///
/// Every percentage in this suite is intentionally nested beneath a containing
/// block whose final content width differs from the reader render width. That
/// distinction catches accidental early resolution against `renderWidth` or a
/// recursively propagated provisional width.
struct BrowserLayoutUsedValueResolutionTests {

    private let pageSize = CGSize(width: 400, height: 2_000)

    private func layout(
        _ html: String,
        images: [String: UIImage] = [:]
    ) throws -> BrowserLayoutDocument.BrowserLayoutPipelineResult {
        let config = BrowserLayoutConfig(
            renderWidth: pageSize.width,
            renderHeight: pageSize.height,
            rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"],
            textColor: .black,
            backgroundColor: .white
        )
        let document = BrowserLayoutDocument(
            html: html,
            cssTexts: [],
            config: config,
            imageLoader: { images[$0] }
        )
        return try document.makeLayout(containerSize: pageSize)
    }

    private func box(
        id: String,
        in root: BlockBox,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> BlockBox {
        if root.debugID == id { return root }
        for child in root.children {
            if let match = try? box(id: id, in: child, sourceLocation: sourceLocation) {
                return match
            }
        }
        Issue.record("missing box #\(id)", sourceLocation: sourceLocation)
        throw MissingBox()
    }

    private struct MissingBox: Error {}

    private func image(size: CGSize = CGSize(width: 800, height: 400)) -> UIImage {
        BrowserLayoutTestSupport.makeImage(size: size, color: .red)
    }

    @Test func nestedPercentageBlocksUseImmediateFinalContainingBlock() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <div id="outer" style="width:50%;margin:0;padding:0">
            <div id="inner" style="width:50%;height:10px;margin:0;padding:0"></div>
          </div>
        </body></html>
        """)

        let outer = try box(id: "outer", in: result.rootBox)
        let inner = try box(id: "inner", in: result.rootBox)
        #expect(abs(outer.contentSize.width - 200) < 0.01)
        #expect(abs(inner.contentSize.width - 100) < 0.01)
    }

    @Test func percentagePaddingUsesContainingBlockInlineSize() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <div id="outer" style="width:50%;margin:0;padding:0">
            <div id="inner" style="margin:0;padding-left:10%;padding-right:10%">padding</div>
          </div>
        </body></html>
        """)

        let inner = try box(id: "inner", in: result.rootBox)
        #expect(abs(inner.padding.left - 20) < 0.01)
        #expect(abs(inner.padding.right - 20) < 0.01)
        #expect(abs(inner.contentSize.width - 160) < 0.01)
    }

    @Test func percentageMarginUsesContainingBlockInlineSize() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <div id="outer" style="width:50%;margin:0;padding:0">
            <div id="inner" style="margin-left:10%;margin-right:10%;padding:0">margin</div>
          </div>
        </body></html>
        """)

        let inner = try box(id: "inner", in: result.rootBox)
        #expect(abs(inner.margins.left - 20) < 0.01)
        #expect(abs(inner.margins.right - 20) < 0.01)
        #expect(abs(inner.contentSize.width - 160) < 0.01)
    }

    @Test func inlinePercentageImageUsesFinalBlockContentWidth() throws {
        let result = try layout(
            """
            <html><body style="margin:0;padding:0">
              <p id="host" style="margin-left:10%;margin-right:10%;padding-left:10%;padding-right:10%">
                <img src="image.png" style="width:50%">
              </p>
            </body></html>
            """,
            images: ["image.png": image()]
        )

        let host = try box(id: "host", in: result.rootBox)
        let atomic = try #require(host.inlineRuns.first(where: { $0.atomic != nil })?.atomic)
        // 400 - 40/40 margins - 40/40 padding = 240pt final content width.
        #expect(abs(host.contentSize.width - 240) < 0.01)
        #expect(abs(atomic.usedSize.width - 120) < 0.01)
        #expect(abs(atomic.usedSize.height - 60) < 0.01)
    }

    @Test func blockPercentageImageUsesFinalContainingBlockWidth() throws {
        let result = try layout(
            """
            <html><body style="margin:0;padding:0">
              <div id="outer" style="width:50%;margin:0;padding:0">
                <img id="image" src="image.png" style="display:block;width:50%">
              </div>
            </body></html>
            """,
            images: ["image.png": image()]
        )

        let outer = try box(id: "outer", in: result.rootBox)
        let imageBox = try box(id: "image", in: result.rootBox)
        #expect(abs(outer.contentSize.width - 200) < 0.01)
        #expect(abs(imageBox.contentSize.width - 100) < 0.01)
        #expect(abs(imageBox.contentSize.height - 50) < 0.01)
    }

    @Test func percentageImageInsidePercentageWidthParentComposesOncePerLevel() throws {
        let result = try layout(
            """
            <html><body style="margin:0;padding:0">
              <div id="outer" style="width:50%;margin:0;padding:0">
                <div id="inner" style="width:50%;margin:0;padding:0">
                  <img src="image.png" style="width:50%">
                </div>
              </div>
            </body></html>
            """,
            images: ["image.png": image()]
        )

        let inner = try box(id: "inner", in: result.rootBox)
        let atomic = try #require(inner.inlineRuns.first(where: { $0.atomic != nil })?.atomic)
        #expect(abs(inner.contentSize.width - 100) < 0.01)
        #expect(abs(atomic.usedSize.width - 50) < 0.01)
        #expect(abs(atomic.usedSize.height - 25) < 0.01)
    }

    @Test func percentageImageInsideFloatUsesFloatFinalContentWidth() throws {
        let result = try layout(
            """
            <html><body style="margin:0;padding:0">
              <div id="float" style="float:right;width:50%;margin:0;padding:0">
                <img src="image.png" style="width:50%">
              </div>
              <p style="margin:0">surrounding text</p>
            </body></html>
            """,
            images: ["image.png": image()]
        )

        let float = try box(id: "float", in: result.rootBox)
        let atomic = try #require(float.inlineRuns.first(where: { $0.atomic != nil })?.atomic)
        #expect(abs(float.contentSize.width - 200) < 0.01)
        #expect(abs(atomic.usedSize.width - 100) < 0.01)
        #expect(abs(atomic.usedSize.height - 50) < 0.01)
    }

    @Test func inheritedEmUsesFinalInheritedFontSize() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <div style="font-size:20px">
            <div id="target" style="font-size:150%;margin-left:2em;width:100px">em</div>
          </div>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        #expect(abs(target.style.fontSize - 30) < 0.01)
        #expect(abs(target.margins.left - 60) < 0.01)
    }

    @Test func emBorderWidthUsesElementFinalFontSize() throws {
        let result = try layout("""
        <html><head><style>
          .bordered { border-left:0.5em solid black; }
          #target { font-size:20px; }
        </style></head><body style="margin:0;padding:0">
          <div id="target" class="bordered">border</div>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        #expect(abs(target.style.fontSize - 20) < 0.01)
        #expect(abs(target.borders.left - 10) < 0.01)
    }

    @Test func percentageTextIndentUsesOwnFinalContentWidth() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <p id="target" style="margin-left:10%;margin-right:10%;padding-left:10%;padding-right:10%;text-indent:10%">
            第一行文字應依最終內容寬度縮排，第二行則不縮排。這段文字刻意足夠長以產生多行。
          </p>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        let first = try #require(target.lines.first)
        #expect(abs(target.contentSize.width - 240) < 0.01)
        #expect(abs(first.contentX - 24) < 0.01)
        if target.lines.count > 1 {
            #expect(abs(target.lines[1].contentX) < 0.01)
        }
    }

    @Test func ordinaryInlineLinesStayInsideFinalContentBox() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <p id="target" style="margin-left:10%;margin-right:10%;padding-left:10%;padding-right:10%">
            這是一段足夠長的普通文字，用來確認行分割直接使用區塊最終內容寬度，而不是全域 reader width。
          </p>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        #expect(abs(target.contentSize.width - 240) < 0.01)
        #expect(target.lines.count > 1)
        for line in target.lines {
            let usedRight = line.runs.map { $0.x + $0.width }.max() ?? 0
            #expect(usedRight <= target.contentSize.width + 0.5)
        }
    }

    @Test func maxWidthClampRecomputesAutoMargins() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <div id="target" style="width:100%;max-width:50%;margin-left:auto;margin-right:auto">center</div>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        #expect(abs(target.contentSize.width - 200) < 0.01)
        #expect(abs(target.margins.left - 100) < 0.01)
        #expect(abs(target.margins.right - 100) < 0.01)
    }

    @Test func lineHeightPercentageResolvesAfterWinningFontSize() throws {
        let result = try layout("""
        <html><head><style>
          .line { line-height:150%; }
          #target { font-size:20px; }
        </style></head><body style="margin:0;padding:0">
          <p id="target" class="line" style="margin:0">line height</p>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        #expect(abs(target.style.fontSize - 20) < 0.01)
        #expect(abs((target.style.lineHeight ?? 0) - 30) < 0.01)
    }

    @Test func unitlessLineHeightRecomputesOnInheritedChildFontSize() throws {
        let result = try layout("""
        <html><body style="margin:0;padding:0">
          <div style="font-size:20px;line-height:1.5">
            <p id="target" style="font-size:10px;margin:0">line height</p>
          </div>
        </body></html>
        """)

        let target = try box(id: "target", in: result.rootBox)
        #expect(abs(target.style.fontSize - 10) < 0.01)
        #expect(abs((target.style.lineHeight ?? 0) - 15) < 0.01)
    }

    @Test func percentageReplacedHeightNeverUsesInlineWidthAsItsBase() {
        var style = ComputedStyle()
        style.height = .percent(0.5)
        let intrinsic = CGSize(width: 100, height: 80)

        let withoutDefiniteHeight = BlockLayout.resolveReplacedSize(
            intrinsic: intrinsic,
            style: style,
            containerWidth: 400,
            rootFontSize: 17
        )
        #expect(abs(withoutDefiniteHeight.width - 100) < 0.01)
        #expect(abs(withoutDefiniteHeight.height - 80) < 0.01)

        let withDefiniteHeight = BlockLayout.resolveReplacedSize(
            intrinsic: intrinsic,
            style: style,
            containerWidth: 400,
            rootFontSize: 17,
            containerHeight: 300
        )
        #expect(abs(withDefiniteHeight.width - 187.5) < 0.01)
        #expect(abs(withDefiniteHeight.height - 150) < 0.01)
    }

    @Test func fixedLengthControlGeometryIsUnchanged() throws {
        let result = try layout(
            """
            <html><body style="margin:0;padding:0">
              <div id="target" style="width:200px;margin-left:10px;margin-right:10px;padding-left:20px;padding-right:20px">
                <img src="image.png" style="width:72px;height:48px">
              </div>
            </body></html>
            """,
            images: ["image.png": image()]
        )

        let target = try box(id: "target", in: result.rootBox)
        let atomic = try #require(target.inlineRuns.first(where: { $0.atomic != nil })?.atomic)
        #expect(abs(target.contentSize.width - 200) < 0.01)
        #expect(abs(target.margins.left - 10) < 0.01)
        #expect(abs(target.margins.right - 10) < 0.01)
        #expect(abs(target.padding.left - 20) < 0.01)
        #expect(abs(target.padding.right - 20) < 0.01)
        #expect(abs(atomic.usedSize.width - 72) < 0.01)
        #expect(abs(atomic.usedSize.height - 48) < 0.01)
    }
}
