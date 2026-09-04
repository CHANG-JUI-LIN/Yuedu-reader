import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A title layer's box is authored against the template's own font; the reader
/// draws it with its own, and a CJK fallback is taller than the Latin face the
/// template was designed with. These pin down that the glyphs survive that
/// mismatch — a title that silently loses its CJK while keeping a Latin digit
/// is the failure this suite exists to catch.
@Suite("Chapter title line box", .serialized)
struct ChapterTitleLineBoxTests {
    private static let canvasHeight: Double = 226

    @Test("an authored line height never squeezes the line the reader actually draws")
    func lineHeightNeverSqueezesResolvedFont() async throws {
        // 星环's own numbers: a 16.26pt line authored at 20.3pt, which is what
        // Roboto needs and 2pt less than the CJK face substituted for it.
        let plan = try await compile(
            title: "第一章 小小灵娥",
            fontSize: 16.26086956521739,
            lineHeight: 20.296521739130437,
            frameHeight: 20.296521739130437
        )
        let attributed = try #require(plan.layers.first?.attributedText)
        let paragraph = try #require(
            attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        #expect(paragraph.maximumLineHeight >= naturalHeight(of: attributed))
    }

    @Test("a box shorter than its own line still paints every glyph")
    func shortBoxDoesNotClipGlyphs() async throws {
        let tight = try await compile(
            title: "第一章 小小灵娥",
            fontSize: 16,
            lineHeight: 10,
            frameHeight: 10
        )
        let generous = try await compile(
            title: "第一章 小小灵娥",
            fontSize: 16,
            lineHeight: 10,
            frameHeight: 60
        )

        let clipped = ink(in: tight)
        let whole = ink(in: generous)
        #expect(whole > 100)
        #expect(clipped == whole)
    }

    /// The title text is painted with CoreText (the UIKit string-drawing call it
    /// replaced never reached the glass on one device while the same layer's
    /// image did). CoreText honours the paragraph alignment carried by the
    /// attributed string — these pin that down, since an alignment regression
    /// would put every imported template's title against the wrong edge.
    @Test("each alignment lands the text against the side it asked for")
    func alignmentIsHonoured() async throws {
        let left = try #require(centroidX(of: try await compile(
            title: "第一章 小小灵娥", fontSize: 16, lineHeight: 22,
            frameHeight: 22, alignment: .left
        )))
        let centre = try #require(centroidX(of: try await compile(
            title: "第一章 小小灵娥", fontSize: 16, lineHeight: 22,
            frameHeight: 22, alignment: .center
        )))
        let right = try #require(centroidX(of: try await compile(
            title: "第一章 小小灵娥", fontSize: 16, lineHeight: 22,
            frameHeight: 22, alignment: .right
        )))

        #expect(left < centre)
        #expect(centre < right)
        #expect(abs(centre - 196) < 8)
    }

    /// CoreText draws `.underlineStyle` itself; verified against the UIKit path
    /// before the switch (634 vs 627 ink pixels on the same string).
    @Test("underline survives the CoreText path")
    func underlineSurvives() async throws {
        let plain = ink(in: try await compile(
            title: "第一章 小小灵娥", fontSize: 16, lineHeight: 22, frameHeight: 22
        ))
        let underlined = ink(in: try await compile(
            title: "第一章 小小灵娥", fontSize: 16, lineHeight: 22,
            frameHeight: 22, underline: true
        ))

        #expect(underlined > plain)
    }

    // MARK: - Support

    /// One centred chapter-name layer, positioned like a template's text slot.
    private func compile(
        title: String,
        fontSize: Double,
        lineHeight: Double,
        frameHeight: Double,
        alignment: ChapterTitleAlignment = .center,
        underline: Bool? = nil
    ) async throws -> ChapterTitleRenderPlan {
        let style = ChapterTitleLayerStyle(
            ruleStyle: ReaderStyleRuleStyle(
                text: ReaderStyleTextStyle(
                    colorHex: 0,
                    fontSize: fontSize,
                    fontWeight: 600,
                    lineHeight: lineHeight,
                    underline: underline
                )
            ),
            textAlignment: alignment
        )
        let design = ChapterTitleDesign(
            canvasAspectRatio: 392 / Self.canvasHeight,
            canvasHeight: Self.canvasHeight,
            layers: [
                ChapterTitleLayer(
                    id: readerStyleFixtureUUID(41),
                    name: "name",
                    kind: .chapterName,
                    frame: .init(
                        x: 0,
                        y: 0.4,
                        width: 1,
                        height: frameHeight / Self.canvasHeight
                    ),
                    rotation: .init(degrees: 0),
                    isVisible: true,
                    isLocked: false,
                    content: .dynamic(.name),
                    lightStyle: style,
                    darkStyle: style
                ),
            ]
        )
        return try await ChapterTitleDesignRenderer.compile(
            title: title,
            design: design,
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 392,
            assetStore: ReaderStyleAssetStore(rootURL: try readerStyleTemporaryDirectory())
        )
    }

    /// What the string measures when nothing forces its line box.
    private func naturalHeight(of attributed: NSAttributedString) -> CGFloat {
        let copy = NSMutableAttributedString(attributedString: attributed)
        copy.removeAttribute(
            .paragraphStyle,
            range: NSRange(location: 0, length: copy.length)
        )
        return copy.boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
    }

    private func centroidX(of plan: ChapterTitleRenderPlan) -> CGFloat? {
        guard let raster = rasterize(plan) else { return nil }
        var sum: CGFloat = 0
        var total = 0
        for (index, red) in raster.red.enumerated() where red < 200 {
            sum += CGFloat(index % raster.width)
            total += 1
        }
        guard total > 0 else { return nil }
        return sum / CGFloat(total)
    }

    private func ink(in plan: ChapterTitleRenderPlan) -> Int {
        guard let raster = rasterize(plan) else { return -1 }
        return raster.red.count { $0 < 200 }
    }

    /// One red byte per pixel, row major, painted on white at 1x so pixel and
    /// point coordinates coincide.
    private func rasterize(
        _ plan: ChapterTitleRenderPlan
    ) -> (red: [UInt8], width: Int)? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: plan.canvasSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: plan.canvasSize))
            ChapterTitleCanvasPainter.draw(
                plan,
                in: CGRect(origin: .zero, size: plan.canvasSize),
                writingMode: ReaderWritingMode.horizontal,
                context: context.cgContext
            )
        }
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (stride(from: 0, to: buffer.count, by: 4).map { buffer[$0] }, width)
    }
}
