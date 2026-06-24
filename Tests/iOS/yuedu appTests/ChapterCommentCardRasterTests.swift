import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Verifies the 起点中文 本章说 (chapter-comment) big SVG card actually rasterizes through the
/// real OnlineImageLoader path — the card was vanishing because WKWebView.takeSnapshot threw on
/// the oversized (~1080pt) bitmap. These tests run the exact production code, not a port.
@Suite("Chapter comment card rasterization")
struct ChapterCommentCardRasterTests {

    /// A faithful-shape 本章说 card: width=1080, NO viewBox, rgba bg, many <text>, a like-pill
    /// (rect+path+text) — same structure as jsLib ChapterCmtSvg/createSvgDocument.
    private func cardSVG(height: Int = 700) -> String {
        let likePath = "M8.75 1.66C8.43 1.66 8.14 1.84 8.0 2.12 7.84 2.45 7.74 2.91 7.66 3.31 L7.08 9.42 V15.83 L13.96 15.83 C14.37 15.83 14.73 15.52 14.78 15.11 L15.58 10.11 C15.65 9.61 15.26 9.16 14.75 9.16 H11.66 V5.41 Z"
        return """
        <svg width="1080" height="\(height)" xmlns="http://www.w3.org/2000/svg">\
        <rect width="1080" height="\(height)" fill="rgba(255,255,255,0.25)" rx="35"/>\
        <text x="80" y="75" font-size="44" font-family="Arial" fill="#000">本章说</text>\
        <text x="1000" y="75" font-size="36" font-family="Arial" text-anchor="end" fill="#000">525条评论 ❯</text>\
        <rect x="880" y="150" width="120" height="64" rx="32" fill="rgba(200,200,200,0.35)" stroke="rgba(0,0,0,0.06)" stroke-width="1"/>\
        <g transform="translate(896,165) scale(2.3)"><path d="\(likePath)" fill="#000"/></g>\
        <text x="940" y="195" font-size="40" font-family="Arial" fill="#000">10</text>\
        <text x="80" y="190" font-weight="bold" font-size="42" font-family="Arial" fill="#000">绝傲蜀风</text>\
        <text x="80" y="280" font-size="42" font-family="Arial" fill="#000">近现代背景、古董加点、漂亮妹妹</text>\
        <text x="80" y="420" font-weight="bold" font-size="42" font-family="Arial" fill="#000">刀锋大帝</text>\
        <text x="80" y="500" font-size="42" font-family="Arial" fill="#000">阅</text>\
        </svg>
        """
    }

    /// Exact data-URI shape the source emits: base64 SVG + a trailing legado click-config.
    private func cardDataURI() -> String {
        let svg = cardSVG()
        let b64 = Data(svg.utf8).base64EncodedString()
        let click = #"{"style":"FULL","type":"qd","click":"androidshowChapterComments(1,2,3)"}"#
        return "data:image/svg+xml;base64,\(b64),\(click)"
    }

    @Test("width/height-only card gets a viewBox injected so it scales (not clips)")
    @MainActor
    func widthHeightOnlyCardGetsViewBox() {
        // The 本章说 card / 版权页 banner are authored width=1080 height=H with NO viewBox. Without a
        // viewBox WKWebView clips them to the top-left corner when forced to the column width,
        // which is why the card "vanished". The rasterizer must inject a matching viewBox.
        let svg = cardSVG(height: 700)
        #expect(!svg.contains("viewBox"))
        let fixed = SVGWebViewRasterizer.shared.ensureViewBox(in: svg)
        #expect(fixed.contains("viewBox=\"0 0 1080 700\""))
    }

    @Test("an SVG that already declares a viewBox is left untouched")
    @MainActor
    func existingViewBoxUntouched() {
        let svg = #"<svg width="180" height="144" viewBox="5 14 45 36" xmlns="http://www.w3.org/2000/svg"><rect width="45" height="36"/></svg>"#
        let fixed = SVGWebViewRasterizer.shared.ensureViewBox(in: svg)
        #expect(fixed == svg)
    }

    @Test("resolveSVGSize caps the 1080pt card to the column width")
    @MainActor
    func cardSizeIsClampedToColumnWidth() {
        let size = SVGWebViewRasterizer.shared.resolveSVGSize(
            styleWidth: nil, styleHeight: nil, svgString: cardSVG(), renderWidth: 360
        )
        // Must be capped to the 360pt column, not the intrinsic 1080.
        #expect(size.width <= 361)
        #expect(size.width > 300)
        // Aspect ratio preserved (1080:700 → 360:~233).
        #expect(abs(size.height - 360.0 * 700.0 / 1080.0) < 2.0)
    }

    @Test("本章说 card loads to a non-nil image through OnlineImageLoader")
    func cardRasterizesEndToEnd() async {
        let uri = cardDataURI()
        let image = await OnlineImageLoader.load(src: uri, renderWidth: 360, timeout: 12)
        #expect(image != nil)
        if let image {
            // Should be a real, non-empty bitmap.
            #expect(image.size.width > 50)
            #expect(image.size.height > 30)
            print("⟐TEST card image = \(Int(image.size.width))x\(Int(image.size.height)) @\(image.scale)x")
        } else {
            print("⟐TEST card image = NIL (rasterization failed)")
        }
    }

    @Test("raw rasterizer at the intrinsic 1080x700 size")
    @MainActor
    func rawRasterizerAtIntrinsicSize() async {
        let img = await SVGWebViewRasterizer.shared.render(
            svgString: cardSVG(), size: CGSize(width: 1080, height: 700)
        )
        print("⟐TEST raw 1080x700 = \(img == nil ? "NIL" : "\(Int(img!.size.width))x\(Int(img!.size.height))")")
        // Informational: documents whether the un-clamped size is what fails.
    }
}
