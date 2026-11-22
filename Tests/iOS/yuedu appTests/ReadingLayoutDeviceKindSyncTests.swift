import Foundation
import Testing
@testable import yuedu_app

/// 排版 syncs between devices of one kind only (FB-244, 2026-11-22): an iPhone's layout
/// reaches iPhones, an iPad's reaches iPads, and the rows that are not layout still reach
/// every device. Each pass here is step 3c of `ICloudSyncManager.sync()` — the record
/// names, the merge and the apply it runs — against a cloud held in memory.
@Suite("排版依裝置種類同步", .serialized)
@MainActor
struct ReadingLayoutDeviceKindSyncTests {
    private typealias Row = ReadingSettingSyncRecord

    /// A font size set on an iPhone is not worn by an iPad, whose own rows and values stay
    /// as they were; the bubble size set with it, which is not layout, is.
    @Test func aLayoutSetOnAnIPhoneIsNotWornByAnIPad() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.readingSettingSyncRecords = []
        settings.readerFontSize = fixture.fontSize + 1
        let padRows = settings.readingSettingSyncRecords
        #expect(padRows.contains { $0.item == "fontSize" })

        var cloud = Cloud()
        var padShadows = Shadows()
        Self.syncPass(kind: .pad, on: settings, shadows: &padShadows, cloud: &cloud)

        let phone = Device(kind: .phone, rows: [
            Self.fontSizeRow(fixture.fontSize + 9, at: Self.later),
            Self.bubbleRow(settings, scale: fixture.otherBubbleScale, at: Self.later),
        ])
        phone.sync(&cloud)
        Self.syncPass(kind: .pad, on: settings, shadows: &padShadows, cloud: &cloud)

        #expect(settings.readerFontSize == fixture.fontSize + 1)
        #expect(settings.readingSettingSyncRecords.first { $0.item == "fontSize" } == padRows.first { $0.item == "fontSize" })
        #expect(settings.commentBubbleScale == fixture.otherBubbleScale, "what is not layout still reaches every device")
        // Nor does the iPad's reach the iPhone on its next pass.
        phone.sync(&cloud)
        #expect(phone.rows.first { $0.item == "fontSize" }?.values.fontSize == fixture.fontSize + 9)
    }

    /// The same edit reaches another iPhone.
    @Test func aLayoutSetOnAnIPhoneIsWornByAnotherIPhone() throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.readingSettingSyncRecords = []
        settings.readerFontSize = fixture.fontSize + 1

        var cloud = Cloud()
        var shadows = Shadows()
        Self.syncPass(kind: .phone, on: settings, shadows: &shadows, cloud: &cloud)

        let other = Device(kind: .phone, rows: [Self.fontSizeRow(fixture.fontSize + 9, at: Self.later)])
        other.sync(&cloud)
        Self.syncPass(kind: .phone, on: settings, shadows: &shadows, cloud: &cloud)

        #expect(settings.readerFontSize == fixture.fontSize + 9)
        #expect(settings.readingSettingSyncRecords.first { $0.item == "fontSize" }?.editedAt == Self.later)
        settings.synchronizeReadingSettings()
        #expect(settings.readerFontSize == fixture.fontSize + 9)
    }

    /// The rows a build before the split stored decode as they are, and the first sync
    /// after the update leaves them and what the device wears alone — on either kind, and
    /// with the other kind's newer layout already in the cloud. Each goes up with the
    /// `editedAt` it had, not as a setting made now.
    @Test(arguments: ReadingLayoutDeviceKind.allCases)
    func rowsFromBeforeTheSplitAreKeptAndWornAsTheyWere(kind: ReadingLayoutDeviceKind) throws {
        let settings = GlobalSettings.shared
        let fixture = Fixture(settings)
        defer { fixture.restore() }
        settings.readerFontSize = 21
        settings.lineHeightMultiple = 1.7
        // As 3.0.2 (156) wrote them.
        let stored = #"""
        [{"item":"fontSize","values":{"fontSize":21},"editedAt":800000000},
         {"item":"lineSpacing","values":{"lineHeightMultiple":1.7},"editedAt":800000100},
         {"item":"regexHighlight","values":{"regexHighlights":[]},"editedAt":800000200}]
        """#
        UserDefaults.standard.set(Data(stored.utf8), forKey: GlobalSettings.readingSettingSyncRecordsKey)
        let before = settings.readingSettingSyncRecords
        #expect(before.map(\.item) == ["fontSize", "lineSpacing", "regexHighlight"])
        #expect(before.first?.editedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))

        var cloud = Cloud()
        let otherKind = ReadingLayoutDeviceKind.allCases.first { $0 != kind }!
        Device(kind: otherKind, rows: [Self.fontSizeRow(40, at: Self.later)]).sync(&cloud)
        var shadows = Shadows()
        Self.syncPass(kind: kind, on: settings, shadows: &shadows, cloud: &cloud)
        Self.syncPass(kind: kind, on: settings, shadows: &shadows, cloud: &cloud)

        #expect(settings.readingSettingSyncRecords == before)
        #expect(settings.readerFontSize == 21)
        #expect(settings.lineHeightMultiple == 1.7)
        let layout = cloud.blobs[ICloudSyncManager.readingSettingsRecordName(.layout, kind: kind)] ?? []
        #expect(Set(layout.map(\.id)) == ["fontSize", "lineSpacing"])
        #expect(layout.first { $0.id == "fontSize" }?.updatedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        let shared = cloud.blobs[ICloudSyncManager.readingSettingsRecordName(.shared, kind: kind)] ?? []
        #expect(shared.map(\.id) == ["regexHighlight"])
    }

    /// Each kind has records of its own, and none is one a build before the split syncs.
    @Test func eachKindHasItsOwnRecords() {
        let layout = ReadingLayoutDeviceKind.allCases.map { ICloudSyncManager.readingSettingsRecordName(.layout, kind: $0) }
        let bars = ReadingLayoutDeviceKind.allCases.map { ICloudSyncManager.readerBarLayoutRecordName(kind: $0) }
        let shared = ReadingLayoutDeviceKind.allCases.map { ICloudSyncManager.readingSettingsRecordName(.shared, kind: $0) }
        let shadows = ReadingLayoutDeviceKind.allCases.flatMap {
            [ICloudSyncManager.readingSettingsShadowKey(.layout, kind: $0), ICloudSyncManager.readerBarLayoutShadowKey(kind: $0)]
        }
        #expect(Set(layout + bars).count == 4)
        #expect(Set(shared).count == 1)
        #expect(Set(shadows).count == 4)
        let before = ["reading_settings_v2", "reader_bar_layout_v2", "icloud_readingSettings_v2", "icloud_readerBarLayout_v2"]
        #expect(Set(layout + bars + shared + shadows).isDisjoint(with: before))
    }

    /// Every row is in exactly one set, and the ones that set type and page are layout.
    @Test func everyRowIsInOneSet() {
        for item in ReadingSettingsScopeItem.allCases {
            let sets = ReadingSettingSyncPartition.allCases.filter { $0.holds(item.rawValue) }
            #expect(sets.count == 1, "\(item.rawValue)")
        }
        let layout = Set(ReadingSettingsScopeItem.allCases.filter { ReadingSettingSyncPartition.layout.holds($0.rawValue) })
        #expect(layout == [
            .font, .fontSize, .bold, .writingMode, .lineSpacing, .letterSpacing, .paragraphSpacing,
            .firstLineIndent, .textAlignment, .pageMargins, .bottomJustify, .headerFooter,
            .chapterTitle, .pageTurn, .readingStyle,
        ])
        #expect(ReadingSettingSyncPartition.shared.holds("a row of a later build"))
    }

    // MARK: - The cloud and the devices on it

    private struct Cloud {
        var blobs: [String: [FirestoreSyncRecord<Row>]] = [:]
    }

    private typealias Shadows = [String: [String: SyncShadowEntry]]

    /// One pass of 3c for a device of `kind` holding `rows`: what `mergeType` does for each
    /// of the two records, with `apply` standing for `applyLocally`.
    private static func syncPass(
        kind: ReadingLayoutDeviceKind,
        rows: [Row],
        shadows: inout Shadows,
        cloud: inout Cloud,
        apply: ([Row], ReadingSettingSyncPartition) -> Void
    ) {
        for partition in ReadingSettingSyncPartition.allCases {
            let name = ICloudSyncManager.readingSettingsRecordName(partition, kind: kind)
            let key = ICloudSyncManager.readingSettingsShadowKey(partition, kind: kind)
            let result = ICloudSyncManager.resolveMerge(
                local: rows.filter { partition.holds($0.item) },
                remote: cloud.blobs[name] ?? [],
                shadow: shadows[key] ?? [:],
                id: { $0.item },
                hash: { ICloudSyncManager.stableHash($0) },
                fallbackUpdatedAt: { $0.editedAt }
            )
            cloud.blobs[name] = ICloudSyncManager
                .cloudSyncRecords(values: result.values, shadow: result.shadow, id: { $0.item })
                .map { FirestoreSyncRecord(id: $0.id, value: $0.value, updatedAt: $0.updatedAt, deleted: $0.deleted) }
            if result.shouldApplyLocally { apply(result.values, partition) }
            shadows[key] = result.shadow
        }
    }

    /// A pass for the device under test: the app's own rows and its own apply.
    private static func syncPass(
        kind: ReadingLayoutDeviceKind,
        on settings: GlobalSettings,
        shadows: inout Shadows,
        cloud: inout Cloud
    ) {
        syncPass(kind: kind, rows: settings.readingSettingSyncRecords, shadows: &shadows, cloud: &cloud) {
            settings.applyReadingSettingsSync($0, in: $1)
        }
    }

    /// Another device of the account: only the rows it holds.
    private final class Device {
        let kind: ReadingLayoutDeviceKind
        var rows: [Row]
        private var shadows = Shadows()

        init(kind: ReadingLayoutDeviceKind, rows: [Row]) {
            self.kind = kind
            self.rows = rows
        }

        @MainActor
        func sync(_ cloud: inout Cloud) {
            var held = rows
            ReadingLayoutDeviceKindSyncTests.syncPass(kind: kind, rows: rows, shadows: &shadows, cloud: &cloud) { merged, partition in
                held = held.filter { !partition.holds($0.item) } + merged
            }
            rows = held
        }
    }

    private static let later = Date(timeIntervalSince1970: 1_900_000_000)

    private static func fontSizeRow(_ size: Double, at date: Date) -> Row {
        var values = AppearanceThemeReadingSettings()
        values.fontSize = size
        return Row(item: "fontSize", values: values, editedAt: date)
    }

    private static func bubbleRow(_ settings: GlobalSettings, scale: Double, at date: Date) -> Row {
        var values = AppearanceThemeReadingSettings()
        var bubble = settings.currentCommentBubbleSettings
        bubble.scale = scale
        values.commentBubble = bubble
        return Row(item: "commentBubble", values: values, editedAt: date)
    }

    /// Puts back the settings these tests set, then the stores and the sync rows — the
    /// writes that put the live values back note rows too.
    private final class Fixture {
        private let settings: GlobalSettings
        let fontSize: Double
        let lineHeight: Double
        let bubbleScale: Double
        private let stores = ReadingSettingsStoresSnapshot()

        @MainActor
        init(_ settings: GlobalSettings) {
            self.settings = settings
            fontSize = settings.readerFontSize
            lineHeight = settings.lineHeightMultiple
            bubbleScale = settings.commentBubbleScale
        }

        /// A bubble size the device does not have on.
        var otherBubbleScale: Double {
            let range = GlobalSettings.commentBubbleScaleRange
            return bubbleScale < range.upperBound ? range.upperBound : range.lowerBound
        }

        @MainActor
        func restore() {
            settings.readerFontSize = fontSize
            settings.lineHeightMultiple = lineHeight
            settings.commentBubbleScale = bubbleScale
            stores.restore()
            ReaderConfig.shared.syncFromGlobalSettings()
        }
    }
}
