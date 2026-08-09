import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter title design")
struct ChapterTitleDesignTests {
    @Test("default design contains number and name layers")
    func defaultLayers() {
        #expect(ChapterTitleDesign.default.layers.map(\.kind) == [.chapterNumber, .chapterName])
        #expect(ChapterTitleDesign.default.layers.map(\.content) == [
            .dynamic(.number),
            .dynamic(.name),
        ])
    }

    @Test("vertical transform swaps normalized axes without changing layer order")
    func verticalTransform() {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let first = ChapterTitleLayer(
            id: firstID,
            name: "Title",
            kind: .chapterName,
            frame: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            rotation: .init(degrees: 23),
            isVisible: true,
            isLocked: false,
            content: .dynamic(.name),
            lightStyle: .init(),
            darkStyle: .init()
        )
        let second = ChapterTitleLayer(
            id: secondID,
            name: "Image",
            kind: .image,
            frame: .init(x: 0.2, y: 0.1, width: 0.5, height: 0.2),
            rotation: .init(degrees: -17),
            isVisible: true,
            isLocked: true,
            content: .image(UUID()),
            lightStyle: .init(),
            darkStyle: .init()
        )

        let vertical = ChapterTitleDesign(layers: [first, second]).resolved(for: .verticalRTL)

        #expect(vertical.layers.map(\.id) == [firstID, secondID])
        #expect(vertical.layers[0].frame == .init(x: 0.4, y: 0.1, width: 0.4, height: 0.3))
        #expect(vertical.layers[0].rotation == first.rotation)
        #expect(vertical.layers[1].rotation == second.rotation)
        #expect(vertical.layers[0].lightStyle.writingDirection == .vertical)
        #expect(vertical.layers[0].darkStyle.writingDirection == .vertical)
        #expect(vertical.canvasAspectRatio == 1 / 2.4)
    }

    @Test("horizontal resolution only sanitizes the design")
    func horizontalResolution() {
        var layer = ChapterTitleDesign.default.layers[0]
        layer.lightStyle.writingDirection = .vertical
        layer.darkStyle.writingDirection = .vertical

        let horizontal = ChapterTitleDesign(layers: [layer]).resolved(for: .horizontal)

        #expect(horizontal.layers[0].frame == layer.frame)
        #expect(horizontal.layers[0].lightStyle.writingDirection == .horizontal)
        #expect(horizontal.layers[0].darkStyle.writingDirection == .horizontal)
    }

    @Test("sanitization clamps every nested numeric style value")
    func sanitization() {
        var frame = ReaderStyleNormalizedRect(x: 0, y: 0, width: 1, height: 1)
        frame.x = -.infinity
        frame.y = 0.8
        frame.width = .infinity
        frame.height = 0.7

        var text = ReaderStyleTextStyle()
        text.fontSize = .infinity
        text.fontWeight = 10_000
        text.letterSpacing = -.infinity
        text.lineHeight = -20

        var padding = ReaderStyleEdges()
        padding.top = .infinity
        padding.leading = -100_000

        var border = ReaderStyleBorder()
        border.width = .infinity
        border.colorHex = 0xFFABCDEF

        var shadow = ReaderStyleShadow(colorHex: 0, radius: 0, x: 0, y: 0)
        shadow.radius = .nan
        shadow.x = .infinity
        shadow.y = -100_000

        var image = ReaderStyleImagePresentation(assetID: UUID())
        image.focalX = .infinity
        image.focalY = -.infinity
        image.opacity = 50

        var decoration = ReaderStyleDecorationStyle()
        decoration.padding = padding
        decoration.borders = [.top: border]
        decoration.cornerRadius = .infinity
        decoration.shadows = [shadow]
        decoration.opacity = -1
        decoration.backgroundImage = image

        var line = ChapterTitleLineStyle(width: 1, colorHex: 0, isDashed: false)
        line.width = .infinity
        line.colorHex = 0xFF123456

        let layer = ChapterTitleLayer(
            id: UUID(),
            name: "Invalid",
            kind: .line,
            frame: frame,
            rotation: .init(degrees: 0),
            isVisible: true,
            isLocked: false,
            content: .line(line),
            lightStyle: ChapterTitleLayerStyle(
                ruleStyle: .init(text: text, decoration: decoration),
                imagePresentation: image
            ),
            darkStyle: .init()
        )

        var design = ChapterTitleDesign(
            canvasAspectRatio: .nan,
            canvasHeight: .infinity,
            layers: [layer]
        )
        design.canvasHeight = .infinity
        let sanitized = design.sanitized()
        let result = sanitized.layers[0]

        #expect(sanitized.canvasAspectRatio == ChapterTitleDesign.defaultCanvasAspectRatio)
        #expect(sanitized.canvasHeight == ChapterTitleDesign.defaultCanvasHeight)
        #expect(result.frame.x == 0)
        #expect(result.frame.width == 0.1)
        #expect(result.frame.y + result.frame.height == 1)
        #expect(result.lightStyle.ruleStyle.text.fontSize == nil)
        #expect(result.lightStyle.ruleStyle.text.fontWeight == 1_000)
        #expect(result.lightStyle.ruleStyle.text.letterSpacing == nil)
        #expect(result.lightStyle.ruleStyle.text.lineHeight == 0)
        #expect(result.lightStyle.ruleStyle.decoration.padding?.top == 0)
        #expect(result.lightStyle.ruleStyle.decoration.padding?.leading == -2_048)
        #expect(result.lightStyle.ruleStyle.decoration.borders?[.top]?.width == 0)
        #expect(result.lightStyle.ruleStyle.decoration.borders?[.top]?.colorHex == 0xABCDEF)
        #expect(result.lightStyle.ruleStyle.decoration.cornerRadius == nil)
        #expect(result.lightStyle.ruleStyle.decoration.shadows[0].radius == 0)
        #expect(result.lightStyle.ruleStyle.decoration.shadows[0].x == 0)
        #expect(result.lightStyle.ruleStyle.decoration.shadows[0].y == -2_048)
        #expect(result.lightStyle.ruleStyle.decoration.opacity == 0)
        #expect(result.lightStyle.imagePresentation?.focalX == 0.5)
        #expect(result.lightStyle.imagePresentation?.focalY == 0.5)
        #expect(result.lightStyle.imagePresentation?.opacity == 1)
        #expect(result.content == .line(.init(width: 0, colorHex: 0x123456, isDashed: false)))
    }

    @Test("legacy templates decode into a source-backed design")
    func legacyMigration() throws {
        let data = Data(#"{"advancedCSSEnabled":true,"lightTemplate":"<div>{number}<span>{name}</span></div>","darkTemplate":"<div>{number}<span>{name}</span></div>"}"#.utf8)
        let decoded = try JSONDecoder().decode(ChapterTitleStyle.self, from: data)

        #expect(decoded.design?.legacySource?.light.contains("{number}") == true)
        #expect(decoded.design?.legacySource?.dark.isEmpty == false)
        #expect(decoded.design?.layers.isEmpty == true)
        #expect(decoded.visible == ChapterTitleStyle.default.visible)
        #expect(decoded.size == ChapterTitleStyle.default.size)
        #expect(decoded.weight == ChapterTitleStyle.default.weight)
    }

    @Test("existing complete JSON remains byte-semantically round-trippable")
    func existingStyleRoundTrip() throws {
        var original = ChapterTitleStyle.default
        original.visible = false
        original.size = 31
        original.topSpacing = 9
        original.bottomSpacing = 27
        original.weight = .medium
        original.alignment = .right
        original.followsBodyFont = false
        original.splitEnabled = true
        original.numberRelativeSize = 0.72
        original.numberFontPostScript = "NumberFont"
        original.nameFontPostScript = "NameFont"
        original.advancedCSSEnabled = false
        original.lightTemplate = "<div>{number}</div>"
        original.darkTemplate = "<div>{name}</div>"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChapterTitleStyle.self, from: data)

        #expect(decoded == original)
        #expect(decoded.design == nil)
    }

    @Test("new structured design round trips without creating legacy source")
    func structuredDesignRoundTrip() throws {
        var original = ChapterTitleStyle.default
        original.advancedCSSEnabled = true
        original.design = .default

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChapterTitleStyle.self, from: data)

        #expect(decoded == original)
        #expect(decoded.design?.legacySource == nil)
    }
}
