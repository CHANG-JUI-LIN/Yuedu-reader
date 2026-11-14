import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader settings export")
struct ReaderSettingsExportTests {
    private func makeSnapshot() -> ReaderLayoutSnapshot {
        ReaderLayoutSnapshot(
            name: "測試",
            fontSize: 20,
            isBold: true,
            lineHeightMultiple: 1.8,
            letterSpacing: 1.5,
            paragraphSpacingMultiplier: 0.6,
            pageMarginH: 22,
            pageMarginV: 14,
            footerBottomPadding: 9,
            footerTextGap: 5,
            titleVisible: true,
            titleSize: 22,
            titleTopSpacing: 12,
            titleBottomSpacing: 18,
            pageTurnStyle: .curl,
            scrollMode: false,
            readerOverlayLayout: ReaderOverlayLayoutMigration.defaultLayout
        )
    }

    @Test("round-trips through the one layout importer")
    func roundTripsThroughImporter() throws {
        let snapshot = makeSnapshot()

        let data = try ReaderLayoutPresetExporter.encode(snapshot)
        let preset = try ReaderLayoutPresetImporter.decode(data: data)

        #expect(preset.name == "測試")
        #expect(preset.fontSize == 20)
        #expect(preset.isBold == true)
        #expect(abs((preset.lineHeightMultiple ?? 0) - 1.8) < 0.0001)
        #expect(preset.letterSpacing == 1.5)
        #expect(abs((preset.paragraphSpacingMultiplier ?? 0) - 0.6) < 0.0001)
        #expect(preset.pageMarginH == 22)
        #expect(preset.pageMarginV == 14)
        #expect(preset.titleVisible == true)
        #expect(preset.titleSize == 22)
        #expect(preset.titleTopSpacing == 12)
        #expect(preset.titleBottomSpacing == 18)
        #expect(preset.pageTurnStyle == .curl)
        #expect(preset.scrollMode == false)
        #expect(
            preset.readerOverlayLayout
                == ReaderOverlayLayoutMigration.upgrade(ReaderOverlayLayoutMigration.defaultLayout)
        )
    }

    @Test("scroll mode outranks the page-turn animation, as legado stores it")
    func scrollModeOutranksPageAnimation() throws {
        var snapshot = makeSnapshot()
        snapshot.scrollMode = true

        let preset = try ReaderLayoutPresetImporter.decode(
            data: try ReaderLayoutPresetExporter.encode(snapshot)
        )

        #expect(preset.scrollMode == true)
    }

    @Test("bundle carries the layout through its own decoder")
    func bundleDecodesItsLayout() throws {
        let inputs = ReaderSettingsExportInputs(
            layout: makeSnapshot(),
            chapterTitleStyle: .default,
            regexHighlights: .disabled
        )

        let bundle = try inputs.makeBundle()
        let encoded = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(ReaderSettingsBundle.self, from: encoded)

        #expect(decoded.format == ReaderSettingsBundle.formatIdentifier)
        #expect(decoded.chapterTitleStyle == ChapterTitleStyle.default)
        #expect(decoded.regexHighlights == RegexHighlightConfiguration.disabled)
        #expect(try decoded.decodedLayoutPreset()?.fontSize == 20)
    }

    /// 匯出閱讀設定 asks for a name first; the file carries it (2026-09-29). It used to be
    /// 閱讀設定.yuedustyle every time, whatever the setup.
    @Test("the export is written under the name it was given")
    func writesTheExportUnderItsName() async throws {
        let inputs = ReaderSettingsExportInputs(
            layout: makeSnapshot(),
            chapterTitleStyle: .default,
            regexHighlights: .disabled
        )

        let url = try await ReaderSettingsExportFile.write(inputs, named: "夜讀/護眼")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "夜讀-護眼.yuedustyle")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Both schemas decode every field with `decodeIfPresent`, so either decoder
    /// accepts any JSON object. Without the key check, importing a chapter-title
    /// file resets the reader's type size to the layout default.
    @Test("tells a chapter-title JSON apart from a readConfig JSON")
    func discriminatesBareJSONSchemas() throws {
        let titleJSON = Data(
            """
            {"visible": true, "size": 21, "topSpacing": 8, "advancedCSSEnabled": false}
            """.utf8
        )
        let readConfigJSON = Data(
            """
            {"textSize": 17, "paddingLeft": 21, "pageAnim": 0, "headerMode": 1}
            """.utf8
        )

        #expect(ReaderSettingsImportService.looksLikeChapterTitleJSON(titleJSON))
        #expect(!ReaderSettingsImportService.looksLikeChapterTitleJSON(readConfigJSON))
        #expect(!ReaderSettingsImportService.looksLikeChapterTitleJSON(Data("[]".utf8)))
    }

    @Test("an exported layout is never mistaken for a chapter-title file")
    func exportedLayoutIsNotChapterTitle() throws {
        let data = try ReaderLayoutPresetExporter.encode(makeSnapshot())
        #expect(!ReaderSettingsImportService.looksLikeChapterTitleJSON(data))
    }

    // MARK: - Version 2: the whole of 閱讀設定

    private func makeReadingSettings(backgroundID: UUID, bubbleID: UUID) -> AppearanceThemeReadingSettings {
        var reading = AppearanceThemeReadingSettings()
        reading.fontPostScript = "TestFont-Regular"
        reading.fontSize = 21
        reading.isBold = false
        reading.lineHeightMultiple = 1.9
        reading.bottomJustify = true
        reading.writingMode = "verticalRTL"
        reading.headerVisible = false
        reading.footerTextGap = 7
        reading.chapterTitleStyle = .default
        reading.readerTheme = "green"
        reading.boundDarkReaderTheme = "custom:\(backgroundID.uuidString)"
        reading.readerBackgroundID = backgroundID.uuidString
        reading.commentBubble = .init(
            followsSourceSVG: false,
            presetMode: ReaderCommentBubblePresetMode.custom.rawValue,
            customStyleID: bubbleID,
            scale: 1.2,
            textScale: 0.9
        )
        reading.regexHighlights = .disabled
        reading.textUnderline = .init(isEnabled: true, colorHex: 0x123456, style: 0, thickness: 1, offset: 2)
        return reading
    }

    private func makeBehavior() -> ReaderBehaviorSettings {
        var behavior = ReaderBehaviorSettings()
        behavior.textConversion = TextConversion.toTraditional.rawValue
        behavior.usesBookSpacing = false
        behavior.spreadMode = ReaderSpreadMode.doublePage.rawValue
        behavior.tapBothSidesNextPage = true
        behavior.swipeUpToExit = false
        behavior.pullDownToBookmark = false
        behavior.touchZonesLeftToRight = TouchZoneConfig(zones: Array(repeating: .nextPage, count: 9))
        behavior.touchZonesRightToLeft = .defaultForReadingDirection(isRTL: true)
        behavior.followsSystemBrightness = false
        behavior.brightness = 0.4
        behavior.keepsScreenAwake = true
        return behavior
    }

    /// The bug this closes (2026-11-14): 匯出閱讀設定 carried only the layout, the title
    /// style and the highlight rules, so a shared file lost the font, the background,
    /// the decorations and every behaviour row.
    @Test("a version-2 export carries the whole setup, its pictures and its fonts")
    @MainActor
    func fullSetupRoundTrips() async throws {
        let backgroundID = UUID()
        let bubble = ReaderCommentBubbleCustomStyle(name: "測試氣泡", svg: "<svg/>")
        let reading = makeReadingSettings(backgroundID: backgroundID, bubbleID: bubble.id)
        let behavior = makeBehavior()

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-settings-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pictureBytes = Data((0..<512).map { UInt8($0 % 251) })
        let pictureURL = scratch.appendingPathComponent("picture.jpg")
        try pictureBytes.write(to: pictureURL)
        let fontBytes = Data((0..<1024).map { UInt8($0 % 241) })
        let fontURL = scratch.appendingPathComponent("font.otf")
        try fontBytes.write(to: fontURL)

        var inputs = ReaderSettingsExportInputs(
            layout: makeSnapshot(),
            chapterTitleStyle: .default,
            regexHighlights: .disabled,
            readingSettings: reading,
            behavior: behavior
        )
        inputs.readerBackgrounds = [ReaderCustomBackground(
            id: backgroundID,
            name: "夜色",
            colorHex: 0x101820,
            imageFileName: "picture.jpg",
            isDark: true
        )]
        inputs.readerBackgroundPictureURLs = [backgroundID: pictureURL]
        inputs.commentBubbleStyle = bubble
        inputs.fontFiles = [.init(postScriptName: "TestFont-Regular", url: fontURL)]

        let url = try await ReaderSettingsExportFile.write(inputs, named: "整套")
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = try await ReaderSettingsImportService.loadReaderSettings(from: url)

        #expect(plan.fullReadingSettings == reading)
        #expect(plan.readingSettings == reading)
        #expect(plan.behavior == behavior)
        // One source per field: the legacy layout section is not applied as well.
        #expect(plan.layout == nil)
        #expect(plan.name == "測試")
        #expect(plan.replacesReadingSetup)
        #expect(plan.readerBackgrounds.map(\.background.id) == [backgroundID])
        #expect(plan.readerBackgrounds.first?.background.name == "夜色")
        #expect(plan.readerBackgrounds.first?.imageData == pictureBytes)
        #expect(plan.commentBubbleStyle == bubble)
        #expect(plan.fonts.map(\.postScriptName) == ["TestFont-Regular"])
        #expect(plan.fonts.first?.data == fontBytes)
        #expect(plan.fonts.first?.fileExtension == "otf")
        #expect(ReadingSetupPart.parts(in: plan).contains(.pagingGestures))
        #expect(ReadingSetupPart.parts(in: plan).contains(.brightness))
        #expect(ReadingSetupPart.parts(in: plan).contains(.background))
    }

    /// Files written before version 2 hold only the three original parts; they still
    /// import through the layout importer.
    @Test("a version-1 file still imports its layout, title style and rules")
    @MainActor
    func versionOneFileStillImports() throws {
        let bundle = ReaderSettingsBundle(
            layoutConfig: try ReaderLayoutPresetExporter.encode(makeSnapshot()),
            chapterTitleStyle: .default,
            regexHighlights: .disabled
        )
        let payload = try ReaderStylePackagePayload.encode(bundle, kind: .readerSettings, assetIDs: [])
        let plan = try ReaderSettingsImportService.plan(from: payload)

        #expect(plan.fullReadingSettings == nil)
        #expect(plan.layout?.fontSize == 20)
        #expect(plan.readingSettings.fontSize == 20)
        #expect(plan.chapterTitleStyle == .default)
        #expect(plan.replacesReadingSetup)
    }

    @Test("a file naming a picture or font the package does not hold is refused")
    @MainActor
    func missingAttachmentIsRefused() throws {
        var bundle = ReaderSettingsBundle(layoutConfig: nil, chapterTitleStyle: nil, regexHighlights: nil)
        bundle.readingSettings = AppearanceThemeReadingSettings()
        bundle.fonts = [.init(postScriptName: "Missing", attachmentID: "font.0")]
        let payload = try ReaderStylePackagePayload.encode(bundle, kind: .readerSettings, assetIDs: [])

        #expect(throws: ReaderStylePackageError.malformedManifest) {
            try ReaderSettingsImportService.plan(from: payload)
        }
    }

    @Test("an untrusted file's behaviour rows are clamped to what the reader accepts")
    func behaviorIsSanitized() {
        var behavior = makeBehavior()
        behavior.brightness = 7
        behavior.spreadMode = "sideways"
        behavior.touchZonesLeftToRight = TouchZoneConfig(zones: [.nextPage])

        let sanitized = behavior.sanitized()

        #expect(sanitized.brightness == ReaderBehaviorSettings.brightnessRange.upperBound)
        #expect(sanitized.spreadMode == nil)
        #expect(sanitized.touchZonesLeftToRight == nil)
        #expect(sanitized.touchZonesRightToLeft == behavior.touchZonesRightToLeft)
    }

    @Test("behaviour rows read out and write back through the live settings")
    @MainActor
    func behaviorAppliesToLiveSettings() {
        let settings = GlobalSettings.shared
        let original = settings.currentReaderBehaviorSettings
        defer { settings.applyReaderBehaviorSettings(original) }

        let behavior = makeBehavior()
        settings.applyReaderBehaviorSettings(behavior)

        #expect(settings.currentReaderBehaviorSettings == behavior)
    }
}
