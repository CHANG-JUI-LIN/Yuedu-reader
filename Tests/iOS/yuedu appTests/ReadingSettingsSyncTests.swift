import Foundation
import Testing
import YueduCoreText
@testable import yuedu_app

/// 閱讀設定 across devices (2026-09-29): each 排版生效範圍 row as last set on any device.
/// The background row has its own tests in 閱讀背景.
@Suite("閱讀設定同步", .serialized)
@MainActor
struct ReadingSettingsSyncTests {
    /// A size set here is noted for its row alone; rows from another device are worn,
    /// recorded where they come from, and not noted again as this device's.
    @Test func aFontSizeSetHereIsNotedAndOnesFromElsewhereAreWorn() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.readingSettingSyncRecords = []

        settings.readerFontSize = fixture.fontSize + 2
        let noted = try #require(settings.readingSettingSyncRecords.first { $0.item == "fontSize" })
        #expect(noted.values.fontSize == fixture.fontSize + 2)
        #expect(noted.values.lineHeightMultiple == nil)

        var fontSize = AppearanceThemeReadingSettings()
        fontSize.fontSize = 30
        var lineHeight = AppearanceThemeReadingSettings()
        lineHeight.lineHeightMultiple = 2
        let remote = [
            ReadingSettingSyncRecord(item: "fontSize", values: fontSize, editedAt: Date(timeIntervalSince1970: 1_900_000_000)),
            ReadingSettingSyncRecord(item: "lineSpacing", values: lineHeight, editedAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ]
        settings.applyReadingSettingsSync(remote)

        #expect(settings.readerFontSize == 30)
        #expect(settings.lineHeightMultiple == 2)
        #expect(settings.readingSettingSyncRecords == remote)
        // Recorded where they come from: wearing the setup again keeps them.
        settings.synchronizeReadingSettings()
        #expect(settings.readerFontSize == 30)
        #expect(settings.lineHeightMultiple == 2)
    }

    /// 排版方向 is noted and worn as its own row, like the other reading settings.
    @Test func aWritingModeIsNotedAndOneFromElsewhereIsWorn() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        let originalMode = settings.readerWritingMode
        defer {
            settings.readerWritingMode = originalMode
            fixture.restore()
        }
        settings.readerWritingMode = .horizontal
        settings.readingSettingSyncRecords = []

        settings.readerWritingMode = .verticalRTL
        let noted = try #require(settings.readingSettingSyncRecords.first { $0.item == "writingMode" })
        #expect(noted.values.writingMode == ReaderWritingMode.verticalRTL.rawValue)
        #expect(noted.values.fontSize == nil)

        var horizontal = AppearanceThemeReadingSettings()
        horizontal.writingMode = ReaderWritingMode.horizontal.rawValue
        let remote = [ReadingSettingSyncRecord(item: "writingMode", values: horizontal,
                                               editedAt: Date(timeIntervalSince1970: 1_900_000_000))]
        settings.applyReadingSettingsSync(remote)
        #expect(settings.readerWritingMode == .horizontal)
        settings.synchronizeReadingSettings()
        #expect(settings.readerWritingMode == .horizontal)
    }

    /// The header/footer layout and which bubble is picked have records of their own;
    /// this sync neither carries the one nor overrides the other.
    @Test func whatHasItsOwnRecordIsLeftToIt() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.readingSettingSyncRecords = []

        settings.readerHeaderVisible = !fixture.headerVisible
        let headerFooter = try #require(settings.readingSettingSyncRecords.first { $0.item == "headerFooter" })
        #expect(headerFooter.values.headerVisible == !fixture.headerVisible)
        #expect(headerFooter.values.barLayout == nil)

        let pickedMode = settings.commentBubblePresetMode
        let pickedStyle = settings.commentBubbleSelectedCustomStyleID
        var bubble = AppearanceThemeReadingSettings()
        bubble.commentBubble = .init(
            followsSourceSVG: !fixture.followsSourceSVG,
            presetMode: ReaderCommentBubblePresetMode.square.rawValue,
            customStyleID: UUID(),
            scale: GlobalSettings.sanitizedCommentBubbleScale(fixture.bubbleScale + 0.1),
            textScale: fixture.bubbleTextScale
        )
        settings.applyReadingSettingsSync([
            ReadingSettingSyncRecord(item: "commentBubble", values: bubble, editedAt: Date()),
        ])

        #expect(settings.commentBubblePresetMode == pickedMode)
        #expect(settings.commentBubbleSelectedCustomStyleID == pickedStyle)
        #expect(settings.commentBubbleFollowsSourceSVG == !fixture.followsSourceSVG)
        #expect(settings.commentBubbleScale == GlobalSettings.sanitizedCommentBubbleScale(fixture.bubbleScale + 0.1))
    }

    /// Another device's header/footer layout, from its own record, is worn and kept in the
    /// reading setup but not noted as set here. Noted, the 頁首頁尾 row became this device's
    /// newest setting, and every other device took this one's header and footer settings
    /// with it (2026-10-05).
    @Test func aLayoutFromAnotherDeviceIsNotNotedAsSetHere() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        let originalLayout = settings.readerBarLayout
        let originalClock = settings.readerBarLayoutSyncClock
        defer { settings.applyReaderBarLayoutFromSync(originalLayout, modifiedAt: originalClock) }
        settings.readingSettingSyncRecords = []

        // As stored: saving a layout normalizes it.
        var layout = ReaderBarLayout(fields: [
            .init(kind: .bookTitle, slot: .headerRight),
            .init(kind: .currentTime, slot: .footerLeft),
        ]).normalized(preservingVersion: false)
        if layout == originalLayout {
            layout.fields.append(.init(kind: .chapterPage, slot: .footerRight))
            layout = layout.normalized(preservingVersion: false)
        }
        let elsewhere = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(settings.applyReaderBarLayoutFromSync(layout, modifiedAt: elsewhere))

        #expect(settings.readerBarLayout == layout)
        #expect(settings.readerBarLayoutSyncClock == elsewhere)
        #expect(settings.readingSettingSyncRecords.isEmpty)
        // Kept in the setup: wearing it again keeps the layout.
        settings.synchronizeReadingSettings()
        #expect(settings.readerBarLayout == layout)
    }

    /// Puts back the settings these tests set, then the stores and the sync rows — the
    /// writes that put the live values back note rows too.
    @MainActor
    private final class Fixture {
        private let settings: GlobalSettings
        let fontSize: Double
        let lineHeight: Double
        let headerVisible: Bool
        let followsSourceSVG: Bool
        let bubbleScale: Double
        let bubbleTextScale: Double
        private let stores = ReadingSettingsStoresSnapshot()

        init(_ settings: GlobalSettings) {
            self.settings = settings
            fontSize = settings.readerFontSize
            lineHeight = settings.lineHeightMultiple
            headerVisible = settings.readerHeaderVisible
            followsSourceSVG = settings.commentBubbleFollowsSourceSVG
            bubbleScale = settings.commentBubbleScale
            bubbleTextScale = settings.commentBubbleTextScale
        }

        func restore() {
            settings.readerFontSize = fontSize
            settings.lineHeightMultiple = lineHeight
            settings.readerHeaderVisible = headerVisible
            settings.commentBubbleFollowsSourceSVG = followsSourceSVG
            settings.commentBubbleScale = bubbleScale
            settings.commentBubbleTextScale = bubbleTextScale
            stores.restore()
            ReaderConfig.shared.syncFromGlobalSettings()
        }
    }
}
