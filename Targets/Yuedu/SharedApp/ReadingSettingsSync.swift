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

    /// Wears the rows iCloud merged in from other devices — the ones that differ from
    /// what this device had — recorded where each comes from, as a setting made here
    /// would be, so the next theme sync keeps them. They stay the other device's: none
    /// is noted again, which would make every device claim the newest on each sync.
    @MainActor
    func applyReadingSettingsSync(_ merged: [ReadingSettingSyncRecord]) {
        let local = Dictionary(uniqueKeysWithValues: readingSettingSyncRecords.map { ($0.item, $0) })
        let arrived = merged.filter { local[$0.item] != $0 }
        readingSettingSyncRecords = merged
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
