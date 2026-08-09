import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter title HTML codec")
struct ChapterTitleHTMLCodecTests {
    @Test("all supported layer kinds and appearance styles round trip canonically")
    func allKindsRoundTrip() throws {
        let design = everyLayerDesign()
        let light = ChapterTitleHTMLCodec.encode(design, appearance: .light)
        let dark = ChapterTitleHTMLCodec.encode(design, appearance: .dark)
        let decoded = try ChapterTitleHTMLCodec.decode(light: light, dark: dark)

        #expect(decoded.sanitized() == design.sanitized())
        #expect(light == ChapterTitleHTMLCodec.encode(decoded, appearance: .light))
        #expect(dark == ChapterTitleHTMLCodec.encode(decoded, appearance: .dark))
        #expect(light.contains("{number}"))
        #expect(light.contains("{name}"))
        #expect(light.contains("{title}"))
        #expect(light.contains("left: 5%;"))
        #expect(light.contains("transform: rotate(7deg);"))
    }

    @Test("unsupported tags fail with source coordinates")
    func rejectsUnsupportedTag() {
        #expect(throws: ChapterTitleHTMLCodecError.unsupportedTag(
            name: "script", line: 2, column: 3
        )) {
            try ChapterTitleHTMLCodec.decode(
                light: "<div>\n  <script>alert(1)</script>\n</div>",
                dark: "<div></div>"
            )
        }
    }

    @Test("unsupported attributes fail at the attribute coordinate")
    func rejectsUnsupportedAttribute() {
        #expect(throws: ChapterTitleHTMLCodecError.unsupportedAttribute(
            name: "onclick", line: 2, column: 9
        )) {
            try ChapterTitleHTMLCodec.decode(
                light: "<div>\n  <span onclick=\"bad()\">x</span>\n</div>",
                dark: "<div></div>"
            )
        }
    }

    @Test("remote image URLs are rejected before DOM normalization")
    func rejectsRemoteImage() {
        #expect(throws: ChapterTitleHTMLCodecError.remoteResource(line: 1, column: 1)) {
            try ChapterTitleHTMLCodec.decode(
                light: "<img src=\"https://example.com/a.png\">",
                dark: "<div></div>"
            )
        }
    }

    @Test("remote CSS URLs are rejected")
    func rejectsRemoteCSSResource() {
        #expect(throws: ChapterTitleHTMLCodecError.remoteResource(line: 2, column: 3)) {
            try ChapterTitleHTMLCodec.decode(
                light: """
                <div data-yuedu-version="1" data-yuedu-canvas-aspect-ratio="2" data-yuedu-canvas-height="100">
                  <div data-yuedu-layer-id="10000000-0000-0000-0000-000000000001" data-yuedu-layer-kind="colorBlock" data-yuedu-layer-name="Block" data-yuedu-visible="true" data-yuedu-locked="false" data-yuedu-content="none" style="position:absolute;left:0%;top:0%;width:100%;height:100%;background-image:url(https://example.com/a.png)"></div>
                </div>
                """,
                dark: "<div></div>"
            )
        }
    }

    @Test("duplicate IDs and invalid placeholders are diagnostic")
    func rejectsDuplicateAndInvalidPlaceholder() throws {
        let design = everyLayerDesign()
        let source = ChapterTitleHTMLCodec.encode(design, appearance: .light)
        let firstID = design.layers[0].id.uuidString.lowercased()
        let secondID = design.layers[1].id.uuidString.lowercased()
        let duplicate = source.replacingOccurrences(of: secondID, with: firstID)
        #expect(throws: ChapterTitleHTMLCodecError.duplicateLayerID(firstID)) {
            try ChapterTitleHTMLCodec.decode(light: duplicate, dark: source)
        }

        let invalid = source.replacingOccurrences(of: "{number}", with: "{chapter}")
        do {
            _ = try ChapterTitleHTMLCodec.decode(light: invalid, dark: source)
            Issue.record("Expected an invalid-placeholder diagnostic")
        } catch ChapterTitleHTMLCodecError.invalidPlaceholder(let value, let line, let column) {
            #expect(value == "{chapter}")
            #expect(line == 2)
            #expect(column > 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("chapter geometry declarations round trip instead of being discarded")
    func chapterGeometryRoundTrip() throws {
        let imageID = UUID(uuidString: "20000000-0000-0000-0000-000000000099")!
        let original = ReaderStyleChapterLayerDeclarations(
            ruleStyle: .init(text: .init(colorHex: 0x123456)),
            frame: .init(x: 0.12, y: 0.23, width: 0.34, height: 0.45),
            rotation: .init(degrees: -13),
            textAlignment: .right,
            writingDirection: .vertical,
            imagePresentation: .init(
                assetID: imageID,
                contentMode: .stretch,
                focalX: 0.2,
                focalY: 0.8,
                opacity: 0.7
            )
        )
        let source = ReaderStyleCSSCodec.encodeChapterLayerDeclarations(original)
        let decoded = try ReaderStyleCSSCodec.decodeChapterLayerDeclarations(source)

        #expect(decoded == original)
    }

    @Test("light and dark must preserve layer structure")
    func rejectsStructureMismatch() {
        let design = everyLayerDesign()
        let light = ChapterTitleHTMLCodec.encode(design, appearance: .light)
        var changed = design
        changed.layers.swapAt(0, 1)
        let dark = ChapterTitleHTMLCodec.encode(changed, appearance: .dark)

        #expect(throws: ChapterTitleHTMLCodecError.lightDarkStructureMismatch) {
            try ChapterTitleHTMLCodec.decode(light: light, dark: dark)
        }
    }

    @Test("legacy flow migrates atomically and retains the original source")
    func migratesLegacyFlow() throws {
        let source = ChapterTitleLegacySource(
            light: "<div style=\"text-align:center\"><p style=\"font-size:0.55em;color:#112233\">{number}</p><span>◆</span><p style=\"font-size:1em\">{name}</p></div>",
            dark: "<div style=\"text-align:center\"><p style=\"font-size:0.55em;color:#DDEEFF\">{number}</p><span>◆</span><p style=\"font-size:1em\">{name}</p></div>"
        )
        let migrated = try ChapterTitleHTMLCodec.migrateLegacySource(source)

        #expect(migrated.layers.map(\.kind) == [.chapterNumber, .ornament, .chapterName])
        #expect(migrated.layers.map(\.content) == [.dynamic(.number), .text("◆"), .dynamic(.name)])
        #expect(migrated.layers[0].lightStyle.ruleStyle.text.fontSize == 15.4)
        #expect(migrated.layers[0].darkStyle.ruleStyle.text.colorHex == 0xDDEEFF)
        #expect(migrated.layers.allSatisfy { $0.lightStyle.textAlignment == .center })
        #expect(migrated.legacySource == source)
    }

    @Test("failed legacy migration does not mutate caller-owned source")
    func failedLegacyMigrationIsAtomic() {
        let source = ChapterTitleLegacySource(
            light: "<div><script>bad()</script></div>",
            dark: "<div>{name}</div>"
        )
        let original = source

        #expect(throws: ChapterTitleHTMLCodecError.unsupportedTag(
            name: "script", line: 1, column: 6
        )) {
            try ChapterTitleHTMLCodec.migrateLegacySource(source)
        }
        #expect(source == original)
    }

    private func everyLayerDesign() -> ChapterTitleDesign {
        let imageID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let kinds: [(ChapterTitleLayerKind, ChapterTitleLayerContent)] = [
            (.chapterNumber, .dynamic(.number)),
            (.chapterName, .dynamic(.name)),
            (.originalTitle, .dynamic(.title)),
            (.customText, .text("Custom & <text>")),
            (.ornament, .text("◆")),
            (.line, .line(.init(width: 2, colorHex: 0x123456, isDashed: true))),
            (.colorBlock, .none),
            (.image, .image(imageID)),
        ]
        let layers = kinds.enumerated().map { index, entry in
            let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012X", index + 1))!
            let imagePresentation: ReaderStyleImagePresentation? = entry.0 == .image
                ? .init(assetID: imageID, contentMode: .fit, focalX: 0.25, focalY: 0.75, opacity: 0.8)
                : nil
            let lightRule = ReaderStyleRuleStyle(
                text: .init(
                    colorHex: 0x112233,
                    fontPostScriptName: "A Font",
                    fontSize: 18,
                    fontWeight: 600,
                    italic: false,
                    letterSpacing: 1,
                    lineHeight: 24,
                    underline: false,
                    strikethrough: false
                ),
                decoration: .init(
                    backgroundColorHex: 0xF0F1F2,
                    padding: .init(top: 1, leading: 2, bottom: 3, trailing: 4),
                    margin: .init(top: 4, leading: 3, bottom: 2, trailing: 1),
                    borders: [.bottom: .init(width: 1, colorHex: 0x445566)],
                    cornerRadius: 3,
                    shadows: [.init(colorHex: 0x010203, radius: 2, x: 1, y: 2)],
                    opacity: 0.9
                )
            )
            var darkRule = lightRule
            darkRule.text.colorHex = 0xDDEEFF
            darkRule.decoration.backgroundColorHex = 0x101112
            return ChapterTitleLayer(
                id: id,
                name: "Layer \(index) \"&\"",
                kind: entry.0,
                frame: .init(x: 0.05, y: Double(index) * 0.1, width: 0.9, height: 0.08),
                rotation: .init(degrees: 7),
                isVisible: index != 6,
                isLocked: index == 7,
                content: entry.1,
                lightStyle: .init(
                    ruleStyle: lightRule,
                    textAlignment: .left,
                    writingDirection: .horizontal,
                    imagePresentation: imagePresentation
                ),
                darkStyle: .init(
                    ruleStyle: darkRule,
                    textAlignment: .right,
                    writingDirection: .vertical,
                    imagePresentation: imagePresentation
                )
            )
        }
        return ChapterTitleDesign(
            canvasAspectRatio: 2.5,
            canvasHeight: 120,
            layers: layers
        )
    }
}
