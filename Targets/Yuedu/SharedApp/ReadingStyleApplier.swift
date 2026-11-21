import Foundation
import YueduCoreText

/// 閱讀樣式: applying, saving and telling whether the reader still wears one.
///
/// A style adds no way of writing settings. Applying one is an import into the reading
/// setup — `writeReadingSettings`, recorded per row where each row comes from (the worn
/// theme, the shared setup, or the open book's own) — so a style travels and syncs
/// exactly as the same values set by hand would.
///
/// Whether the reader may apply or save one (Pro) is asked where it is tapped, never
/// here: a theme switch, another device or a lapsed subscription still wears what is
/// stored.
extension GlobalSettings {
    /// The name of the style last applied, or nil when there is none or it was deleted.
    var appliedReadingStyleName: String? {
        guard let id = readerReadingStyleID else { return nil }
        if let builtIn = ReadingStyleLibrary.builtIn(id: id) { return localized(builtIn.nameKey) }
        return customReadingStyles.first { $0.id == id }?.name
    }

    /// A built-in style: its typesetting rows go on 自動, where the style is laid over the
    /// book's 排版基準 — so the rows it does not name follow the book — and the rest of what
    /// it names (排版方向, the reading background) is set outright.
    func applyReadingStyle(_ style: BuiltInReadingStyle) throws {
        rememberSetupBeforeStyle()
        if let family = style.downloadableFamily {
            // A system face iOS fetches on demand. Until it arrives the text is drawn in
            // the default one; the reader lays out again when `CJKFontInstaller` posts.
            CJKFontInstaller.shared.ensure(family)
        }
        var reading = style.values(for: readingBaseline)
        for item in ReadingBaseline.items { reading.clear(item) }
        // 跟隨裝置深淺色 and 綁定閱讀主題 pick the built-in background by themselves, and
        // would put theirs back on the next appearance change.
        let background = (readerFollowSystemTheme || appearanceBindReaderTheme) ? nil : reading.readerTheme
        reading.readerTheme = background
        reading.automaticItems = Dictionary(uniqueKeysWithValues: ReadingBaseline.items.map { ($0.rawValue, true) })
        reading.readingStyleID = style.id
        if let background {
            // The writer stores the built-in background without the edit the reader
            // would record for it. Recorded first: the writer wears the setup again
            // for the rows on 自動, and would put the stored background back.
            recordReadingSettingEdit { $0.readerTheme = background }
        }
        try writeReadingSettings(reading, origin: .userImport)
    }

    /// A saved style: every row it holds, as the numbers it was saved with.
    func applyReadingStyle(_ style: ReadingStyle) throws {
        rememberSetupBeforeStyle()
        if let background = style.values.readerTheme {
            // As above: the writer does not record the built-in background itself.
            recordReadingSettingEdit { $0.readerTheme = background }
        }
        try writeReadingSettings(style.values, origin: .userImport)
    }

    // MARK: - 未套用

    nonisolated static let setupBeforeReadingStyleKey = "yd_reading_setup_before_style"

    /// What was on screen before the first style was applied, so 未套用 can put it back.
    /// Kept through a change from one style to another: 未套用 goes back to the reader's
    /// own setup, not to the style before.
    private func rememberSetupBeforeStyle() {
        guard readerReadingStyleID == nil else { return }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(currentReadingSettingsSnapshot()),
                                      forKey: Self.setupBeforeReadingStyleKey)
        } catch {
            AppLogger.error("⟐ setup before the reading style not kept", error: error)
        }
    }

    private var setupBeforeReadingStyle: AppearanceThemeReadingSettings? {
        guard let data = UserDefaults.standard.data(forKey: Self.setupBeforeReadingStyleKey) else { return nil }
        do {
            return try JSONDecoder().decode(AppearanceThemeReadingSettings.self, from: data)
        } catch {
            AppLogger.error("⟐ setup before the reading style unreadable", error: error)
            return nil
        }
    }

    /// 未套用: takes the style off and puts back what the rows it set showed before it —
    /// only those rows, so a setting changed since that the style never touched stays.
    /// With nothing kept from before (the style came from another device, or with a
    /// theme), the page stays as it is and only stops being called by the style's name.
    func removeReadingStyle() throws {
        guard let id = readerReadingStyleID else { return }
        var rows: Set<ReadingSettingsScopeItem>
        if let builtIn = ReadingStyleLibrary.builtIn(id: id) {
            rows = ReadingBaseline.items.union(builtIn.values(for: readingBaseline).items)
        } else {
            rows = Set(ReadingSettingsScopeItem.allCases)
        }
        rows.remove(.readingStyle)
        var restored = (setupBeforeReadingStyle ?? AppearanceThemeReadingSettings()).restricted(to: rows)
        if readerFollowSystemTheme || appearanceBindReaderTheme {
            // The built-in background is the appearance's to pick, as when a style is applied.
            restored.readerTheme = nil
        }
        restored.readingStyleID = ""
        if let background = restored.readerTheme {
            recordReadingSettingEdit { $0.readerTheme = background }
        }
        try writeReadingSettings(restored, origin: .userImport)
        UserDefaults.standard.removeObject(forKey: Self.setupBeforeReadingStyleKey)
    }

    /// Whether what is on screen is no longer the applied style: a row it set was
    /// changed by hand since.
    var isReadingStyleModified: Bool {
        guard let id = readerReadingStyleID else { return false }
        var shown = currentReadingSettingsSnapshot()
        var expected: AppearanceThemeReadingSettings
        if let builtIn = ReadingStyleLibrary.builtIn(id: id) {
            guard ReadingBaseline.items.isSubset(of: readerAutomaticItems) else { return true }
            expected = builtIn.values(for: readingBaseline)
            for item in ReadingBaseline.items { expected.clear(item) }
        } else if let custom = customReadingStyles.first(where: { $0.id == id }) {
            expected = custom.values
        } else {
            return false
        }
        if readerFollowSystemTheme || appearanceBindReaderTheme {
            // The built-in background is the appearance's, not the style's or the reader's.
            expected.readerTheme = nil
            shown.readerTheme = nil
        }
        // The header/footer layout is compared as stored; the rest field by field.
        return shown.overlaid(with: expected) != shown
    }

    /// Saves what is on screen as a style of the reader's own and wears it: every row
    /// becomes its own numbers, none left on 自動, so the style reads the same in any book.
    @discardableResult
    func saveCurrentReadingSetupAsStyle(named name: String) -> ReadingStyle {
        var values = currentReadingSettingsSnapshot()
        values.customBackground = nil
        values.automaticItems = Dictionary(uniqueKeysWithValues: ReadingBaseline.items.map { ($0.rawValue, false) })
        let style = ReadingStyle(name: name, values: values)
        var stored = style
        stored.values.readingStyleID = style.id
        customReadingStyles.append(stored)

        readerAutomaticItems = []
        readerReadingStyleID = stored.id
        // Whole, not only the flags: the stored fields of a row that was on 自動 date from
        // before it was, and are what an explicit row wears.
        recordReadingSettingEdit { $0 = stored.values }
        return stored
    }

    func renameCustomReadingStyle(id: String, to name: String) {
        guard let index = customReadingStyles.firstIndex(where: { $0.id == id }) else { return }
        customReadingStyles[index].name = name
    }

    /// The setup stays as it is on screen; it only stops being called by the style's name.
    func deleteCustomReadingStyle(id: String) {
        customReadingStyles.removeAll { $0.id == id }
    }

    // MARK: - 只套用到這本書

    /// Wears `override` — the open book's own setup — over the theme's and the shared
    /// one, and hands later edits to `persist`. Called by the reader when a book opens.
    func setBookReadingOverride(
        _ override: AppearanceThemeReadingSettings?,
        bookID: UUID,
        persist: @escaping (AppearanceThemeReadingSettings?) -> Void
    ) {
        bookReadingOverrideBookID = bookID
        bookReadingOverride = override
        persistBookReadingOverride = persist
        synchronizeReadingSettings()
    }

    /// The book's reader closed for good: the library's setup is worn again.
    func clearBookReadingOverride(bookID: UUID) {
        guard bookReadingOverrideBookID == bookID else { return }
        let hadOverride = bookReadingOverride != nil
        bookReadingOverrideBookID = nil
        bookReadingOverride = nil
        persistBookReadingOverride = nil
        if hadOverride { synchronizeReadingSettings() }
    }

    /// 只套用到這本書 on: the open book gets a setup of its own, empty at first, so
    /// nothing moves until a style is applied or a setting changed. Off: the book's own
    /// setup is dropped and it reads like the rest of the library again.
    func setReadingSetupIsThisBooksOwn(_ isOwn: Bool) {
        guard bookReadingOverrideBookID != nil, (bookReadingOverride != nil) != isOwn else { return }
        bookReadingOverride = isOwn ? AppearanceThemeReadingSettings() : nil
        persistBookReadingOverride?(bookReadingOverride)
        if !isOwn { synchronizeReadingSettings() }
    }
}
