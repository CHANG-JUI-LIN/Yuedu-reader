import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Dialogue bubble script importer", .serialized)
struct DialogueBubbleScriptImporterTests {

    @Test("recognizes a bubble script and leaves other JSON alone")
    func detectsBubbleScripts() throws {
        #expect(DialogueBubbleScriptImporter.looksLikeBubbleScript(try fixtureData()))
        #expect(!DialogueBubbleScriptImporter.looksLikeBubbleScript(
            Data(#"{ "name": "書源", "bookSourceUrl": "https://example.com" }"#.utf8)
        ))
        #expect(!DialogueBubbleScriptImporter.looksLikeBubbleScript(
            Data(#"{ "textSize": 18 }"#.utf8)
        ))
    }

    /// `CONFIG` is a local inside `process`, so it has to be lifted out of the
    /// source text — past comments and past braces that live inside strings.
    @Test("lifts the CONFIG literal past comments and braces in strings")
    func extractsConfigLiteral() throws {
        let script = """
        function process(ctx) {
            /* a comment with a { brace */
            var CONFIG = {
                // line comment with }
                "note": "a string with } and { inside",
                "layout": { "canvasWidth": 1080 }
            };
            return "";
        }
        """
        let literal = try #require(DialogueBubbleScriptImporter.configLiteral(in: script))

        #expect(literal.hasPrefix("{"))
        #expect(literal.hasSuffix("}"))
        #expect(literal.contains("canvasWidth"))
        #expect(!literal.contains("return"))
    }

    @Test("converts script pixels into column ratios and em multiples")
    func convertsMetrics() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await DialogueBubbleScriptImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let style = result.style

        #expect(style.isEnabled)
        #expect(result.name == "氣泡對話")
        #expect(style.startSide == .right)
        // 760 of a 1080 canvas, 36 of 1080, then 32/24/10 against the 66px
        // dialogue font the script lays out with.
        #expect(abs(style.maxWidthRatio - 760.0 / 1_080) < 0.0001)
        #expect(abs(style.sideInsetRatio - 36.0 / 1_080) < 0.0001)
        #expect(abs(style.horizontalPaddingEm - 32.0 / 66) < 0.0001)
        #expect(abs(style.verticalPaddingEm - 24.0 / 66) < 0.0001)
        #expect(abs(style.spacingEm - 20.0 / 66) < 0.0001)
        #expect(style.removesQuotes)
        #expect(style.mergesAdjacent)
    }

    @Test("maps colors, borders and tails per side")
    func convertsSides() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await DialogueBubbleScriptImporter.import(
            try fixtureData(),
            assetStore: store
        )

        #expect(result.style.right.fillHex == 0x95EC69)
        #expect(result.style.right.textHex == 0x182012)
        #expect(result.style.right.borderHex == 0x78CF50)
        #expect(abs(result.style.right.cornerRadiusEm - 28.0 / 66) < 0.0001)
        #expect(abs(result.style.right.borderWidthEm - 2.0 / 66) < 0.0001)
        let tail = try #require(result.style.right.tail)
        #expect(abs(tail.widthEm - 32.0 / 66) < 0.0001)
        #expect(abs(tail.heightEm - 22.0 / 66) < 0.0001)
        #expect(abs(tail.outsideEm - 8.0 / 66) < 0.0001)
        #expect(abs(tail.bottomOffsetEm - 13.0 / 66) < 0.0001)
        // The right side is a plain drawn bubble in this fixture.
        #expect(result.style.right.skin == nil)
    }

    @Test("stores a nine-slice skin and keeps its source slices")
    func importsSkin() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await DialogueBubbleScriptImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let skin = try #require(result.style.left.skin)

        #expect(result.importedAssetIDs == [skin.assetID])
        #expect(await store.assets().count == 1)
        #expect(skin.sliceTop == 42)
        #expect(skin.sliceLeft == 135)
        // The script's own factors, kept as factors: the skin is scaled against
        // one line of text at draw time, not against a fixed canvas.
        #expect(abs(skin.cornerScale - 0.4138) < 0.0001)
        #expect(abs(skin.targetHeightScale - 1) < 0.0001)
    }

    /// The one thing an imported style deliberately drops: the script's own text
    /// metrics. Native bubbles follow the reader's font, which is the whole
    /// reason for importing the settings instead of running the script.
    @Test("reports that the script's text metrics are not carried over")
    func reportsTextMetricNote() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await DialogueBubbleScriptImporter.import(
            try fixtureData(),
            assetStore: store
        )

        // Compared through `localized` rather than against the Chinese source
        // string: the test bundle resolves notes in the simulator's language.
        #expect(result.notes.contains(
            localized("氣泡文字改用閱讀字級，腳本裡的字級、行高與字距不會沿用。")
        ))
    }

    @Test("refuses a script with no readable settings block")
    func refusesScriptWithoutConfig() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let data = try JSONSerialization.data(withJSONObject: [
            "name": "無設定",
            "script": "function process(ctx) { return CONFIG; }",
        ])

        await #expect(throws: DialogueBubbleScriptImportError.configNotFound) {
            try await DialogueBubbleScriptImporter.import(data, assetStore: store)
        }
    }

    // MARK: - Fixture

    private func fixtureData() throws -> Data {
        let png = try #require(UIImage(systemName: "message.fill")?.pngData())
        let script = """
        function process(ctx) {
            /*
             * 參數控制台 { 這裡有括號 }
             */
            var CONFIG = {
                layout: {
                    "canvasWidth": 1080,
                    "leftScreenMargin": 36,
                    "rightScreenMargin": 36,
                    "leftBubbleMaxWidth": 760,
                    "rightBubbleMaxWidth": 760,
                    "leftBubblePaddingX": 32,
                    "rightBubblePaddingX": 32,
                    "leftBubblePaddingY": 24,
                    "rightBubblePaddingY": 24,
                    "canvasPaddingY": 10
                },
                text: {
                    "left": { "fontSize": 66, "lineHeight": 82 },
                    "right": { "fontSize": 66, "lineHeight": 82 }
                },
                colors: {
                    "leftBubble": "#f1f2f4",
                    "leftText": "#182012",
                    "leftBorder": "#d6d7da",
                    "rightBubble": "#95ec69",
                    "rightText": "#182012",
                    "rightBorder": "#78cf50"
                },
                behavior: {
                    "startSide": "right",
                    "mergeAdjacentDialogues": true,
                    "removeOuterQuotes": true
                },
                bubbleType: { "left": "image", "right": "native" },
                nativeBubble: {
                    "left": {
                        "radius": 28, "borderWidth": 2, "tailEnabled": true,
                        "tailOutside": 8, "tailBottomOffset": 13,
                        "tailWidth": 32, "tailHeight": 22
                    },
                    "right": {
                        "radius": 28, "borderWidth": 2, "tailEnabled": true,
                        "tailOutside": 8, "tailBottomOffset": 13,
                        "tailWidth": 32, "tailHeight": 22
                    }
                },
                imageSkin: {
                    "left": {
                        "mode": "nineSlice",
                        "dataUri": "data:image/png;base64,\(png.base64EncodedString())",
                        "sourceWidth": 282,
                        "sourceHeight": 96,
                        "opacity": 1,
                        "sliceTop": 42,
                        "sliceRight": 135,
                        "sliceBottom": 42,
                        "sliceLeft": 135,
                        "sliceUnit": "px",
                        "cornerScale": 41.38
                    },
                    "right": { "mode": "nineSlice" }
                }
            };
            return "";
        }
        """
        return try JSONSerialization.data(withJSONObject: [
            "id": 108,
            "name": "氣泡對話",
            "order": 26,
            "timeoutMillisecond": 3_000,
            "enabledCookieJar": false,
            "script": script,
        ])
    }
}
