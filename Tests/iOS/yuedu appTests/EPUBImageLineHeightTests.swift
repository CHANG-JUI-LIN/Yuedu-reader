import Testing
import UIKit
import CoreText
@testable import yuedu_app

/// Regression guard for the Hebrew-RTL EPUB image layout (israelsailing sample):
/// `<p class="regular"><img style="width:90%"/><br/></p>` between two text paragraphs.
/// The image placeholder's line must reserve the image's full drawn height; if it only
/// reserved one text line the following paragraph would be laid out inside the image's
/// vertical band and the image (drawn in the overlay pass) would cover it — leaving only
/// the left edge of the RTL text peeking past the right-aligned image.
@Suite("EPUB image line-height reservation", .serialized)
struct EPUBImageLineHeightTests {

    private static let html = """
    <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="he">
    <head><style>
      p { text-align:right; margin:8px; }
      .regular { font-size:100%; }
    </style></head>
    <body style="text-align:right" dir="rtl">
    <p class="regular">
    שורה ראשונה של טקסט לפני התמונה כדי למלא מקום.<br />
    </p>
    <p class="regular">
    <img src="pic65.jpg" style="width:90%" alt="מרינה הרצליה" /><br />
    </p>
    <p class="regular">
    לפני מספר חודשים הרס וירוס אימתני את מרבית מחשבי העולם בשנת 2014.<br />
    </p>
    </body>
    </html>
    """

    /// 2560x1920 landscape (4:3), matching pic65.jpg's aspect ratio.
    private static func makeImage() async -> UIImage {
        await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 256, height: 192)).image { ctx in
                UIColor.systemTeal.setFill()
                ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
            }
        }
    }

    private static func config(renderWidth: CGFloat) -> HTMLAttributedStringBuilder.Config {
        HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: renderWidth,
            writingMode: .horizontal
        )
    }

    /// Reserved line height (paragraph min/max) of the image placeholder, plus the run
    /// delegate's ascent+descent and drawn height.
    private func imageLineMetrics(in attr: NSAttributedString) -> (reserved: CGFloat, runHeight: CGFloat, drawHeight: CGFloat)? {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let ns = attr.string as NSString
        var found: (CGFloat, CGFloat, CGFloat)?
        attr.enumerateAttribute(delegateKey, in: NSRange(location: 0, length: attr.length)) { value, range, stop in
            guard let value, ns.substring(with: range).contains("\u{FFFC}") else { return }
            let info = Unmanaged<ImageRunInfo>
                .fromOpaque(CTRunDelegateGetRefCon(value as! CTRunDelegate)).takeUnretainedValue()
            guard info.image != nil else { return }
            let para = attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let reserved = max(para?.minimumLineHeight ?? 0, para?.maximumLineHeight ?? 0)
            found = (reserved, info.ascent + info.descent, info.drawHeight)
            stop.pointee = true
        }
        return found
    }

    @Test("legacy builder reserves the image's full height on its line")
    func legacyReservesImageHeight() async throws {
        let image = await Self.makeImage()
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let result = await builder.build(html: Self.html, config: Self.config(renderWidth: 358))
        let m = try #require(imageLineMetrics(in: result.attributedString))
        #expect(m.drawHeight > 100, "sanity: image should be tall (got \(m.drawHeight))")
        #expect(m.reserved >= m.runHeight - 1, "reserved \(m.reserved) must cover run height \(m.runHeight)")
        #expect(m.reserved >= m.drawHeight - 1, "reserved \(m.reserved) must cover drawn height \(m.drawHeight)")
    }

    @Test("RenderableNode renderer reserves the image's full height on its line")
    func renderableNodeReservesImageHeight() async throws {
        let image = await Self.makeImage()
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let ast = try #require(await builder.buildStyledAST(html: Self.html, config: Self.config(renderWidth: 358)))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let settings = ReaderRenderSettings(
            theme: "test", textColor: .black, backgroundColor: .white,
            fontSize: 18, lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 8,
            letterSpacing: 0, marginH: 0, marginV: 0, footerHeight: 0,
            contentInsets: .zero, writingMode: .horizontal
        )
        let cfg = NodeAttributedStringRenderer.Config(
            from: settings, textColor: .black, renderWidth: 358, imageLoader: { _ in image })
        let attr = await NodeAttributedStringRenderer(config: cfg).render(nodes)
        let m = try #require(imageLineMetrics(in: attr))
        #expect(m.drawHeight > 100, "sanity: image should be tall (got \(m.drawHeight))")
        #expect(m.reserved >= m.runHeight - 1, "reserved \(m.reserved) must cover run height \(m.runHeight)")
        #expect(m.reserved >= m.drawHeight - 1, "reserved \(m.reserved) must cover drawn height \(m.drawHeight)")
    }
}
