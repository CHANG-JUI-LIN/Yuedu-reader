import CoreText
import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

@MainActor
@Suite("HTML presentational hints", .serialized)
struct HTMLPresentationalHintTests {
    private static let contentWidth: CGFloat = 418

    @Test func imgPercentageWidthNormalizesAsTypedPercentage() {
        let hints = HTMLPresentationalHintExtractor.extract(
            from: HTMLSemanticElement(tagName: "IMG", attributes: ["WIDTH": " 15% "])
        )
        #expect(hints == [
            HTMLPresentationalHint(
                property: .width,
                value: .dimension(.percentage(0.15))
            )
        ])
    }

    @Test func imgIntegerWidthNormalizesAsCSSPixels() {
        let hints = HTMLPresentationalHintExtractor.extract(
            from: HTMLSemanticElement(tagName: "img", attributes: ["width": "100"])
        )
        #expect(hints == [
            HTMLPresentationalHint(
                property: .width,
                value: .dimension(.pixels(100))
            )
        ])
    }

    @Test func invalidDimensionsProduceNoHintAndNeverBecomeZero() {
        for raw in ["", "auto", "-1", "15px", "10%%", "nan", "20 30"] {
            let hints = HTMLPresentationalHintExtractor.extract(
                from: HTMLSemanticElement(tagName: "img", attributes: ["width": raw])
            )
            #expect(hints.isEmpty, "raw=\(raw)")
        }
        #expect(
            HTMLPresentationalHintExtractor.extract(
                from: HTMLSemanticElement(tagName: "img", attributes: ["width": "0"])
            ) == [
                HTMLPresentationalHint(
                    property: .width,
                    value: .dimension(.pixels(0))
                )
            ]
        )
        #expect(
            HTMLPresentationalHintExtractor.extract(
                from: HTMLSemanticElement(tagName: "img", attributes: ["height": "auto"])
            ).isEmpty
        )
    }

    @Test func nonImageDimensionAttributesStayOutsidePhase4F0Subset() {
        for tag in ["table", "td", "body", "svg"] {
            #expect(
                HTMLPresentationalHintExtractor.extract(
                    from: HTMLSemanticElement(tagName: tag, attributes: ["width": "15%"])
                ).isEmpty,
                "tag=\(tag)"
            )
        }
    }

    @Test func missingAndPresentDimensionsAreIndependentAndDeterministic() {
        let widthOnly = HTMLPresentationalHintExtractor.extract(
            from: HTMLSemanticElement(tagName: "img", attributes: ["width": "15%"])
        )
        let heightOnly = HTMLPresentationalHintExtractor.extract(
            from: HTMLSemanticElement(tagName: "img", attributes: ["height": "40"])
        )
        let bothInput = HTMLSemanticElement(
            tagName: "img",
            attributes: ["height": "40", "width": "100"]
        )
        let both = HTMLPresentationalHintExtractor.extract(from: bothInput)

        #expect(widthOnly.map(\.property) == [.width])
        #expect(heightOnly.map(\.property) == [.height])
        #expect(both.map(\.property) == [.width, .height])
        #expect(HTMLPresentationalHintExtractor.extract(from: bothInput) == both)
    }

    @Test func browserComputedStyleReceivesPercentageHint() throws {
        let root = try styleTree(
            html: "<html><body><img class='target' src='image.png' width='15%'></body></html>"
        )
        #expect(node(class: "target", in: root)?.style.width == .percent(0.15))
        #expect(node(class: "target", in: root)?.style.height == .auto)
    }

    @Test func browserAuthorCSSAndInlineStyleOverrideHintByNormalCascade() throws {
        let author = try styleTree(
            html: "<html><body><img class='hero' src='image.png' width='15%'></body></html>",
            css: [".hero { width:40% }"]
        )
        #expect(node(class: "hero", in: author)?.style.width == .percent(0.4))

        let inline = try styleTree(
            html: "<html><body><img class='hero' src='image.png' width='15%' style='width:30%'></body></html>",
            css: [".hero { width:40% }"]
        )
        #expect(node(class: "hero", in: inline)?.style.width == .percent(0.3))

        let important = try styleTree(
            html: "<html><body><img class='hero' src='image.png' width='15%' style='width:30%'></body></html>",
            css: [".hero { width:40% !important }"]
        )
        #expect(node(class: "hero", in: important)?.style.width == .percent(0.4))
    }

    @Test func browserWidthHintPreservesIntrinsicRatioAtUsedValueTime() async throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 800, height: 800),
            color: .red
        )
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            """
            <html><head><style>html, body, div { margin:0; padding:0 }</style></head>
            <body><div><img src="image.png" width="15%"></div></body></html>
            """,
            width: Self.contentWidth,
            height: 800,
            imageLoader: { $0 == "image.png" ? image : nil }
        )
        let fragment = try #require(BrowserLayoutTestSupport.allImageFragments(pages).first)
        #expect(abs(fragment.rect.width - 62.7) < 0.05)
        #expect(abs(fragment.rect.height - 62.7) < 0.05)
    }

    @Test func browserHeightOnlyPreservesIntrinsicRatio() async throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 200, height: 100),
            color: .green
        )
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            "<html><body><img src='image.png' height='40'></body></html>",
            width: Self.contentWidth,
            height: 400,
            imageLoader: { _ in image }
        )
        let fragment = try #require(BrowserLayoutTestSupport.allImageFragments(pages).first)
        #expect(abs(fragment.rect.width - 80) < 0.01)
        #expect(abs(fragment.rect.height - 40) < 0.01)
    }

    @Test func browserWidthAndHeightHintsSetBothUsedDimensions() async throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 200, height: 100),
            color: .blue
        )
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            "<html><body><img src='image.png' width='100' height='80'></body></html>",
            width: Self.contentWidth,
            height: 400,
            imageLoader: { _ in image }
        )
        let fragment = try #require(BrowserLayoutTestSupport.allImageFragments(pages).first)
        #expect(abs(fragment.rect.width - 100) < 0.01)
        #expect(abs(fragment.rect.height - 80) < 0.01)
    }

    @Test func centeredParentPlacesHintSizedImageWithoutImageSpecificAlignment() async throws {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 800, height: 800),
            color: .purple
        )
        let (pages, _) = try await BrowserLayoutTestSupport.layout(
            """
            <html><head><style>
            html, body, div { margin:0; padding:0 }
            .center { text-align:center }
            </style></head><body>
            <div class="center"><img src="image.png" width="15%"></div>
            </body></html>
            """,
            width: Self.contentWidth,
            height: 800,
            imageLoader: { _ in image }
        )
        let fragment = try #require(BrowserLayoutTestSupport.allImageFragments(pages).first)
        #expect(abs(fragment.rect.width - 62.7) < 0.05)
        #expect(abs(fragment.rect.minX - (Self.contentWidth - 62.7) / 2) < 0.1)
    }

    @Test func legacyReceivesHintAndAuthorCSSStillWins() async throws {
        let hint = try await legacyImageRun(widthAttribute: "15%")
        #expect(abs(hint.drawWidth - 62.7) < 0.05)
        #expect(abs(hint.drawHeight - 62.7) < 0.05)

        let author = try await legacyImageRun(
            widthAttribute: "15%",
            css: ".hero { width:40% }"
        )
        #expect(abs(author.drawWidth - 167.2) < 0.05)

        let inline = try await legacyImageRun(
            widthAttribute: "15%",
            css: ".hero { width:40% }",
            inlineStyle: "width:30%"
        )
        #expect(abs(inline.drawWidth - 125.4) < 0.05)

        let authorPixels = try await legacyImageRun(
            widthAttribute: "15%",
            css: ".hero { width:100px }"
        )
        #expect(abs(authorPixels.drawWidth - 100) < 0.05)

        let authorAuto = try await legacyImageRun(
            widthAttribute: "15%",
            css: ".hero { width:auto }"
        )
        #expect(abs(authorAuto.drawWidth - Self.contentWidth) < 0.05)
    }

    @Test func repeatedBrowserCascadeAndGeometryAreDeterministic() async throws {
        let html = "<html><body><img class='target' src='image.png' width='15%'></body></html>"
        let firstTree = try styleTree(html: html)
        let secondTree = try styleTree(html: html)
        #expect(node(class: "target", in: firstTree)?.style == node(class: "target", in: secondTree)?.style)

        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 800, height: 800),
            color: .orange
        )
        let first = try await BrowserLayoutTestSupport.layout(
            html,
            width: Self.contentWidth,
            imageLoader: { _ in image }
        )
        let second = try await BrowserLayoutTestSupport.layout(
            html,
            width: Self.contentWidth,
            imageLoader: { _ in image }
        )
        #expect(BrowserLayoutTestSupport.allImageFragments(first.pages).map(\.rect)
            == BrowserLayoutTestSupport.allImageFragments(second.pages).map(\.rect))
    }

    private func styleTree(html: String, css: [String] = []) throws -> ComputedStyleNode {
        var metrics = LayoutMetrics()
        return try LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: BrowserLayoutConfig(renderWidth: Self.contentWidth),
            metrics: &metrics
        ).rootNode
    }

    private func node(class className: String, in root: ComputedStyleNode) -> ComputedStyleNode? {
        let classes = root.element.flatMap { try? $0.classNames() } ?? []
        if classes.contains(className) { return root }
        for child in root.children {
            guard case .element(let childNode) = child else { continue }
            if let match = node(class: className, in: childNode) { return match }
        }
        return nil
    }

    private func legacyImageRun(
        widthAttribute: String,
        css: String = "",
        inlineStyle: String = ""
    ) async throws -> ImageRunInfo {
        let image = BrowserLayoutTestSupport.makeImage(
            size: CGSize(width: 800, height: 800),
            color: .red
        )
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let styleAttribute = inlineStyle.isEmpty ? "" : " style='\(inlineStyle)'"
        let result = await builder.build(
            html: """
            <html><head><style>\(css)</style></head><body>
            <p>before</p><div><img class="hero" src="image.png" width="\(widthAttribute)"\(styleAttribute)></div>
            </body></html>
            """,
            config: EPUBTestFixtures.htmlConfig(renderWidth: Self.contentWidth)
        )
        return try #require(EPUBTestFixtures.imageRunInfos(in: result.attributedString).first?.info)
    }
}
