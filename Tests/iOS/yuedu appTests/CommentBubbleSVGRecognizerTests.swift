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
}
