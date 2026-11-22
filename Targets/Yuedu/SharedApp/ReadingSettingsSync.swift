import SwiftUI

/// One 排版生效範圍 row of the reading setup as it was last set on a device — what
/// iCloud carries so every device reads with the setup changed on any of them
/// (2026-09-29). One record per row, so the font size changed here and the line height
/// changed there both survive the merge.
///
/// A snapshot taken when the row is set, not the live settings read at sync time:
/// switching the appearance theme puts that theme's own setup on, and a sync that read
/// the live settings would hand it to the other devices as if it had been set.
struct ReadingSettingSyncRecord: Codable, Equatable, Sendable {
    /// `ReadingSettingsScopeItem.rawValue`.
    var item: String
    /// The row's fields, and nothing else.
    var values: AppearanceThemeReadingSettings
    /// When it was set: the merge clock.
    var editedAt: Date
}

/// Which kind of device a reading layout was set on. Layout syncs between devices of one
/// kind only (maintainer, 2026-11-22, FB-244): a reader with an iPad and an iPhone sets
/// each for its own screen, and until then a size or a margin set on one landed on the
/// other at the next sync.
enum ReadingLayoutDeviceKind: String, CaseIterable, Sendable {
    case phone
    case pad

    /// An iPad app running on a Mac is an iPad.
    @MainActor
    static var current: Self {
        if ProcessInfo.processInfo.isiOSAppOnMac { return .pad }
        switch UIDevice.current.userInterfaceIdiom {
        case .pad, .mac: return .pad
        default: return .phone
        }
    }
}

/// The two sets the synced rows fall into, each a cloud record of its own.
enum ReadingSettingSyncPartition: String, CaseIterable, Sendable {
    /// Rows every device of the account wears.
    case shared
    /// Rows only devices of this one's kind wear: one record per `ReadingLayoutDeviceKind`.
    case layout

    /// The rows that set type and page for a screen: what a reader means by 排版, and what
    /// has a different right answer on a phone and on a tablet. 閱讀樣式 goes with them —
    /// it names the style those rows were set by.
    ///
    /// The rest say how things look or what gets marked, not how the page is set, and stay
    /// with every device: 文字顏色, 閱讀背景, 段評氣泡, 對話氣泡, 正則高亮, 文字底線.
    static func isLayout(_ item: ReadingSettingsScopeItem) -> Bool {
        switch item {
        case .font, .fontSize, .bold, .writingMode, .lineSpacing, .letterSpacing,
             .paragraphSpacing, .firstLineIndent, .textAlignment, .pageMargins, .bottomJustify,
             .headerFooter, .chapterTitle, .pageTurn, .readingStyle:
            return true
        case .textColor, .background, .commentBubble, .dialogueBubble, .regexHighlight,
             .textUnderline:
            return false
        }
    }

    /// Whether the row named `item` (a `ReadingSettingsScopeItem` raw value) is this set's.
    /// A row this build cannot name is a newer build's, and is passed on with the shared
    /// ones as it always was; the sync leaves a layout record holding one alone
    /// (`ICloudSyncManager`, 3c).
    func holds(_ item: String) -> Bool {
        let isLayout = ReadingSettingsScopeItem(rawValue: item).map(Self.isLayout) ?? false
        return isLayout == (self == .layout)
    }
}

extension GlobalSettings {
    nonisolated static let readingSettingSyncRecordsKey = "yd_reading_setting_sync_records"

    /// Each row as last set here or brought here from another device, in row order.
    /// A row never set since this sync began has none.
    var readingSettingSyncRecords: [ReadingSettingSyncRecord] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.readingSettingSyncRecordsKey) else { return [] }
            do {
                return try JSONDecoder().decode([ReadingSettingSyncRecord].self, from: data)
            } catch {
                AppLogger.error("⟐ synced reading settings unreadable", error: error)
                return []
            }
        }
        set {
            do {
                let sorted = newValue.sorted { $0.item < $1.item }
                UserDefaults.standard.set(try JSONEncoder().encode(sorted), forKey: Self.readingSettingSyncRecordsKey)
            } catch {
                AppLogger.error("⟐ synced reading settings not stored", error: error)
            }
        }
    }

    /// Notes the rows `edit` sets — one field, from `recordReadingSettingEdit` — as this
    /// device's latest setting of them. Every reading setting is written through there:
    /// the reader's panels, 閱讀設定, 綁定閱讀主題, an import of the user's.
    func noteReadingSettingSync(_ edit: AppearanceThemeReadingSettings, now: Date = Date()) {
        var items = edit.items
        if items.contains(.background), !choosesReaderBackground(edit) {
            items.remove(.background)
        }
        guard !items.isEmpty else { return }
        let snapshot = syncedReadingSnapshot()
        var records = Dictionary(uniqueKeysWithValues: readingSettingSyncRecords.map { ($0.item, $0) })
        for item in items {
            records[item.rawValue] = ReadingSettingSyncRecord(
                item: item.rawValue,
                values: snapshot.restricted(to: [item]),
                editedAt: now
            )
        }
        readingSettingSyncRecords = Array(records.values)
    }

    /// Whether a background edit is the user choosing one. The built-in background
    /// alone is not while 跟隨裝置深淺色 or 綁定閱讀主題 decides it — the reader sets it
    /// for the appearance by itself, and every device does that for its own.
    func choosesReaderBackground(_ edit: AppearanceThemeReadingSettings) -> Bool {
        if edit.followsSystemTheme != nil
            || edit.bindsAppearanceReaderTheme != nil
            || edit.boundLightReaderTheme != nil
            || edit.boundDarkReaderTheme != nil
            || edit.readerBackgroundID != nil {
            return true
        }
        return edit.readerTheme != nil && !readerFollowSystemTheme && !appearanceBindReaderTheme
    }

    /// The live setup as it syncs. The header/footer layout has its own record
    /// (`reader_bar_layout`), and so has which bubble is picked (`comment_bubble_selection`,
    /// ignored on the way in by `applyReadingSettingsSync`). The built-in background is
    /// left out while 跟隨裝置深淺色 or 綁定閱讀主題 decides it.
    private func syncedReadingSnapshot() -> AppearanceThemeReadingSettings {
        var snapshot = currentReadingSettingsSnapshot()
        snapshot.barLayout = nil
        if readerFollowSystemTheme || appearanceBindReaderTheme {
            snapshot.readerTheme = nil
        }
        return snapshot
    }

    /// Wears the rows iCloud merged in from other devices for one set — the ones that
    /// differ from what this device had — recorded where each comes from, as a setting
    /// made here would be, so the next theme sync keeps them. They stay the other
    /// device's: none is noted again, which would make every device claim the newest on
    /// each sync.
    ///
    /// Only `partition`'s rows are replaced: the other set has a merge of its own, and
    /// rows dropped here would read as deleted on this device at the next sync. A row of
    /// the other set found in this one's record is not worn — a layout row in the shared
    /// record would be another kind of device's.
    @MainActor
    func applyReadingSettingsSync(_ merged: [ReadingSettingSyncRecord], in partition: ReadingSettingSyncPartition) {
        let stored = readingSettingSyncRecords
        let local = Dictionary(
            stored.filter { partition.holds($0.item) }.map { ($0.item, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let strays = merged.filter { !partition.holds($0.item) }
        if !strays.isEmpty {
            AppLogger.error("⟐ synced reading settings: \(strays.map(\.item)) not in the \(partition.rawValue) set; not worn")
        }
        let own = merged.filter { partition.holds($0.item) }
        let arrived = own.filter { local[$0.item] != $0 }
        readingSettingSyncRecords = stored.filter { !partition.holds($0.item) } + own
        guard !arrived.isEmpty else { return }

        var values = AppearanceThemeReadingSettings()
        for record in arrived {
            values = values.overlaid(with: record.values)
        }
        values.barLayout = nil
        if var bubble = values.commentBubble {
            // Which bubble is picked syncs through `comment_bubble_selection`.
            bubble.presetMode = commentBubblePresetMode.rawValue
            bubble.customStyleID = commentBubbleSelectedCustomStyleID
            values.commentBubble = bubble
        }

        let wasApplying = isApplyingReadingSettingsSync
        isApplyingReadingSettingsSync = true
        defer { isApplyingReadingSettingsSync = wasApplying }
        do {
            try writeReadingSettings(values, origin: .theme)
        } catch {
            AppLogger.error("⟐ synced reading settings not fully applied", error: error)
        }
        // `writeReadingSettings` stores the built-in background without the edit the
        // reader would record for it, so it is recorded here.
        if let theme = values.readerTheme {
            recordReadingSettingEdit { $0.readerTheme = theme }
        }
    }
}
