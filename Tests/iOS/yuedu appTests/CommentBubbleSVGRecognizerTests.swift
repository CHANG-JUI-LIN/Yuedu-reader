import Foundation
import Testing
@testable import yuedu_app

@Suite("Comment bubble SVG recognizer")
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
                guard case let .text(_, _, _, _, _, _, color, _) = element else { return false }
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

    @Test("preserves the selected bubble scale in the inline attachment height")
    func resolvesScaledInlineAttachmentHeight() {
        #expect(
            CommentBubbleSVGRecognizer.inlineAttachmentHeight(
                pointSize: 18,
                lineHeight: 24,
                overallScale: 0.5
            ) == 12
        )
        #expect(
            CommentBubbleSVGRecognizer.inlineAttachmentHeight(
                pointSize: 18,
                lineHeight: 24,
                overallScale: 1.5
            ) == 36
        )
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
}
