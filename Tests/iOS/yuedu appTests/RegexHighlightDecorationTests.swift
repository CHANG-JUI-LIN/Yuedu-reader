import CoreGraphics
import Testing
@testable import yuedu_app

@Suite("Regex highlight decoration")
struct RegexHighlightDecorationTests {
    @Test("horizontal padding expands glyph rect in every direction")
    func horizontalPadding() {
        let rect = RegexHighlightDecorationGeometry.expandedRect(
            glyphRect: CGRect(x: 10, y: 20, width: 30, height: 12),
            padding: .init(top: 2, leading: 3, bottom: 4, trailing: 5),
            writingMode: .horizontal
        )

        #expect(rect == CGRect(x: 7, y: 18, width: 38, height: 18))
    }

    @Test("vertical leading and trailing map to the inline column direction")
    func verticalPadding() {
        let rect = RegexHighlightDecorationGeometry.expandedRect(
            glyphRect: CGRect(x: 100, y: 40, width: 18, height: 30),
            padding: .init(top: 2, leading: 3, bottom: 4, trailing: 5),
            writingMode: .verticalRTL
        )

        #expect(rect == CGRect(x: 96, y: 37, width: 24, height: 38))
    }

    @Test("image destination honors fit fill and stretch")
    func imageModes() {
        let source = CGSize(width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        #expect(
            RegexHighlightImageGeometry.destination(
                source: source,
                bounds: bounds,
                mode: .fit
            ) == CGRect(x: 0, y: 25, width: 100, height: 50)
        )
        #expect(
            RegexHighlightImageGeometry.destination(
                source: source,
                bounds: bounds,
                mode: .fill
            ) == CGRect(x: -50, y: 0, width: 200, height: 100)
        )
        #expect(
            RegexHighlightImageGeometry.destination(
                source: source,
                bounds: bounds,
                mode: .stretch
            ) == bounds
        )
        #expect(
            RegexHighlightImageGeometry.destination(
                source: CGSize(width: 20, height: 10),
                bounds: bounds,
                mode: .tile,
                focalX: 0.5,
                focalY: 0.5
            ) == CGRect(x: 40, y: 45, width: 20, height: 10)
        )
    }

    @Test("image focal point positions aspect fill overflow")
    func imageFocalPoint() {
        let destination = RegexHighlightImageGeometry.destination(
            source: CGSize(width: 200, height: 100),
            bounds: CGRect(x: 20, y: 30, width: 100, height: 100),
            mode: .fill,
            focalX: 1,
            focalY: 0
        )

        #expect(destination == CGRect(x: -80, y: 30, width: 200, height: 100))
    }

    @Test("visual gap shrinks only touching inline edges")
    func visualGap() {
        let rect = RegexHighlightDecorationGeometry.applyingInlineGap(
            to: CGRect(x: 10, y: 20, width: 40, height: 12),
            gap: 6,
            hasPreviousFragment: true,
            hasNextFragment: true,
            writingMode: .horizontal
        )

        #expect(rect == CGRect(x: 13, y: 20, width: 34, height: 12))
    }
}
