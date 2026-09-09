import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite("Paged and scroll appearance", .serialized)
struct CoreTextPagedScrollAppearanceTests {
    // The same frame isolates paint differences from legitimate page/chunk breaks.
    // These authored fixed-height fills reproduce the gallery heading and resource bar.
    @Test(arguments: [false, true]) @MainActor
    func authoredCompositionMatchesScroll(nestedBackdrop: Bool) async throws {
        let size = CGSize(width: 360, height: 800)
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 17, lineHeightMultiple: 1.5, lineSpacing: 0,
            paragraphSpacing: 8, firstLineIndent: 0, textColor: .black,
            backgroundColor: .white, fontFamilyName: nil, renderWidth: size.width
        )
        let outerOpen = nestedBackdrop ? "<div style=\"background:#f8f9fa;border:2px solid #dde0e3\">" : ""
        let outerClose = nestedBackdrop ? "</div>" : ""
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
        <p>惜春作画＋海棠诗社</p>
        <div style="width:70%;height:32px;margin:0 auto;background:#6050a0;color:white;text-align:center">红 楼 梦 画 册 叁</div>
        <p>A Dream of Red Mansions</p>
        <p>由王子和画师精心绘制</p>
        \(outerOpen)<div style="border:1px solid black;padding:12px">
          <p>本月已用资源额度</p>
          <div style="height:16px;background:#20c997;color:white;text-align:center">294MB/300MB</div>
          <p>资源使用率：98% | 剩余：6MB</p>
        </div>\(outerClose)
        <p>正文继续。</p>
        </body></html>
        """, config: config)
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: attributed, imagePage: nil,
            anchorOffsets: [:], renderSize: size, fontSize: 17, contentInsets: .zero
        )
        try #require(layout.pageRanges.count == 1)
        let frame = CoreTextPageView.frameForRendering(layout: layout, pageIndex: 0)
        let scrollDecorations = CoreTextChunkSlicer.extractBlockRenderables(
            frame: frame, chunkSize: size, attributedString: layout.attributedString,
            charRange: layout.pageRanges[0]
        )
        let chunk = CoreTextChunk(
            chapterIndex: 0, charRange: layout.pageRanges[0], size: size,
            framesetter: layout.framesetter, attributedString: layout.attributedString,
            frame: frame, blockRenderables: scrollDecorations
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let paged = renderer.image { context in
            CoreTextPageView.renderPage(layout: layout, pageIndex: 0,
                in: context.cgContext, bounds: CGRect(origin: .zero, size: size))
        }
        let scrollView = CoreTextChunkDrawView(frame: CGRect(origin: .zero, size: size))
        scrollView.chunk = chunk
        let scroll = renderer.image { context in
            layout.backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            scrollView.draw(scrollView.bounds)
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paged-scroll-appearance-\(nestedBackdrop)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try paged.pngData()?.write(to: directory.appendingPathComponent("paged.png"))
        try scroll.pngData()?.write(to: directory.appendingPathComponent("scroll.png"))
        // Compare real compositor output, including text, authored fills and borders.
        let a = try #require(paged.cgImage?.dataProvider?.data) as Data
        let b = try #require(scroll.cgImage?.dataProvider?.data) as Data
        #expect(a == b, "The same chapter frame must retain the scroll composition in paged mode. Captures: \(directory.path)")
    }
}
