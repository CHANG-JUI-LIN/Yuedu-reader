import Foundation

/// Applies the non-colour half of an appearance theme, and puts the user's own
/// settings back when they leave it.
///
/// Before this existed, importing an appearance pack scattered its contents across
/// a dozen independent `GlobalSettings` keys, so selecting 默認 again reverted the
/// five theme colours and nothing else: the pack's tab icons, font, covers, glass
/// and bookshelf layout stayed put with no way to undo them.
///
/// The mechanism is a baseline rather than a per-setting override, so no read site
/// has to learn about themes: the first time a theme with extras is applied, the
/// user's current values are captured; selecting a theme that carries no extras
/// writes that capture back and discards it. Switching straight from one pack to
/// another keeps the original baseline, so the way out is always the way in.
extension GlobalSettings {
    private static let extrasBaselineKey = "yd_appearance_extras_baseline"

    /// The user's own values from before the first pack was applied, or nil when no
    /// pack is active.
    var appearanceExtrasBaseline: AppearanceThemeExtras? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.extrasBaselineKey) else {
                return nil
            }
            return try? JSONDecoder().decode(AppearanceThemeExtras.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: Self.extrasBaselineKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Self.extrasBaselineKey)
        }
    }

    /// The extras in force: the light slot's theme wins, and the dark slot is
    /// consulted only when the light one carries none — a pack selected in either
    /// slot takes effect, and a plain colour theme in one does not cancel the other.
    var activeAppearanceThemeExtras: AppearanceThemeExtras? {
        func extras(for id: String?) -> AppearanceThemeExtras? {
            guard let id, let theme = customAppearanceThemes.first(where: { $0.id == id }) else {
                return nil
            }
            guard let extras = theme.extras, !extras.isEmpty else { return nil }
            return extras
        }
        return extras(for: appearanceThemeID) ?? extras(for: appearanceDarkThemeID)
    }

    /// Called whenever the selected theme changes. Cheap and idempotent.
    func synchronizeAppearanceThemeExtras() {
        if let extras = activeAppearanceThemeExtras {
            if appearanceExtrasBaseline == nil {
                appearanceExtrasBaseline = captureAppearanceExtrasBaseline()
            }
            // A pack is a sparse override of the user's original settings, not
            // of the preceding pack. Restore first so omitted fields cannot
            // carry another theme's font, icons or effects into this one.
            if let baseline = appearanceExtrasBaseline {
                writeAppearanceExtras(baseline)
            }
            writeAppearanceExtras(extras)
        } else if let baseline = appearanceExtrasBaseline {
            writeAppearanceExtras(baseline)
            appearanceExtrasBaseline = nil
        }
    }

    /// Every field filled in, so restoring it sets all of them back.
    private func captureAppearanceExtrasBaseline() -> AppearanceThemeExtras {
        var baseline = AppearanceThemeExtras()
        baseline.tabIcons = Dictionary(
            uniqueKeysWithValues: rootTabIconAssets.map {
                ("\($0.tabID).\($0.slotRawValue)", $0.fileName)
            }
        )
        baseline.tabIconSize = rootTabIconSize
        baseline.hidesTabLabels = rootTabHidesLabels
        baseline.launchImageEnabled = launchImageEnabled
        baseline.launchImageLightFileName = launchImageLightFileName ?? ""
        baseline.launchImageDarkFileName = launchImageDarkFileName ?? ""
        baseline.defaultCoverLightFileNames = defaultCoverLightFileNames
        baseline.defaultCoverDarkFileNames = defaultCoverDarkFileNames
        baseline.forceDefaultCover = useDefaultCoverForAllBooks
        baseline.globalFontPostScript = selectedGlobalFontPostScript ?? ""
        baseline.frostedGlass = interfaceFrostedGlass
        baseline.glassTransparency = interfaceGlassTransparency
        baseline.glowIntensity = interfaceGlowIntensity
        baseline.bookshelfGridColumnCount = bookshelfGridColumnCount
        baseline.bookshelfCoverCornerRadius = bookshelfCoverCornerRadius
        baseline.readerInterface = appearanceReaderInterface.rawValue
        baseline.cardBackground = appearanceCardBackground
        return baseline
    }

    private func writeAppearanceExtras(_ extras: AppearanceThemeExtras) {
        if let icons = extras.tabIcons {
            // Assigned directly rather than through `importRootTabIcon`, which deletes the
            // icon it replaces — that would destroy the user's own artwork the first time a
            // pack was applied and leave the baseline pointing at files that no longer exist.
            rootTabIconAssets = icons.compactMap { key, fileName in
                let parts = key.split(separator: ".", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return RootTabIconAsset(
                    tabID: String(parts[0]),
                    slotRawValue: String(parts[1]),
                    fileName: fileName,
                    originalFileName: fileName,
                    addedAt: Date()
                )
            }
            .sorted { ($0.tabID, $0.slotRawValue) < ($1.tabID, $1.slotRawValue) }
        }
        if let size = extras.tabIconSize { rootTabIconSize = size }
        if let hidden = extras.hidesTabLabels { rootTabHidesLabels = hidden }
        if let enabled = extras.launchImageEnabled { launchImageEnabled = enabled }
        if let name = extras.launchImageLightFileName {
            launchImageLightFileName = name.isEmpty ? nil : name
        }
        if let name = extras.launchImageDarkFileName {
            launchImageDarkFileName = name.isEmpty ? nil : name
        }
        if let covers = extras.defaultCoverLightFileNames { defaultCoverLightFileNames = covers }
        if let covers = extras.defaultCoverDarkFileNames { defaultCoverDarkFileNames = covers }
        if let force = extras.forceDefaultCover { useDefaultCoverForAllBooks = force }
        if let font = extras.globalFontPostScript {
            selectedGlobalFontPostScript = font.isEmpty ? nil : font
        }
        if let frosted = extras.frostedGlass { interfaceFrostedGlass = frosted }
        if let transparency = extras.glassTransparency { interfaceGlassTransparency = transparency }
        if let glow = extras.glowIntensity { interfaceGlowIntensity = glow }
        if let columns = extras.bookshelfGridColumnCount { bookshelfGridColumnCount = columns }
        if let radius = extras.bookshelfCoverCornerRadius { bookshelfCoverCornerRadius = radius }
        if let raw = extras.readerInterface, let interface = AppearanceReaderInterface(rawValue: raw) {
            appearanceReaderInterface = interface
        }
        appearanceCardBackground = extras.cardBackground
    }
}
