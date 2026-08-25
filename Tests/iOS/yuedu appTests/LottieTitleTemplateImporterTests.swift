import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Lottie title template importer", .serialized)
struct LottieTitleTemplateImporterTests {

    // MARK: - Detection

    @Test("recognizes a Bodymovin document and leaves other JSON alone")
    func detectsTitleTemplates() throws {
        #expect(LottieTitleTemplateImporter.looksLikeTitleTemplate(try fixtureData()))
        #expect(!LottieTitleTemplateImporter.looksLikeTitleTemplate(
            Data(#"{ "textSize": 18, "paddingLeft": 20 }"#.utf8)
        ))
        // The dialogue-bubble scripts shipped in the same folder as these
        // templates: same origin, completely different format.
        #expect(!LottieTitleTemplateImporter.looksLikeTitleTemplate(
            Data(#"{ "name": "氣泡對話", "script": "function process(ctx){}" }"#.utf8)
        ))
        #expect(!LottieTitleTemplateImporter.looksLikeTitleTemplate(Data("not json".utf8)))
    }

    // MARK: - Conversion

    @Test("converts a static template into a chapter title design")
    func convertsStaticTemplate() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let design = try #require(result.style.design)

        #expect(result.style.advancedCSSEnabled)
        #expect(result.style.visible)
        #expect(result.templateName == "測試模板")
        // 2000 × 800 template against the 340pt reference column.
        #expect(abs(design.canvasAspectRatio - 2.5) < 0.0001)
        #expect(abs(design.canvasHeight - 136) < 0.0001)
        #expect(design.layers.count == 3)
    }

    @Test("paints by Lottie layer index, not array order")
    func ordersLayersByIndex() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let design = try #require(result.style.design)

        // Source array is [image(ind 10), s1(ind 8), s2(ind 9)]; the background
        // image has the highest index, so it must be drawn first.
        #expect(design.layers.map(\.kind) == [.image, .chapterName, .chapterNumber])
    }

    @Test("maps the editor's ${s1}/${s2} slots onto the number and name")
    func mapsTitleSlots() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let design = try #require(result.style.design)
        let number = try #require(design.layers.first { $0.kind == .chapterNumber })
        let name = try #require(design.layers.first { $0.kind == .chapterName })

        #expect(number.content == .dynamic(.number))
        #expect(name.content == .dynamic(.name))
    }

    @Test("scales point text against the reference column and keeps its baseline")
    func convertsPointText() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let design = try #require(result.style.design)
        let number = try #require(design.layers.first { $0.kind == .chapterNumber })
        let text = number.lightStyle.ruleStyle.text

        // 100px text on a 2000px canvas → 17pt on the 340pt reference column.
        #expect(abs((text.fontSize ?? 0) - 17) < 0.0001)
        #expect(abs((text.lineHeight ?? 0) - 20.4) < 0.0001)
        #expect(text.colorHex == 0x1A1A1A)
        #expect(number.lightStyle.textAlignment == .center)
        // Baseline 300px with a 75% ascent puts the box top at 225px of 800.
        #expect(abs(number.frame.y - 0.28125) < 0.0001)
        #expect(abs(number.frame.height - 0.15) < 0.0001)
        // Centred point text keeps its anchor: the box is symmetric around it.
        #expect(abs(number.frame.x - 0) < 0.0001)
        #expect(abs(number.frame.width - 1) < 0.0001)
    }

    @Test("keeps an installed font and falls back with a note otherwise")
    func reportsMissingFonts() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let design = try #require(result.style.design)
        let number = try #require(design.layers.first { $0.kind == .chapterNumber })
        let name = try #require(design.layers.first { $0.kind == .chapterName })

        #expect(number.lightStyle.ruleStyle.text.fontPostScriptName == "Helvetica")
        #expect(name.lightStyle.ruleStyle.text.fontPostScriptName == nil)
        #expect(result.notes.contains { $0.contains("Microsoft YaHei") })
    }

    @Test("stores the embedded image once and aspect-fills its frame")
    func storesEmbeddedImage() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try fixtureData(),
            assetStore: store
        )
        let design = try #require(result.style.design)
        let image = try #require(design.layers.first { $0.kind == .image })
        let presentation = try #require(image.lightStyle.imagePresentation)

        #expect(await store.assets().count == 1)
        #expect(result.importedAssetIDs.count == 1)
        #expect(image.content == .image(presentation.assetID))
        #expect(presentation.contentMode == .fill)
        // p (1000,400) − a (200,100) at 100% → a 400×200 box at (800,300).
        #expect(abs(image.frame.x - 0.4) < 0.0001)
        #expect(abs(image.frame.y - 0.375) < 0.0001)
        #expect(abs(image.frame.width - 0.2) < 0.0001)
        #expect(abs(image.frame.height - 0.25) < 0.0001)
    }

    // MARK: - Refusals

    @Test("refuses an animated template instead of freezing it")
    func refusesAnimatedTemplate() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        var document = try fixture()
        var layers = try #require(document["layers"] as? [[String: Any]])
        layers[0]["ks"] = [
            "o": ["a": 1, "k": [["t": 0, "s": [0]], ["t": 30, "s": [100]]]],
            "p": ["a": 0, "k": [1_000, 400, 0]],
            "a": ["a": 0, "k": [200, 100, 0]],
            "s": ["a": 0, "k": [100, 100, 100]],
        ]
        document["layers"] = layers
        let data = try JSONSerialization.data(withJSONObject: document)

        await #expect(throws: LottieTitleTemplateImportError.animatedTemplate) {
            try await LottieTitleTemplateImporter.import(data, assetStore: store)
        }
    }

    @Test("refuses a template with nothing convertible in it")
    func refusesEmptyTemplate() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        var document = try fixture()
        document["layers"] = [["ty": 4, "ind": 1, "nm": "shape", "ks": [:]]]
        let data = try JSONSerialization.data(withJSONObject: document)

        await #expect(throws: LottieTitleTemplateImportError.noSupportedLayers) {
            try await LottieTitleTemplateImporter.import(data, assetStore: store)
        }
    }

    // MARK: - Fixture

    /// A three-layer template shaped like the ones the xTitleEditor exports:
    /// one embedded background image plus the `${s1}` / `${s2}` title slots.
    private func fixture() throws -> [String: Any] {
        let png = try #require(UIImage(systemName: "star")?.pngData())
        return [
            "v": "5.9.0",
            "fr": 30,
            "ip": 0,
            "op": 162,
            "w": 2_000,
            "h": 800,
            "nm": "測試模板",
            "assets": [
                [
                    "id": "image_0",
                    "w": 400,
                    "h": 200,
                    "u": "",
                    "p": "data:image/png;base64," + png.base64EncodedString(),
                    "e": 1,
                ],
            ],
            "layers": [
                [
                    "ty": 2,
                    "ind": 10,
                    "nm": "背景",
                    "refId": "image_0",
                    "ks": [
                        "o": ["a": 0, "k": 100],
                        "r": ["a": 0, "k": 0],
                        "p": ["a": 0, "k": [1_000, 400, 0]],
                        "a": ["a": 0, "k": [200, 100, 0]],
                        "s": ["a": 0, "k": [100, 100, 100]],
                    ],
                ],
                textLayer(index: 8, name: "s1", token: "${s1}", font: "XTE-Installed", y: 300),
                textLayer(index: 9, name: "s2", token: "${s2}", font: "XTE-Missing", y: 560),
            ],
            "fonts": [
                "list": [
                    [
                        "fName": "XTE-Installed",
                        "fFamily": "Helvetica",
                        "fStyle": "Regular",
                        "ascent": 75,
                    ],
                    [
                        "fName": "XTE-Missing",
                        "fFamily": "Microsoft YaHei",
                        "fStyle": "Regular",
                        "ascent": 75,
                    ],
                ],
            ],
        ]
    }

    private func textLayer(
        index: Int,
        name: String,
        token: String,
        font: String,
        y: Double
    ) -> [String: Any] {
        [
            "ty": 5,
            "ind": index,
            "nm": name,
            "ks": [
                "o": ["a": 0, "k": 100],
                "r": ["a": 0, "k": 0],
                "p": ["a": 0, "k": [1_000, y, 0]],
                "a": ["a": 0, "k": [0, 0, 0]],
                "s": ["a": 0, "k": [100, 100, 100]],
            ],
            "t": [
                "d": [
                    "k": [
                        [
                            "s": [
                                "s": 100,
                                "f": font,
                                "t": token,
                                "j": 2,
                                "tr": 0,
                                "lh": 120,
                                "ls": 0,
                                "fc": [0.1, 0.1, 0.1, 1],
                            ],
                            "t": 0,
                        ],
                    ],
                ],
                "p": [:],
                "a": [],
            ],
        ]
    }

    private func fixtureData() throws -> Data {
        try JSONSerialization.data(withJSONObject: try fixture())
    }
}
