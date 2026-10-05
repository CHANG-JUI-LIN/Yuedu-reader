import SwiftUI

/// What the reader wears in one of its two modes: a built-in reading background, painted
/// over by a saved one or by the appearance theme's palette.
struct ReaderBackgroundResolution: Equatable {
    /// The built-in background the reader sits on. Its chrome reads this: 黑色 is dark —
    /// which is why a dark saved background sits on 黑色 in light mode too.
    var theme: ReaderTheme
    var customBackground: ReaderCustomBackground?
    /// 跟隨外觀主題 under 綁定閱讀主題: the appearance theme's palette repaints the page.
    var paintsWithAppearanceTheme: Bool
}

extension GlobalSettings {
    /// The reader's mode as the scheme its picks and palettes are keyed by.
    var readerMode: ColorScheme { readerDarkMode ? .dark : .light }

    /// The one place the reading background is decided, for the reader and for what its
    /// panels say is on screen — from the reader's own mode (`readerDarkMode`), not the
    /// device's appearance (the user's call, 2026-09-30):
    ///
    /// - 綁定閱讀主題 on: the mode's pick, 淺色閱讀主題 or 深色閱讀主題.
    /// - off: light mode wears the built-in light background, or the saved one picked in
    ///   the reader whatever its tone; dark mode is 黑色. A saved background used to be
    ///   worn by the mode of its own tone, so making a dark one put the reader in dark
    ///   mode and left light mode without it.
    ///
    /// - Parameter wornTheme: the built-in background the reader sits on now. A light one
    ///   is the light mode's; from 黑色, the last light one used is.
    func readerBackgroundResolution(mode: ColorScheme, wornTheme: ReaderTheme) -> ReaderBackgroundResolution {
        let lightTheme = wornTheme == .night ? ReaderTheme.lastLightTheme : wornTheme
        let builtIn = ReaderBackgroundResolution(
            theme: mode == .dark ? .night : lightTheme,
            customBackground: nil,
            paintsWithAppearanceTheme: false
        )
        guard appearanceBindReaderTheme else {
            guard mode == .light, let background = wornReaderCustomBackground else { return builtIn }
            return Self.wearing(background, lightTheme: lightTheme)
        }
        switch boundReaderTheme(for: mode) {
        case .followAppearanceTheme:
            // The theme's own reading background — a pack's picture — is what the theme
            // looks like in the reader; only a theme without one is painted with its
            // palette. The pick used to paint the palette over a pack's picture.
            if let background = wornReaderCustomBackground {
                return Self.wearing(background, lightTheme: lightTheme)
            }
            var painted = builtIn
            painted.paintsWithAppearanceTheme = true
            return painted
        case .reading(let theme):
            return ReaderBackgroundResolution(theme: theme, customBackground: nil, paintsWithAppearanceTheme: false)
        case .custom(let id):
            // Deleted — here, or on another device before this one synced.
            guard let background = readerCustomBackground(id: id) else { return builtIn }
            return Self.wearing(background, lightTheme: lightTheme)
        }
    }

    /// A saved background sits on the built-in of its own tone — 黑色 under a dark one —
    /// whichever mode wears it.
    private static func wearing(
        _ background: ReaderCustomBackground,
        lightTheme: ReaderTheme
    ) -> ReaderBackgroundResolution {
        ReaderBackgroundResolution(
            theme: background.isDark ? .night : lightTheme,
            customBackground: background,
            paintsWithAppearanceTheme: false
        )
    }

    // MARK: - The reader's mode

    /// The mode as set by hand: the 深色／白天 button, a background picked in the reader.
    /// Set against the device's appearance it ends 跟隨裝置深淺色 — the two cannot both
    /// hold. Without 綁定閱讀主題, where no switch shows, a mode set back to the device's
    /// appearance follows it again.
    func setReaderDarkMode(_ isDark: Bool, deviceIsDark: Bool) {
        if appearanceBindReaderTheme {
            if isDark != deviceIsDark, readerFollowSystemTheme { readerFollowSystemTheme = false }
        } else {
            setReaderFollowsDeviceByItself(isDark == deviceIsDark)
        }
        if readerDarkMode != isDark { readerDarkMode = isDark }
    }

    /// The device's appearance, as the reader opens, as the scene comes back from the
    /// background, and whenever it changes. Following it, the reader takes it. Without
    /// 綁定閱讀主題 a mode set against the device holds until the device comes round to it,
    /// and follows from there.
    ///
    /// Nothing in the background, where the light／dark is the app-switcher snapshots'
    /// (`ScenePhase.showsDeviceAppearance`). The light snapshot of a dark device read as the
    /// device coming round to a reader set to 白天, and the dark one then took it to 深色 —
    /// on every trip out of the app (reported 2026-10-04).
    func alignReaderDarkMode(deviceIsDark: Bool, in phase: ScenePhase) {
        guard phase.showsDeviceAppearance else { return }
        // Nor while 外觀主題 previews its other slot: a reader left open under another tab
        // (iPad keeps the tab bar over it) took the preview for the device turning, and a
        // mode set against the device came back as following once the preview ended. The
        // preview ending hands the restored appearance back through here.
        guard appearanceSlotPreview == nil else { return }
        if readerFollowSystemTheme {
            if readerDarkMode != deviceIsDark { readerDarkMode = deviceIsDark }
        } else if !appearanceBindReaderTheme, readerDarkMode == deviceIsDark {
            setReaderFollowsDeviceByItself(true)
        }
    }

    /// 跟隨裝置深淺色, the switch the reader shows under 綁定閱讀主題.
    func setReaderFollowsDevice(_ follows: Bool, deviceIsDark: Bool) {
        if readerFollowSystemTheme != follows { readerFollowSystemTheme = follows }
        if follows, readerDarkMode != deviceIsDark { readerDarkMode = deviceIsDark }
    }

    /// A built-in background arriving in place of the one in use — from a theme's reading
    /// setup, another device's, the account's — says which mode that reader was in, where
    /// no binding decides the background: 黑色 is dark mode, unless a dark saved background
    /// sits on it. Only for one that arrives: a setup worn again names the background
    /// already in use, and the mode the user is in stays theirs.
    func adoptReaderDarkMode(from theme: ReaderTheme) {
        guard !appearanceBindReaderTheme else { return }
        let isDark = theme == .night && wornReaderCustomBackground?.isDark != true
        if readerDarkMode != isDark { readerDarkMode = isDark }
    }

    /// What the reader lets go of or takes up again by itself. Stored with the reading
    /// setup like any other value — a setup worn again must not put the old one back —
    /// but not noted as a setting made here: noted, every device would hand its own
    /// state to the others.
    private func setReaderFollowsDeviceByItself(_ follows: Bool) {
        guard readerFollowSystemTheme != follows else { return }
        let wasApplying = isApplyingReadingSettingsSync
        isApplyingReadingSettingsSync = true
        defer { isApplyingReadingSettingsSync = wasApplying }
        readerFollowSystemTheme = follows
    }

    // MARK: - Starting values

    /// The mode a reader with none stored starts in: read off what the mode used to be
    /// read from, so the update changes nothing on screen — 黑色 is dark mode, unless it
    /// is only what a dark saved background sits on.
    static func startingReaderDarkMode(
        stored: Bool?,
        theme: ReaderTheme,
        wornBackgroundIsDark: Bool,
        binds: Bool
    ) -> Bool {
        if let stored { return stored }
        return theme == .night && (binds || !wornBackgroundIsDark)
    }

    /// Whether the reader starts out following the device. One never given a background
    /// does. One that was keeps the mode it is in — an update must not flip it — and
    /// follows from the moment the device agrees with it (`alignReaderDarkMode`).
    static func startingReaderFollowsDevice(stored: Bool?, hasPickedBackground: Bool) -> Bool {
        stored ?? !hasPickedBackground
    }
}
