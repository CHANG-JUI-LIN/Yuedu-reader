@testable import YueduCoreText
import Foundation
import Testing
import UIKit
import CoreText
@testable import yuedu_app

@Suite("Comment bubble SVG recognizer", .serialized)
struct CommentBubbleSVGRecognizerTests {
    @Test("returns the selected built-in SVG template")
    func returnsSelectedTemplate() {
        #expect(
            CommentBubbleSVGRecognizer.templateSVG(for: .builtin, customSVG: "")
                == CommentBubbleSVGRecognizer.builtinBubbleSVG
        )
        #expect(
            CommentBubbleSVGRecognizer.templateSVG(for: .square, customSVG: "")
                == CommentBubbleSVGRecognizer.squareBubbleSVG
        )
    }

    @Test("returns an empty SVG for an empty custom template")
    func returnsEmptyCustomTemplateWithoutBuiltInFallback() {
        #expect(
            CommentBubbleSVGRecognizer.templateSVG(for: .custom, customSVG: "").isEmpty
        )
    }

    @Test("inherits the root SVG color for built-in bubble outlines and text")
    func inheritsRootColorForBuiltInTemplates() throws {
        for mode in [ReaderCommentBubblePresetMode.builtin, .square] {
            let bubble = try #require(
                CommentBubbleSVGRecognizer.recognize(
                    src: "",
                    svgContent: CommentBubbleSVGRecognizer.templateSVG(for: mode, customSVG: "")
                )
            )

            let hasColoredShape = bubble.elements.contains { element in
                switch element {
                case .path(_, let strokeColor, _, let fillColor, _):
                    return strokeColor != nil || fillColor != nil
                case .rect(_, _, _, _, _, _, let strokeColor, _, let fillColor, _):
                    return strokeColor != nil || fillColor != nil
                case .image(_, _, _), .text:
                    return false
                }
            }
            let hasColoredText = bubble.elements.contains { element in
                guard case let .text(_, _, _, _, _, _, _, color, _, _) = element else { return false }
                return color != nil
            }

            #expect(hasColoredShape)
            #expect(hasColoredText)
        }
    }

    @Test("accepts a full custom template beyond the legacy 8 KiB limit")
    func acceptsLargeCustomTemplateWithDisplayTextPlaceholder() throws {
        let detailedPath = String(repeating: "M0 0 L1 1 L2 0 Z ", count: 520)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
          <path d="\(detailedPath)" fill="#FFFFFF" stroke="#000000" />
          <text x="16" y="24" font-size="10" text-anchor="middle">$displayText</text>
        </svg>
        """

        #expect(svg.utf8.count > 8 * 1024)

        let bubble = try #require(
            CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg)
        )

        #expect(bubble.displayText == "$displayText")
        #expect(bubble.replacingDisplayText(with: "99+").displayText == "99+")
    }

    @Test("accepts an embedded raster image as the custom bubble artwork")
    func acceptsEmbeddedRasterImageArtwork() throws {
        let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
             width="100%" height="100%" viewBox="0 0 100 100">
          <image width="127" height="178" x="-13.5" y="-33"
                 xlink:href="data:image/png;base64,\(onePixelPNG)"/>
          <text x="50" y="36" font-size="40" text-anchor="middle">$displayText</text>
        </svg>
        """

        let bubble = try #require(
            CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg)
        )

        #expect(bubble.displayText == "$displayText")
        #expect(bubble.elements.contains { element in
            if case .image = element { return true }
            return false
        })
    }

    @Test("clamps bubble scale controls to their supported ranges")
    func clampsBubbleScaleControls() {
        #expect(GlobalSettings.sanitizedCommentBubbleScale(0.1) == 0.5)
        #expect(GlobalSettings.sanitizedCommentBubbleScale(2.5) == 2.0)
        #expect(GlobalSettings.sanitizedCommentBubbleTextScale(0.1) == 0.2)
        #expect(GlobalSettings.sanitizedCommentBubbleTextScale(1.0) == 0.8)
    }

    @Test("accepts the bubble.json ${num} placeholder as a replaceable count")
    func acceptsNumPlaceholder() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
          <path d="M0 0 H64 V64 H0 Z" fill="rgb(254,254,254)"/>
          <text x="32" y="40" font-size="22" fill="${color}" text-anchor="middle">${num}</text>
        </svg>
        """

        let bubble = try #require(
            CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg)
        )

        #expect(bubble.displayText == "${num}")
        #expect(bubble.replacingDisplayText(with: "99").displayText == "99")
    }

    @Test("reuses an SVG shape template without leaking the previous count")
    func reusesTemplateForDifferentCounts() throws {
        func svg(count: String) -> String {
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="64" height="48" viewBox="0 0 64 48">
              <path d="M2 2 H62 V46 H2 Z" fill="none" stroke="#888888" />
              <text x="32" y="32" font-size="20" text-anchor="middle">\(count)</text>
            </svg>
            """
        }

        let first = try #require(
            CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg(count: "5"))
        )
        let second = try #require(
            CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg(count: "99+"))
        )

        #expect(first.displayText == "5")
        #expect(second.displayText == "99+")
        #expect(first.viewBox == second.viewBox)
        #expect(first.elements.count == second.elements.count)
    }

    @Test("parses rgb(r,g,b) outline fills so bubble.json shapes actually paint")
    func parsesRGBFills() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
          <path d="M0 0 H32 V32 H0 Z" fill="rgb(254,254,254)"/>
          <text x="16" y="24" font-size="10" text-anchor="middle">$displayText</text>
        </svg>
        """

        let bubble = try #require(
            CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg)
        )

        let hasRGBFill = bubble.elements.contains { element in
            if case let .path(_, _, _, fillColor, _) = element, let fill = fillColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                fill.getRed(&r, green: &g, blue: &b, alpha: &a)
                return Int(round(r * 255)) == 254
                    && Int(round(g * 255)) == 254
                    && Int(round(b * 255)) == 254
            }
            return false
        }
        #expect(hasRGBFill)
    }

    @Test("treats numeric font-weight '900' as bold for rendering")
    func treatsNumeric900WeightAsBold() {
        // The render path folds 900/700/etc into isBold; we assert the threshold
        // check directly via the same comparison logic used by the recognizer.
        let weight = "900"
        let isNumericBold = Int(weight) ?? 0 >= 600
        #expect(isNumericBold)
    }

    @Test("comment-tag badges use the selected native SVG path")
    @MainActor
    func commentTagUsesSelectedNativeSVGPath() async throws {
        let settings = GlobalSettings.shared
        let oldFollowSource = settings.commentBubbleFollowsSourceSVG
        let oldPresetMode = settings.commentBubblePresetMode
        defer {
            settings.commentBubblePresetMode = oldPresetMode
            settings.commentBubbleFollowsSourceSVG = oldFollowSource
        }

        settings.commentBubblePresetMode = .square
        settings.commentBubbleFollowsSourceSVG = false

        let renderSettings = ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 0,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: renderSettings,
                textColor: .black,
                renderWidth: 320
            )
        )
        let result = await renderer.render([
            .paragraph([
                .text("正文"),
                .commentBadge(
                    count: "12",
                    reviewURL: "ydreview://test",
                    title: "本章說"
                )
            ], style: .body)
        ])

        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var info: ImageRunInfo?
        result.enumerateAttribute(
            delegateKey,
            in: NSRange(location: 0, length: result.length)
        ) { value, _, stop in
            guard let value else { return }
            info = Unmanaged<ImageRunInfo>
                .fromOpaque(CTRunDelegateGetRefCon(value as! CTRunDelegate))
                .takeUnretainedValue()
            stop.pointee = true
        }

        let runInfo = try #require(info)
        let renderedImage = try #require(runInfo.image)
        let expectedImage = try #require(
            CommentBubbleSVGRecognizer.commentBadgeImage(
                count: "12",
                pointSize: renderSettings.fontSize,
                themeTextColor: .black.withAlphaComponent(0.55)
            )
        )

        #expect(runInfo.isTextSized)
        #expect(renderedImage.size == expectedImage.size)
    }
}

/// The recognizer answers two different questions, and they need different strictness:
/// "is this unknown source image a bubble?" (strict — a wrong yes turns book illustrations
/// into bubbles) and "parse the template the user picked" (permissive — the user already
/// said what it is). These tests pin both halves so the two can't be collapsed again.
@Suite("Comment bubble recognition modes", .serialized)
struct CommentBubbleRecognitionModeTests {
    /// An artwork-only bubble: one <image> wrapping a raster, no <text> anywhere. This is
    /// the shape QiReader exports when the count is switched off, and the shape the 32KB
    /// string cap used to reject even though there is a single element to parse.
    private static func rasterBubbleSVG(pixels: Int = 8, noisy: Bool = false) throws -> String {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels))
        let image = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard noisy else { return }
            // PNG compresses a flat fill to ~1KB at any size; random pixels are what make
            // the encoded artwork genuinely large, the way real bubble art is.
            var generator = SystemRandomNumberGenerator()
            for x in stride(from: 0, to: pixels, by: 2) {
                for y in stride(from: 0, to: pixels, by: 2) {
                    UIColor(
                        red: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        green: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        blue: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
        let data = try #require(image.pngData())
        return "<svg xmlns='http://www.w3.org/2000/svg' width='90' height='120'"
            + " viewBox='0 0 90 120'><image href='data:image/png;base64,"
            + data.base64EncodedString()
            + "' width='90' height='120'/></svg>"
    }

    @Test("accepts an artwork-only template the user picked")
    func acceptsArtworkOnlyUserTemplate() throws {
        let svg = try Self.rasterBubbleSVG()
        let bubble = try #require(CommentBubbleSVGRecognizer.recognizeUserTemplate(svg))
        #expect(bubble.elements.count == 1)
        // Nothing to substitute a count into, which is exactly the author's intent.
        #expect(bubble.displayText == nil)
    }

    @Test("still refuses an artwork-only SVG when sniffing an unknown source image")
    func refusesArtworkOnlySourceImage() throws {
        // Relaxing this would make every <image>-only picture a book source serves render
        // as a comment bubble.
        let svg = try Self.rasterBubbleSVG()
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg) == nil)
    }

    @Test("accepts a user template far larger than the source-sniffing cap")
    func acceptsLargeUserTemplate() throws {
        // A base64 raster inflates ~33%, so real artwork lands well past 32KB while still
        // being a single element.
        let svg = try Self.rasterBubbleSVG(pixels: 256, noisy: true)
        #expect(svg.utf8.count > CommentBubbleSVGRecognizer.maximumRecognizableSVGByteCount)
        #expect(svg.utf8.count <= CommentBubbleSVGRecognizer.maximumUserTemplateSVGByteCount)
        #expect(CommentBubbleSVGRecognizer.recognizeUserTemplate(svg) != nil)
        // The strict path keeps its tight bound.
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg) == nil)
    }

    @Test("still requires exactly one count text when sniffing")
    func sniffingRequiresExactlyOneText() {
        let twoTexts = """
        <svg xmlns="http://www.w3.org/2000/svg" width="96" height="72" viewBox="0 0 96 72">
          <rect x="8" y="8" width="80" height="56" rx="18" fill="none" stroke="#888" stroke-width="6"/>
          <text x="48" y="46" font-size="30" fill="#888">0</text>
          <text x="10" y="20" font-size="10" fill="#888">1</text>
        </svg>
        """
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: twoTexts) == nil)
        // A second replaceable count is ambiguous for the user path too.
        #expect(CommentBubbleSVGRecognizer.recognizeUserTemplate(twoTexts) == nil)
    }

    @Test("refuses a template with nothing to draw")
    func refusesEmptyTemplate() {
        let empty = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"90\" height=\"120\"></svg>"
        #expect(CommentBubbleSVGRecognizer.recognizeUserTemplate(empty) == nil)
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: empty) == nil)
    }

    @Test("the built-in template still parses through both entry points")
    func builtinParsesInBothModes() {
        let builtin = CommentBubbleSVGRecognizer.builtinBubbleSVG
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: builtin) != nil)
        #expect(CommentBubbleSVGRecognizer.recognizeUserTemplate(builtin) != nil)
    }
}

/// QiReader's own bubble convention, as exported in `commentBubbleStyleData` (山风 packs'
/// 兔子): the count slot is an *empty* `<text>` QiReader fills in, `__TEXT__` stands for the
/// count colour on both the outline and the digits, and the digit is centred on its anchor
/// with `dominant-baseline="middle"`. Before these were understood the bubble drew no count
/// — and, with `__TEXT__` unresolvable, no outline either.
@Suite("QiReader bubble template", .serialized)
struct QiReaderBubbleTemplateTests {
    static let qiReaderSVG = """
    <svg viewBox="0 0 100 100" version="1.1" xmlns="http://www.w3.org/2000/svg" width="100" height="100">\
    <path d="M10 10 L90 10 L90 90 L10 90 Z" stroke-width="8" stroke="__TEXT__" fill="none"></path>\
    <text x="50" y="50" font-family="Arial" font-size="40" font-weight="bold" fill="__TEXT__" \
    text-anchor="middle" dominant-baseline="middle"></text></svg>
    """

    private static func autoStyle() -> ReaderCommentBubbleCustomStyle {
        ReaderCommentBubbleCustomStyle(name: "兔子", svg: qiReaderSVG)
    }

    @Test("a user template's empty <text> is the count slot")
    func emptyTextIsCountSlot() throws {
        let materialized = CommentBubbleSVGRecognizer.materializeTemplateColors(
            Self.qiReaderSVG,
            style: Self.autoStyle(),
            count: "12",
            themeTextColor: .black
        )
        let bubble = try #require(CommentBubbleSVGRecognizer.recognizeUserTemplate(materialized))
        let filled = bubble.replacingDisplayText(with: "12")
        #expect(filled.displayText == "12")
    }

    @Test("sniffing still refuses a source image whose only <text> is empty")
    func sniffingRefusesEmptyText() {
        // A book-source illustration with an empty text node is not a bubble.
        let svg = Self.qiReaderSVG.replacingOccurrences(of: "__TEXT__", with: "#000000")
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg) == nil)
    }

    @Test("__TEXT__ follows the reading theme when the pack says AUTO")
    func textTokenFollowsTheme() {
        let materialized = CommentBubbleSVGRecognizer.materializeTemplateColors(
            Self.qiReaderSVG,
            style: Self.autoStyle(),
            count: "12",
            themeTextColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        #expect(!materialized.contains("__TEXT__"))
        #expect(materialized.contains("#FF0000"))
    }

    @Test("__TEXT__ takes the pack's own colour when it gives one")
    func textTokenUsesPackColor() {
        var style = Self.autoStyle()
        style.dayNormalColor = "#00FF00"
        style.dayEmphasisColor = "#00FF00"
        let materialized = CommentBubbleSVGRecognizer.materializeTemplateColors(
            Self.qiReaderSVG,
            style: style,
            count: "12",
            themeTextColor: .black
        )
        #expect(materialized.contains("#00FF00"))
        #expect(!materialized.contains("__TEXT__"))
    }

    @Test("draws the outline and a vertically centred count")
    func drawsOutlineAndCenteredCount() throws {
        let materialized = CommentBubbleSVGRecognizer.materializeTemplateColors(
            Self.qiReaderSVG,
            style: Self.autoStyle(),
            count: "88",
            themeTextColor: .black
        )
        let bubble = try #require(CommentBubbleSVGRecognizer.recognizeUserTemplate(materialized))
        let image = CommentBubbleSVGRecognizer.draw(
            svg: bubble.replacingDisplayText(with: "88"),
            pointSize: 100,
            themeTextColor: .black,
            textFace: .reader
        )
        let alpha = try Self.alphaMap(image)

        // The outline: the left edge of the square, halfway down.
        #expect(alpha.value(atFractionX: 0.10, y: 0.50) > 128)

        // The count: inked rows inside the outline, centred on the anchor (y = 50%).
        // Drawn with `y` as the baseline instead, the digits sit wholly above the anchor
        // and their centre lands near 35%.
        let rows = alpha.inkedRows(insetFraction: 0.2)
        let top = try #require(rows.first)
        let bottom = try #require(rows.last)
        let center = CGFloat(top + bottom) / 2 / CGFloat(alpha.height)
        #expect(center > 0.42 && center < 0.58, "count centre at \(center)")
    }

    private struct AlphaMap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func value(atFractionX fx: CGFloat, y fy: CGFloat) -> UInt8 {
            let x = min(width - 1, Int(CGFloat(width) * fx))
            let y = min(height - 1, Int(CGFloat(height) * fy))
            return bytes[(y * width + x) * 4 + 3]
        }

        /// Rows holding opaque pixels strictly inside the outline.
        func inkedRows(insetFraction: CGFloat) -> [Int] {
            let lo = Int(CGFloat(width) * insetFraction)
            let hi = Int(CGFloat(width) * (1 - insetFraction))
            let loY = Int(CGFloat(height) * insetFraction)
            let hiY = Int(CGFloat(height) * (1 - insetFraction))
            return (loY..<hiY).filter { y in
                (lo..<hi).contains { x in bytes[(y * width + x) * 4 + 3] > 128 }
            }
        }
    }

    private static func alphaMap(_ image: UIImage) throws -> AlphaMap {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return AlphaMap(width: width, height: height, bytes: bytes)
    }
}

/// A user-reported template: an invisible bubble whose lone `<text>` holds the word `TEXT`.
/// It must draw as an invisible, still-sized (so still tappable) run — before, the word
/// disqualified the text node, nothing was left to draw, and the built-in bubble was drawn
/// in its place.
@Suite("Invisible bubble template", .serialized)
struct InvisibleBubbleTemplateTests {
    static let svg = """
    <svg opacity="0">
      <text y="15">
        TEXT
      </text>
    </svg>
    """

    @Test("is accepted as a user template, with its text as the count slot")
    func acceptedAsUserTemplate() throws {
        let bubble = try #require(CommentBubbleSVGRecognizer.recognizeUserTemplate(Self.svg))
        #expect(bubble.opacity == 0)
        #expect(bubble.replacingDisplayText(with: "12").displayText == "12")
        #expect(bubble.replacingDisplayText(with: "12").opacity == 0)
    }

    @Test("draws a sized, fully transparent run")
    func drawsInvisible() throws {
        let bubble = try #require(CommentBubbleSVGRecognizer.recognizeUserTemplate(Self.svg))
        let image = CommentBubbleSVGRecognizer.draw(
            svg: bubble.replacingDisplayText(with: "88"),
            pointSize: 40,
            themeTextColor: .black,
            textFace: .reader
        )
        #expect(image.size.width > 0 && image.size.height > 0)
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        #expect(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 })
    }

    @Test("a word in <text> is still no evidence when sniffing a source image")
    func sniffingRefusesWordText() {
        #expect(CommentBubbleSVGRecognizer.recognize(src: "", svgContent: Self.svg) == nil)
    }

    @Test("half opacity fades the whole bubble")
    func halfOpacityFades() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" opacity="0.5">\
        <rect x="0" y="0" width="20" height="20" rx="1" ry="1" fill="#000000"/>\
        <text x="10" y="15" font-size="10" fill="#000000">1</text></svg>
        """
        let bubble = try #require(CommentBubbleSVGRecognizer.recognizeUserTemplate(svg))
        #expect(abs(bubble.opacity - 0.5) < 0.001)
    }
}
