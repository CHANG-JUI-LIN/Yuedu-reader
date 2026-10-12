import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Synthetic packs shaped like the real ones (Reeden 对话高亮 十字架, QiReader 高透绿): the
/// same fields, nine-slice syntax and layouts, with generated artwork.
enum HighlightPackFixtures {
    static let imageSize = CGSize(width: 504, height: 173)

    static func png(size: CGSize = imageSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A gzip member with stored (uncompressed) DEFLATE blocks — valid gzip any inflater
    /// reads, without needing a compressor in the test target.
    static func gzip(_ payload: Data) -> Data {
        var data = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        let bytes = [UInt8](payload)
        var offset = 0
        repeat {
            let length = min(65_535, bytes.count - offset)
            let isLast = offset + length >= bytes.count
            data.append(isLast ? 1 : 0)
            data.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8)])
            data.append(contentsOf: [UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)])
            data.append(contentsOf: bytes[offset ..< offset + length])
            offset += length
        } while offset < bytes.count
        for value in [crc32(bytes), UInt32(truncatingIfNeeded: bytes.count)] {
            data.append(contentsOf: (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
        }
        return data
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static let reedenCSS = #"background-image: url("A7F7FC2AC4D0393A099371003E95D679"); background-position: center; background-repeat: no-repeat; background-size: 100% 100%; --reeden-background-nine-slice: 478.593 158.7 479.593 159.7; reeden-background-nine-slice: 227 91 228 92 / 504 173 / 64 69 440 126; display: inline; color: rgba(0,0,0,1); font-size: 0.89em; padding-left: 1.1228070175438596em; padding-right: 1.1228070175438596em; padding-top: 1.2105263157894737em; padding-bottom: 0.8245614035087719em;"#

    static func reedenRule(name: String, css: String = reedenCSS, enabled: Bool = true) -> [String: Any] {
        [
            "name": name, "keyword": "“[^”\\n]+”", "isRegex": true, "target": "all",
            "enabled": enabled, "styleMode": "advanced", "groupName": "对话",
            "styleCssText": css,
            "backgroundImageData": gzip(png()).base64EncodedString(),
        ]
    }

    static func reedenPack(rules: [[String: Any]] = [reedenRule(name: "对话高亮 十字架")]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: [
            "version": 1, "type": "highlightRule", "data": rules,
        ])
        return Data("RED".utf8) + [0x01] + gzip(json)
    }

    static func qiLayout(slices: [String: Double]) -> [String: Any] {
        [
            "contentInsets": ["top": 2, "left": 4, "bottom": 2, "right": 4],
            "sliceInsets": slices,
            "horizontalOffset": 0, "verticalOffset": 0,
            "horizontalScale": 1, "verticalScale": 1, "opacity": 1,
        ]
    }

    static func qiPack(enabled: Bool = false) async throws -> Data {
        let asset = "qireader-highlight-bg://asset-30816b75-5230-45c6-8a55-523040921e1c"
        let file = "asset-0-asset-30816b75-5230-45c6-8a55-523040921e1c.png"
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "assetFiles": [asset: file],
            "rules": [[
                "name": "高透绿", "regex": "“[^“”\\n]*”", "enabled": enabled,
                "noCrossParagraph": true, "crossPageQuotes": true, "fontFamily": "", "fontSize": 0,
                "lightColorHex": "464646", "darkColorHex": "464646",
                "lightStyleCSS": "", "darkStyleCSS": "",
                "lightBackgroundImageURL": asset, "darkBackgroundImageURL": asset,
                "lightBackgroundImageLayout": qiLayout(slices: ["top": 91, "left": 227, "bottom": 81, "right": 276]),
                "darkBackgroundImageLayout": qiLayout(slices: ["top": 91, "left": 227, "bottom": 81, "right": 276]),
            ]],
        ])
        let archive = try await EPUBTestFixtures.makeArchive(entries: [
            "高透绿/manifest.json": manifest,
            "高透绿/assets/\(file)": png(),
        ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        return try Data(contentsOf: archive)
    }
}

@Suite("Highlight-rule packs from other readers", .serialized)
struct HighlightPackImporterTests {
    private let context = HighlightPackImporter.Context(
        lightPrimaryHex: 0x336699, darkPrimaryHex: 0x99CCFF, bodySize: 20
    )

    // MARK: - gzip

    @Test("a gzip member with a file name in its header inflates")
    func inflatesRealGzip() throws {
        // `gzip.GzipFile(filename: "a.txt")` of "hello highlight " × 20.
        let member = Data([
            0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x61, 0x2E, 0x74, 0x78, 0x74,
            0x00, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0xC8, 0x4C, 0xCF, 0xC8, 0x01, 0xE2, 0x12,
            0x85, 0x8C, 0x51, 0x3E, 0x49, 0x7C, 0x00, 0x97, 0x87, 0x08, 0x18, 0x40, 0x01, 0x00, 0x00,
        ])
        let text = try GzipDecoder.decompress(member, maximumBytes: 1_024)
        #expect(String(decoding: text, as: UTF8.self) == String(repeating: "hello highlight ", count: 20))
    }

    @Test("stored blocks inflate, and the size cap and truncation are errors")
    func gzipLimits() throws {
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        let member = HighlightPackFixtures.gzip(payload)
        #expect(try GzipDecoder.decompress(member, maximumBytes: 100_000) == payload)
        #expect(throws: GzipDecoderError.tooLarge(maximum: 1_000)) {
            try GzipDecoder.decompress(member, maximumBytes: 1_000)
        }
        #expect(throws: (any Error).self) {
            try GzipDecoder.decompress(member.prefix(member.count - 30_000), maximumBytes: 100_000)
        }
        #expect(throws: GzipDecoderError.notGzip) {
            try GzipDecoder.decompress(Data("plain text, not gzip".utf8), maximumBytes: 100)
        }
    }

    // MARK: - Nine-slice

    @Test("Reeden's nine-slice centre rectangle becomes fractional cap insets")
    func readsReedenNineSlice() throws {
        let slices = try #require(ReedenThemeImporter.nineSlice(
            HighlightPackFixtures.reedenCSS, imageSize: HighlightPackFixtures.imageSize
        ))
        #expect(abs(slices.left - 227.0 / 504) < 1e-9)
        #expect(abs(slices.top - 91.0 / 173) < 1e-9)
        #expect(abs(slices.right - (504.0 - 228) / 504) < 1e-9)
        #expect(abs(slices.bottom - (173.0 - 92) / 173) < 1e-9)
    }

    @Test("the frame scales uniformly from the box height and shrinks both axes to fit")
    func nineSliceGeometry() {
        // 高透绿: 956×256, every pixel but a 1px centre is corner.
        let slices = NineSliceImageDrawing.Insets(top: 128, right: 477, bottom: 127, left: 478)
        let size = CGSize(width: 956, height: 256)
        let wide = NineSliceImageDrawing.destinationInsets(
            slices: slices, sourceSize: size, scale: 30.0 / 256, in: CGRect(x: 0, y: 0, width: 300, height: 30)
        )
        #expect(abs(wide.destination.left - 478 * 30.0 / 256) < 1e-6)
        #expect(abs(wide.destination.top + wide.destination.bottom - 255 * 30.0 / 256) < 1e-6)

        // A short quote: the corners need ~112pt; both axes shrink by the same factor.
        let narrow = NineSliceImageDrawing.destinationInsets(
            slices: slices, sourceSize: size, scale: 30.0 / 256, in: CGRect(x: 0, y: 0, width: 80, height: 30)
        )
        #expect(abs(narrow.destination.left + narrow.destination.right - 80) < 1e-6)
        let factor = narrow.destination.left / wide.destination.left
        #expect(abs(narrow.destination.top / wide.destination.top - factor) < 1e-6)
    }

    @Test("nine-slice insets survive the CSS codec both ways")
    func sliceCSSRoundTrip() throws {
        var style = ReaderStyleRuleStyle(text: .init(), decoration: .init(shadows: []))
        style.decoration.backgroundImage = ReaderStyleImagePresentation(
            assetID: UUID(), contentMode: .stretch,
            nineSlice: ReaderStyleImageSlices(top: 0.5, right: 0.25, bottom: 0.125, left: 0.375)
        )
        let css = ReaderStyleCSSCodec.encodeDeclarations(style, context: .regexHighlight)
        #expect(css.contains("-yuedu-background-slice: 50% 25% 12.5% 37.5%;"))
        let decoded = try ReaderStyleCSSCodec.decodeDeclarations(css, context: .regexHighlight)
        #expect(decoded.decoration.backgroundImage == style.decoration.backgroundImage)
    }

    // MARK: - Reeden

    @Test("a Reeden highlight pack keeps its artwork, frame, padding and colour")
    func parsesReedenPack() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let data = try HighlightPackFixtures.reedenPack(rules: [
            HighlightPackFixtures.reedenRule(name: "对话高亮 十字架"),
            HighlightPackFixtures.reedenRule(
                name: "首字下沉", css: "float: left; background-image: url(\"X\"); color: {primaryColor};"
            ),
            HighlightPackFixtures.reedenRule(
                name: "主色", css: "color: {primaryColor}; background-color: rgba(10,20,30,1);"
            ),
        ])
        #expect(HighlightPackImporter.format(fileExtension: "red", data: data) == .reeden)

        let pack = try await HighlightPackImporter.parse(data, format: .reeden, context: context, assetStore: store)
        #expect(pack.name == "对话")
        #expect(pack.rules.map(\.name) == ["对话高亮 十字架", "主色"])
        let frame = pack.rules[0].lightStyle
        let image = try #require(frame.decoration.backgroundImage)
        #expect(await store.assets().contains { $0.id == image.assetID })
        #expect(abs((image.nineSlice?.left ?? 0) - 227.0 / 504) < 1e-6)
        #expect(frame.text.colorHex == 0x000000)
        // Padding em is the rule's own size (0.89em of the 20pt body), not the body's.
        let padding = try #require(frame.decoration.padding)
        #expect(abs(padding.leading - 1.1228070175438596 * 0.89 * 20) < 0.01)
        #expect(abs((frame.text.fontSize ?? 0) - 17.8) < 0.01)

        let primary = pack.rules[1]
        #expect(primary.lightStyle.text.colorHex == 0x336699)
        #expect(primary.darkStyle.text.colorHex == 0x99CCFF)
        #expect(primary.lightStyle.decoration.backgroundColorHex == 0x0A141E)

        #expect(pack.notes.contains { $0.contains("首字下沉") })
        #expect(pack.notes.contains { $0.contains("display") })
    }

    @Test("a .red theme is not mistaken for a highlight pack")
    func themeIsNotHighlightPack() {
        let theme = Data("RED".utf8) + [0x04, 0x50, 0x4B, 0x03, 0x04]
        #expect(HighlightPackImporter.format(fileExtension: "red", data: theme) == nil)
    }

    // MARK: - QiReader

    @Test("a QiReader pack maps images, slices, content insets and colours per appearance")
    func parsesQiReaderPack() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let data = try await HighlightPackFixtures.qiPack()

        let pack = try await HighlightPackImporter.parse(data, format: .qiReader, context: context, assetStore: store)
        #expect(pack.name == "高透绿")
        let rule = try #require(pack.rules.first)
        #expect(rule.pattern == "“[^“”\\n]*”")
        #expect(!rule.isEnabled)
        #expect(rule.options.contains(.doesNotCrossParagraph))
        for style in [rule.lightStyle, rule.darkStyle] {
            #expect(style.text.colorHex == 0x464646)
            let image = try #require(style.decoration.backgroundImage)
            #expect(await store.assets().contains { $0.id == image.assetID })
            let slices = try #require(image.nineSlice)
            #expect(abs(slices.top - 91.0 / 173) < 1e-9)
            #expect(abs(slices.right - 276.0 / 504) < 1e-9)
            #expect(style.decoration.padding == ReaderStyleEdges(top: 2, leading: 4, bottom: 2, trailing: 4))
        }
        #expect(pack.notes.isEmpty)
    }

    @Test("QiReader's background shorthand becomes our gradient; what has no mapping is named")
    func translatesQiReaderCSS() {
        let css = "background: linear-gradient(90deg, #FFD93D, #00C2FF);\nborder-radius: 999px;\nbox-shadow:\n    0 2px 8px rgba(160, 150, 210, .15),\n    inset 0 1px 1px rgba(255,255,255,.4);"
        var dropped: Set<String> = []
        let style = ReaderStyleCSSCodec.decodeLeniently(
            HighlightPackImporter.qiDeclarations(css), context: .regexHighlight, dropped: &dropped
        )
        #expect(style.decoration.backgroundGradient?.stops.map(\.colorHex) == [0xFFD93D, 0x00C2FF])
        #expect(style.decoration.cornerRadius == 999)
        #expect(dropped == ["box-shadow"])

        // Our colours carry no alpha, so a translucent gradient is reported, not made opaque.
        var translucent: Set<String> = []
        _ = ReaderStyleCSSCodec.decodeLeniently(
            HighlightPackImporter.qiDeclarations("background: linear-gradient(90deg, rgba(255, 217, 61, .34), rgba(0, 194, 255, .22));"),
            context: .regexHighlight, dropped: &translucent
        )
        #expect(translucent == ["background-image"])
    }

    // MARK: - Wearing and merging

    @Test("a pack is worn: one rule per pattern on, the file's own choice first")
    func wearsPack() {
        func rule(_ name: String, _ pattern: String, on: Bool) -> RegexHighlightRule {
            var rule = RegexHighlightRule.custom(name: name, pattern: pattern)
            rule.isEnabled = on
            return rule
        }
        let allOff = HighlightPackImporter.worn([rule("a", "x", on: false), rule("b", "x", on: false), rule("c", "y", on: false)])
        #expect(allOff.map(\.isEnabled) == [true, false, true])
        let picked = HighlightPackImporter.worn([rule("a", "x", on: false), rule("b", "x", on: true)])
        #expect(picked.map(\.isEnabled) == [false, true])
    }

    @Test("an imported pack switches off same-pattern rules and replaces itself on re-import")
    func mergesPack() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let data = try await HighlightPackFixtures.qiPack()
        func imported() async throws -> [RegexHighlightRule] {
            HighlightPackImporter.worn(
                try await HighlightPackImporter.parse(data, format: .qiReader, context: context, assetStore: store).rules
            )
        }
        var mine = RegexHighlightRule.custom(name: "mine", pattern: "“[^“”\\n]*”")
        mine.isEnabled = true
        let base = RegexHighlightConfiguration(isEnabled: true, rules: RegexHighlightRule.builtIns, customRules: [mine])

        let once = base.addingImported(try await imported(), replacingSamePattern: true)
        #expect(once.customRules.map(\.name) == ["mine", "高透绿"])
        #expect(once.customRules.map(\.isEnabled) == [false, true])
        // Same bytes, same asset: the second import is recognised as the same rule.
        let twice = once.addingImported(try await imported(), replacingSamePattern: true)
        #expect(twice.customRules.map(\.name) == ["mine", "高透绿"])
    }

    @Test("sharing the rules as a style package keeps the frame and its artwork")
    func exportKeepsFrame() async throws {
        let sourceRoot = try readerStyleTemporaryDirectory()
        let targetRoot = try readerStyleTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = ReaderStyleAssetStore(rootURL: sourceRoot)
        let pack = try await HighlightPackImporter.parse(
            try HighlightPackFixtures.reedenPack(), format: .reeden, context: context, assetStore: source
        )
        let configuration = RegexHighlightConfiguration.disabled.addingImported(pack.rules)
        let exported = try await ReaderStylePackage.export(
            try .encode(
                configuration,
                kind: .regexHighlights,
                assetIDs: ReaderStyleAssetReferences.assetIDs(in: configuration)
            ),
            assetStore: source
        )
        let target = ReaderStyleAssetStore(rootURL: targetRoot)
        let payload = try await ReaderStylePackage.import(exported, assetStore: target)
        let reimported = try payload.decode(RegexHighlightConfiguration.self)
        let image = try #require(reimported.customRules.last?.lightStyle.decoration.backgroundImage)
        #expect(image.nineSlice == pack.rules[0].lightStyle.decoration.backgroundImage?.nineSlice)
        #expect(await target.assets().contains { $0.id == image.assetID })
    }
}
