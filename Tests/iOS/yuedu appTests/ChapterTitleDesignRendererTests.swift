import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Chapter title design renderer", .serialized)
struct ChapterTitleDesignRendererTests {
    @Test("dynamic fields resolve without losing original title text")
    func dynamicFieldsAndAccessibility() async throws {
        let design = ChapterTitleDesign(layers: [
            dynamicLayer(id: 1, kind: .chapterNumber, field: .number, y: 0),
            dynamicLayer(id: 2, kind: .chapterName, field: .name, y: 0.34),
            dynamicLayer(id: 3, kind: .originalTitle, field: .title, y: 0.68),
        ])
        let store = ReaderStyleAssetStore(
            rootURL: try readerStyleTemporaryDirectory()
        )

        let result = try await ChapterTitleDesignRenderer.compile(
            title: "第12章 風起",
            design: design,
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 320,
            assetStore: store
        )

        #expect(result.accessibilityText == "第12章 風起")
        #expect(result.layers.map(\.text) == ["第12章", "風起", "第12章 風起"])
        #expect(result.canvasSize == CGSize(width: 320, height: 112))
    }

    @Test("missing referenced assets are explicit validation errors")
    func missingAsset() async throws {
        let missingID = readerStyleFixtureUUID(90)
        let design = imageDesign(assetID: missingID)

        do {
            _ = try await ChapterTitleDesignRenderer.compile(
                title: "第一章",
                design: design,
                appearance: .light,
                writingMode: .horizontal,
                renderWidth: 320,
                assetStore: ReaderStyleAssetStore(
                    rootURL: try readerStyleTemporaryDirectory()
                )
            )
            Issue.record("Expected the missing asset to fail compilation")
        } catch let error as ChapterTitleDesignRendererError {
            #expect(error == .missingAsset(missingID))
        }
    }

    @Test("hidden and inactive appearance assets do not block compilation")
    func ignoresAssetsOutsideCurrentRenderPlan() async throws {
        let hiddenAssetID = readerStyleFixtureUUID(95)
        var hiddenLayer = imageDesign(assetID: hiddenAssetID).layers[0]
        hiddenLayer.isVisible = false

        let inactiveAssetID = readerStyleFixtureUUID(96)
        let visibleLayer = ChapterTitleLayer(
            id: readerStyleFixtureUUID(97),
            name: "Visible",
            kind: .chapterName,
            frame: .init(x: 0, y: 0, width: 1, height: 1),
            rotation: .init(degrees: 0),
            isVisible: true,
            isLocked: false,
            content: .dynamic(.title),
            lightStyle: .init(),
            darkStyle: .init(ruleStyle: .init(decoration: .init(
                backgroundImage: .init(assetID: inactiveAssetID)
            )))
        )

        let result = try await ChapterTitleDesignRenderer.compile(
            title: "第一章",
            design: ChapterTitleDesign(layers: [hiddenLayer, visibleLayer]),
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 320,
            assetStore: ReaderStyleAssetStore(
                rootURL: try readerStyleTemporaryDirectory()
            )
        )

        #expect(result.layers.map(\.id) == [visibleLayer.id])
    }

    @Test("every current appearance image reference is validated")
    func validatesAllCurrentAppearanceAssetKinds() async throws {
        let contentID = readerStyleFixtureUUID(98)
        let presentationID = readerStyleFixtureUUID(99)
        let backgroundID = readerStyleFixtureUUID(100)
        let cases: [(UUID, ChapterTitleLayer)] = [
            (
                contentID,
                ChapterTitleLayer(
                    id: readerStyleFixtureUUID(101),
                    name: "Content image",
                    kind: .image,
                    frame: .init(x: 0, y: 0, width: 1, height: 1),
                    rotation: .init(degrees: 0),
                    isVisible: true,
                    isLocked: false,
                    content: .image(contentID),
                    lightStyle: .init(),
                    darkStyle: .init()
                )
            ),
            (
                presentationID,
                ChapterTitleLayer(
                    id: readerStyleFixtureUUID(102),
                    name: "Presented image",
                    kind: .image,
                    frame: .init(x: 0, y: 0, width: 1, height: 1),
                    rotation: .init(degrees: 0),
                    isVisible: true,
                    isLocked: false,
                    content: .none,
                    lightStyle: .init(imagePresentation: .init(assetID: presentationID)),
                    darkStyle: .init()
                )
            ),
            (
                backgroundID,
                ChapterTitleLayer(
                    id: readerStyleFixtureUUID(103),
                    name: "Background image",
                    kind: .colorBlock,
                    frame: .init(x: 0, y: 0, width: 1, height: 1),
                    rotation: .init(degrees: 0),
                    isVisible: true,
                    isLocked: false,
                    content: .none,
                    lightStyle: .init(ruleStyle: .init(decoration: .init(
                        backgroundImage: .init(assetID: backgroundID)
                    ))),
                    darkStyle: .init()
                )
            ),
        ]

        for (missingID, layer) in cases {
            do {
                _ = try await ChapterTitleDesignRenderer.compile(
                    title: "第一章",
                    design: ChapterTitleDesign(layers: [layer]),
                    appearance: .light,
                    writingMode: .horizontal,
                    renderWidth: 320,
                    assetStore: ReaderStyleAssetStore(
                        rootURL: try readerStyleTemporaryDirectory()
                    )
                )
                Issue.record("Expected current appearance asset \(missingID) to be validated")
            } catch let error as ChapterTitleDesignRendererError {
                #expect(error == .missingAsset(missingID))
            }
        }
    }

    @Test("persisted asset data compiles when the image cache was never warmed")
    func coldAssetStore() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assetID = readerStyleFixtureUUID(91)
        let imageData = try #require(UIImage(systemName: "photo")?.pngData())
        let asset = ReaderStyleAsset(
            id: assetID,
            name: "Persisted",
            mimeType: "image/png",
            pixelWidth: 64,
            pixelHeight: 64,
            hasAlpha: true,
            sha256: String(repeating: "a", count: 64),
            fileName: "persisted.png",
            thumbnailFileName: "persisted-thumb.png"
        )
        try imageData.write(to: root.appendingPathComponent(asset.fileName))
        try imageData.write(to: root.appendingPathComponent(asset.thumbnailFileName))
        let manifest = AssetManifestFixture(version: 1, revision: 1, assets: [asset])
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("manifest.json")
        )

        let result = try await ChapterTitleDesignRenderer.compile(
            title: "第一章",
            design: imageDesign(assetID: assetID),
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 320,
            assetStore: ReaderStyleAssetStore(rootURL: root)
        )

        #expect(result.layers.first?.image != nil)
    }

    @Test("vertical compilation resolves design and canvas in one coordinate space")
    func verticalResolvedDesign() async throws {
        let layer = ChapterTitleLayer(
            id: readerStyleFixtureUUID(92),
            name: "Name",
            kind: .chapterName,
            frame: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            rotation: .init(degrees: 15),
            isVisible: true,
            isLocked: false,
            content: .dynamic(.name),
            lightStyle: .init(),
            darkStyle: .init()
        )

        let result = try await ChapterTitleDesignRenderer.compile(
            title: "第一章 風起",
            design: ChapterTitleDesign(layers: [layer]),
            appearance: .dark,
            writingMode: .verticalRTL,
            renderWidth: 320,
            assetStore: ReaderStyleAssetStore(
                rootURL: try readerStyleTemporaryDirectory()
            )
        )

        #expect(result.canvasSize == CGSize(width: 112, height: 320))
        let frame = result.layers[0].frame
        #expect(abs(frame.minX - 44.8) < 0.001)
        #expect(abs(frame.minY - 32) < 0.001)
        #expect(abs(frame.width - 44.8) < 0.001)
        #expect(abs(frame.height - 96) < 0.001)
        #expect(result.layers[0].style.writingDirection == .vertical)
        #expect(result.layers[0].rotationRadians == CGFloat(15 * Double.pi / 180))
        let color = try #require(
            result.layers[0].attributedText?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? UIColor
        )
        #expect(color == GlobalSettings.uiColor(rgbHex: 0xF2F2F7))
    }

    @Test("missing font faces fall back while preserving requested traits")
    func fontFallbackTraits() async throws {
        let styledLayer = ChapterTitleLayer(
            id: readerStyleFixtureUUID(94),
            name: "Styled",
            kind: .chapterName,
            frame: .init(x: 0, y: 0, width: 1, height: 1),
            rotation: .init(degrees: 0),
            isVisible: true,
            isLocked: false,
            content: .dynamic(.title),
            lightStyle: .init(ruleStyle: .init(text: .init(
                fontPostScriptName: "YD-Missing-Font",
                fontSize: 26,
                fontWeight: 700,
                italic: true
            ))),
            darkStyle: .init()
        )
        let result = try await ChapterTitleDesignRenderer.compile(
            title: "第一章",
            design: ChapterTitleDesign(layers: [styledLayer]),
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 320,
            assetStore: ReaderStyleAssetStore(
                rootURL: try readerStyleTemporaryDirectory()
            )
        )
        let font = try #require(
            result.layers[0].attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont
        )

        #expect(font.fontName != "YD-Missing-Font")
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    @Test("structured marker reserves canvas and carries the immutable plan")
    func attributedMarker() async throws {
        let title = "第12章 風起"
        let marker = try await ChapterTitleAttributedBuilder.compileDesignBlock(
            title: title,
            design: ChapterTitleDesign.default,
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 320,
            bottomSpacing: 24,
            assetStore: ReaderStyleAssetStore(
                rootURL: try readerStyleTemporaryDirectory()
            )
        )

        #expect(marker.string == title + "\n")
        let plan = try #require(
            marker.attribute(
                ChapterTitleAttributedBuilder.designRenderPlanAttribute,
                at: 0,
                effectiveRange: nil
            ) as? ChapterTitleRenderPlan
        )
        #expect(plan.accessibilityText == title)
        let paragraph = try #require(
            marker.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        #expect(paragraph.minimumLineHeight == plan.canvasSize.height)
        #expect(paragraph.maximumLineHeight == plan.canvasSize.height)
        #expect(paragraph.paragraphSpacing == 24)
        let color = try #require(
            marker.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                as? UIColor
        )
        #expect(color.cgColor.alpha == 0)
    }

    @Test("migrated layers render while retained legacy source remains available for export")
    func migratedDesignUsesStructuredLayers() async throws {
        var design = ChapterTitleDesign.default
        design.legacySource = ChapterTitleLegacySource(
            light: "<div>{name}</div>",
            dark: "<div>{name}</div>"
        )

        let result = try await ChapterTitleDesignRenderer.compile(
            title: "第一章 風起",
            design: design,
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 320,
            assetStore: ReaderStyleAssetStore(
                rootURL: try readerStyleTemporaryDirectory()
            )
        )

        #expect(result.layers.count == design.layers.count)
        #expect(design.legacySource != nil)
    }

    private func dynamicLayer(
        id: Int,
        kind: ChapterTitleLayerKind,
        field: ChapterTitleDynamicField,
        y: Double
    ) -> ChapterTitleLayer {
        ChapterTitleLayer(
            id: readerStyleFixtureUUID(id),
            name: field.rawValue,
            kind: kind,
            frame: .init(x: 0, y: y, width: 1, height: 0.32),
            rotation: .init(degrees: 0),
            isVisible: true,
            isLocked: false,
            content: .dynamic(field),
            lightStyle: .init(),
            darkStyle: .init()
        )
    }

    private func imageDesign(assetID: UUID) -> ChapterTitleDesign {
        ChapterTitleDesign(layers: [
            ChapterTitleLayer(
                id: readerStyleFixtureUUID(93),
                name: "Image",
                kind: .image,
                frame: .init(x: 0, y: 0, width: 1, height: 1),
                rotation: .init(degrees: 0),
                isVisible: true,
                isLocked: false,
                content: .image(assetID),
                lightStyle: .init(
                    imagePresentation: .init(assetID: assetID, contentMode: .fit)
                ),
                darkStyle: .init(
                    imagePresentation: .init(assetID: assetID, contentMode: .fit)
                )
            ),
        ])
    }
}

private struct AssetManifestFixture: Codable {
    let version: Int
    let revision: UInt64
    let assets: [ReaderStyleAsset]
}
