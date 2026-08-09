import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader style CSS codec")
struct ReaderStyleCSSCodecTests {
    @Test("appearance values resolve independently")
    func appearanceResolution() {
        let value = ReaderStyleAppearanceValue(light: 0x112233, dark: 0xAABBCC)
        #expect(value.resolve(for: .light) == 0x112233)
        #expect(value.resolve(for: .dark) == 0xAABBCC)
    }

    @Test("supported declaration block round trips canonically")
    func supportedRoundTrip() throws {
        let source = "color:#112233; padding:4px 8px; border-radius:6px; opacity:0.75"
        let style = try ReaderStyleCSSCodec.decodeDeclarations(source, context: .regexHighlight)
        let encoded = ReaderStyleCSSCodec.encodeDeclarations(style, context: .regexHighlight)

        #expect(encoded == "color: #112233; padding: 4px 8px; border-radius: 6px; opacity: 0.75;")
    }

    @Test("unsupported properties report source coordinates")
    func rejectsUnsupportedProperty() {
        #expect(throws: ReaderStyleCSSCodecError.unsupportedProperty(
            name: "display", line: 2, column: 1
        )) {
            try ReaderStyleCSSCodec.decodeDeclarations(
                "color: #fff;\ndisplay: grid;",
                context: .regexHighlight
            )
        }
    }

    @Test("managed image declarations decode without accepting external URLs")
    func managedImageDeclarations() throws {
        let assetID = readerStyleFixtureUUID(7)
        let source = """
        background-image: url(yuedu-asset://\(assetID.uuidString));
        background-size: contain;
        background-position: 25% 75%;
        background-repeat: no-repeat;
        """

        let style = try ReaderStyleCSSCodec.decodeDeclarations(source, context: .regexHighlight)
        let image = try #require(style.decoration.backgroundImage)

        #expect(image.assetID == assetID)
        #expect(image.contentMode == .fit)
        #expect(image.focalX == 0.25)
        #expect(image.focalY == 0.75)
    }

    @Test("linear gradients decode into structured stops")
    func linearGradient() throws {
        let style = try ReaderStyleCSSCodec.decodeDeclarations(
            "background-image: linear-gradient(90deg, #112233 0%, #AABBCC 100%);",
            context: .chapterLayer
        )
        let gradient = try #require(style.decoration.backgroundGradient)

        #expect(gradient.angleDegrees == 90)
        #expect(gradient.stops == [
            ReaderStyleGradientStop(colorHex: 0x112233, location: 0),
            ReaderStyleGradientStop(colorHex: 0xAABBCC, location: 1)
        ])
    }

    @Test("remote background resources are rejected")
    func rejectsRemoteResource() {
        #expect(throws: ReaderStyleCSSCodecError.invalidValue(
            property: "background-image",
            value: "url(https://example.com/background.png)",
            line: 1,
            column: 1
        )) {
            try ReaderStyleCSSCodec.decodeDeclarations(
                "background-image: url(https://example.com/background.png);",
                context: .regexHighlight
            )
        }
    }

    @Test("contrast evaluator reports but does not reject low contrast")
    func contrastWarning() {
        let warning = ReaderStyleContrastEvaluator.warning(
            foregroundHex: 0x777777,
            backgroundHex: 0x787878
        )
        #expect(warning != nil)
        #expect(warning?.isBlocking == false)
    }
}
