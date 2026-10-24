import Foundation

extension GlobalSettings {
    /// 重置為默認: everything 外觀主題 sets goes back to how the app ships — the theme in
    /// both appearances, the colours edited on the built-in themes, the page backgrounds,
    /// the card artwork, the tab bar and its icons,
    /// the global font, the interface effects, the reader's interface and chrome, and the
    /// launch screen. Saved themes and packs are kept, and so is 閱讀設定: selecting a pack
    /// again brings its look back, and reading is not appearance.
    ///
    /// Under this name it used to clear the page backgrounds alone (2026-09-29).
    func resetAppearanceToDefault() {
        // Leaving every custom theme first hands the user's own values back and drops the
        // baseline, so nothing below is recorded on a theme or restored over later.
        appearanceUsesSeparateDarkTheme = false
        appearanceThemeID = Self.defaultAppearanceThemeID
        appearanceDarkThemeID = Self.defaultAppearanceThemeID
        appearanceFollowsSystem = Self.defaultAppearanceFollowsSystem
        appearanceBuiltInThemeColors = [:]

        resetAllPageBackgrounds()
        appearanceCardBackground = nil
        rootTabIconAssets = []
        rootTabIconSize = Self.defaultRootTabIconSize
        rootTabHidesLabels = false
        rootTabVisibleIDs = Self.defaultRootTabVisibleIDs
        selectedGlobalFontPostScript = nil
        interfaceGlowIntensity = Self.defaultInterfaceGlowIntensity
        interfaceGlowColor = nil
        interfaceFrostedGlass = Self.defaultInterfaceFrostedGlass
        interfaceGlassTransparency = Self.defaultInterfaceGlassTransparency
        interfaceGlassCards = Self.defaultInterfaceGlassCards
        readerChromeColors = [:]
        readerChromeHiddenIDs = []
        readerChromeIcons = []
        launchImageEnabled = false
        launchImageLightFileName = nil
        launchImageDarkFileName = nil
    }
}
