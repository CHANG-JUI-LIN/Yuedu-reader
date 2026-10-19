import Foundation

/// One-time rewrites of stored data for saved reading backgrounds and for how theme packs
/// look in dark mode (2026-09-29). Runs at the top of `GlobalSettings.init`, on the raw
/// stores, before anything loads them.
///
/// 1. **Saved backgrounds.** The single custom slot, and every stored reading setup that
///    named a custom background (全域, each built-in theme's own, each custom theme's and
///    the pack original it can be reset to), becomes a saved background, named after its
///    theme, referenced by id. Setups naming the same picture share one.
/// 2. **A pack's reading picture in dark mode.** An imported theme whose reading setup wore
///    a picture gets 綁定閱讀主題 on with both picks on that picture, so dark mode keeps
///    it instead of turning 黑色 — unless the user had already turned binding on there.
/// 3. **A pack's page pictures in dark mode.** An imported theme with a light page picture
///    and no dark one shows the light one in dark mode, dimmed.
/// 4. **A pack's background named after the pack**, on devices where step 1 named it
///    自訂背景 — see `renamePackBackgroundsLeftWithTheDefaultName`.
@MainActor
enum ReaderBackgroundMigration {
    static let savedBackgroundsDoneKey = "yd_migrated_reader_saved_backgrounds_v1"
    static let packDarkPagesDoneKey = "yd_migrated_pack_dark_page_backgrounds_v1"
    static let packBackgroundNamesDoneKey = "yd_migrated_pack_background_names_v1"
    static let legacyModeKey = "yd_reader_custom_background_mode"
    static let legacyColorKey = "yd_reader_custom_background_color_hex"
    static let legacyImageKey = "yd_reader_custom_background_image_file_name"

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        measure: @escaping (String) -> ReaderBackgroundPicture? = GlobalSettings.readerBackgroundPicture(fileName:)
    ) {
        if !defaults.bool(forKey: savedBackgroundsDoneKey) {
            migrateSavedBackgrounds(defaults: defaults, now: now, measure: measure)
            defaults.set(true, forKey: savedBackgroundsDoneKey)
        }
        if !defaults.bool(forKey: packDarkPagesDoneKey) {
            migratePackDarkPages(defaults: defaults)
            defaults.set(true, forKey: packDarkPagesDoneKey)
        }
        if !defaults.bool(forKey: packBackgroundNamesDoneKey) {
            renamePackBackgroundsLeftWithTheDefaultName(defaults: defaults, now: now)
            defaults.set(true, forKey: packBackgroundNamesDoneKey)
        }
    }

    // MARK: - 1 & 2

    private static func migrateSavedBackgrounds(
        defaults: UserDefaults,
        now: Date,
        measure: @escaping (String) -> ReaderBackgroundPicture?
    ) {
        var library = Library(
            backgrounds: GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults),
            now: now,
            measure: measure
        )
        let defaultName = localized("自訂背景")
        let overrides = (defaults.dictionary(forKey: "yd_reader_text_color_overrides") as? [String: Int] ?? [:])
            .mapValues { UInt32(clamping: $0) }

        // Themes first, so a background they share with the stores below is named after
        // the theme. The old applier copied a pack's picture into the live slot, and
        // with the slot taken first the pack's background kept the slot's name, 自訂背景.
        // Each custom theme's, and the pack original it was imported with.
        if var themes = decode([AppearanceCustomTheme].self, key: GlobalSettings.customAppearanceThemesKey, defaults) {
            var changed = false
            for index in themes.indices {
                let theme = themes[index]
                let isPack = theme.originalExtras != nil
                if var reading = theme.extras?.reading,
                   library.migrate(&reading, name: theme.name, bindsToPicture: isPack) {
                    themes[index].extras?.reading = reading
                    changed = true
                }
                if var reading = theme.originalExtras?.reading,
                   library.migrate(&reading, name: theme.name, bindsToPicture: isPack) {
                    themes[index].originalExtras?.reading = reading
                    changed = true
                }
            }
            if changed { encode(themes, key: GlobalSettings.customAppearanceThemesKey, defaults) }
        }

        // 全域.
        if var global = decode(AppearanceThemeReadingSettings.self, key: GlobalSettings.globalReadingKey, defaults) {
            if library.migrate(&global, name: defaultName, bindsToPicture: false) {
                encode(global, key: GlobalSettings.globalReadingKey, defaults)
            }
        }

        // Each built-in theme's own.
        if var builtIns = decode(
            [String: AppearanceThemeReadingSettings].self,
            key: GlobalSettings.builtInThemeReadingKey,
            defaults
        ) {
            var changed = false
            for themeID in builtIns.keys.sorted() {
                guard var reading = builtIns[themeID],
                      library.migrate(&reading, name: defaultName, bindsToPicture: false) else { continue }
                builtIns[themeID] = reading
                changed = true
            }
            if changed { encode(builtIns, key: GlobalSettings.builtInThemeReadingKey, defaults) }
        }

        // The live slot: worn when its mode was anything but none.
        let legacyMode = defaults.string(forKey: legacyModeKey) ?? ReaderCustomBackgroundMode.none.rawValue
        if legacyMode != ReaderCustomBackgroundMode.none.rawValue {
            let slot = AppearanceThemeReadingSettings.CustomBackground(
                mode: legacyMode,
                colorHex: (defaults.object(forKey: legacyColorKey) as? Int).map { UInt32(clamping: $0) },
                imageFileName: defaults.string(forKey: legacyImageKey)
            )
            let worn = defaults.string(forKey: "yd_reader_theme") ?? ReaderTheme.white.rawValue
            if let id = library.adopt(slot, name: defaultName, textColorHex: overrides[worn]) {
                defaults.set(id.uuidString, forKey: GlobalSettings.readerCustomBackgroundIDKey)
            }
        }
        for key in [legacyModeKey, legacyColorKey, legacyImageKey] {
            defaults.removeObject(forKey: key)
        }

        GlobalSettings.saveReaderCustomBackgrounds(library.backgrounds, defaults: defaults)
    }

    /// The saved list while it is being built, deduplicating as it goes.
    struct Library {
        var backgrounds: [ReaderCustomBackground]
        let now: Date
        let measure: (String) -> ReaderBackgroundPicture?

        /// Replaces `reading`'s old custom background with a saved one. Returns whether
        /// `reading` changed.
        mutating func migrate(
            _ reading: inout AppearanceThemeReadingSettings,
            name: String,
            bindsToPicture: Bool
        ) -> Bool {
            guard let legacy = reading.customBackground else { return false }
            reading.customBackground = nil
            let worn = reading.readerTheme ?? ReaderTheme.white.rawValue
            guard let id = adopt(legacy, name: name, textColorHex: reading.textColorOverrides?[worn]) else {
                reading.readerBackgroundID = reading.readerBackgroundID ?? ""
                return true
            }
            reading.readerBackgroundID = id.uuidString
            // A pack's reading picture: kept in dark mode too, unless the user set the
            // binding up there already.
            if bindsToPicture,
               backgrounds.first(where: { $0.id == id })?.isImage == true,
               reading.bindsAppearanceReaderTheme != true {
                reading.bindsAppearanceReaderTheme = true
                reading.boundLightReaderTheme = ReaderBoundTheme.custom(id).storageValue
                reading.boundDarkReaderTheme = ReaderBoundTheme.custom(id).storageValue
                reading.followsSystemTheme = false
            }
            return true
        }

        /// The saved background for an old custom one — an existing one showing the same
        /// picture or colour, else a new one. Nil for none, or a picture whose file is gone.
        mutating func adopt(
            _ legacy: AppearanceThemeReadingSettings.CustomBackground,
            name: String,
            textColorHex: UInt32?
        ) -> UUID? {
            guard let mode = ReaderCustomBackgroundMode(rawValue: legacy.mode) else { return nil }
            switch mode {
            case .image:
                guard let fileName = legacy.imageFileName, !fileName.isEmpty else { return nil }
                if let existing = backgrounds.first(where: { $0.imageFileName == fileName }) {
                    return existing.id
                }
                guard let picture = measure(fileName) else {
                    AppLogger.error("⟐ old reading background picture missing, not kept", context: ["file": fileName])
                    return nil
                }
                return add(ReaderCustomBackground(
                    name: ReaderCustomBackgroundLibrary.unusedName(base: name, among: backgrounds),
                    colorHex: picture.averageColorHex,
                    imageFileName: fileName,
                    textColorHex: textColorHex,
                    isDark: picture.isDark
                ))
            case .color:
                let colorHex = legacy.colorHex ?? 0xF4F5F7
                if let existing = backgrounds.first(where: { !$0.isImage && $0.colorHex == colorHex }) {
                    return existing.id
                }
                return add(ReaderCustomBackground(
                    name: ReaderCustomBackgroundLibrary.unusedName(base: name, among: backgrounds),
                    colorHex: colorHex,
                    textColorHex: textColorHex,
                    isDark: ReaderBackgroundTone.isDark(rgbHex: colorHex)
                ))
            case .none:
                return nil
            }
        }

        private mutating func add(_ background: ReaderCustomBackground) -> UUID {
            backgrounds = ReaderCustomBackgroundLibrary.upserting(background, into: backgrounds, now: now)
            return background.id
        }
    }

    // MARK: - 3

    private static func migratePackDarkPages(defaults: UserDefaults) {
        guard var themes = decode(
            [AppearanceCustomTheme].self,
            key: GlobalSettings.customAppearanceThemesKey,
            defaults
        ) else { return }
        var changed = false
        for index in themes.indices where themes[index].originalExtras != nil {
            let before = themes[index]
            themes[index].extras?.pageBackgrounds = reusingLightImagesInDark(before.extras?.pageBackgrounds)
            themes[index].originalExtras?.pageBackgrounds = reusingLightImagesInDark(before.originalExtras?.pageBackgrounds)
            // The legacy slot `loadCustomAppearanceThemes` folds into extras on load.
            themes[index].pageBackgrounds = reusingLightImagesInDark(before.pageBackgrounds)
            changed = changed || themes[index] != before
        }
        if changed { encode(themes, key: GlobalSettings.customAppearanceThemesKey, defaults) }
    }

    // MARK: - 4

    /// Step 1 used to take the live slot before the themes, so on a device that ran it
    /// then, a pack's background kept the slot's name, 自訂背景, instead of the pack's.
    /// Renamed once: only a pack's own background — the one its original setup names —
    /// and only while it still has a name the migration gives. A name the user typed, and
    /// a background they made and wore under the pack, are left alone.
    ///
    /// Only devices that ran a build from 2026-09-29 have anything to rename; for every
    /// other device it finds nothing. Can go once no such build is in use.
    private static func renamePackBackgroundsLeftWithTheDefaultName(defaults: UserDefaults, now: Date) {
        guard let themes = decode([AppearanceCustomTheme].self, key: GlobalSettings.customAppearanceThemesKey, defaults) else {
            return
        }
        let defaultName = localized("自訂背景")
        var backgrounds = GlobalSettings.loadReaderCustomBackgrounds(defaults: defaults)
        var renamed = Set<UUID>()
        for theme in themes where theme.originalExtras != nil {
            guard let id = theme.originalExtras?.reading?.readerBackgroundID.flatMap(UUID.init(uuidString:)),
                  !renamed.contains(id),
                  var background = backgrounds.first(where: { $0.id == id }),
                  isDefaultName(background.name, base: defaultName) else { continue }
            background.name = ReaderCustomBackgroundLibrary.unusedName(
                base: theme.name,
                among: backgrounds.filter { $0.id != id }
            )
            // Stamped like any edit, so iCloud takes the new name to the other devices.
            backgrounds = ReaderCustomBackgroundLibrary.upserting(background, into: backgrounds, now: now)
            renamed.insert(id)
        }
        guard !renamed.isEmpty else { return }
        GlobalSettings.saveReaderCustomBackgrounds(backgrounds, defaults: defaults)
    }

    /// `base`, or `base 2`, `base 3`… — the names `unusedName` hands out.
    private static func isDefaultName(_ name: String, base: String) -> Bool {
        guard name != base else { return true }
        guard name.hasPrefix(base + " ") else { return false }
        return Int(name.dropFirst(base.count + 1)) != nil
    }

    // MARK: - Helpers

    static func reusingLightImagesInDark(
        _ configs: [String: AppearancePageBackgroundConfig]?
    ) -> [String: AppearancePageBackgroundConfig]? {
        configs?.mapValues { config in
            var config = config
            config.reuseLightImageInDarkIfMissing()
            return config
        }
    }

    // MARK: - Stores

    private static func decode<Value: Decodable>(_ type: Value.Type, key: String, _ defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLogger.error("⟐ store unreadable, left as it was", error: error, context: ["key": key])
            return nil
        }
    }

    private static func encode<Value: Encodable>(_ value: Value, key: String, _ defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLogger.error("⟐ store not rewritten", error: error, context: ["key": key])
        }
    }
}
