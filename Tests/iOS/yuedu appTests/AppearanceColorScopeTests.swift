import Testing
import SwiftUI
import UIKit
@testable import yuedu_app

/// What each setting on 外觀主題 › 顏色與字體 reaches, redesigned after Apple's HIG
/// (2026-09-29): 強調色 what can be tapped or is selected, 背景 the page as set, the
/// text levels iOS's own three.
@Suite("Appearance colour scope", .serialized)
@MainActor
struct AppearanceColorScopeTests {
    /// The symbol leading a settings row wears 強調色 in every theme, 默認 included —
    /// read from the tint when it draws, not from the app-theme global, which left rows
    /// SwiftUI did not rebuild black beside red ones.
    @Test("a settings row's symbol wears the tint, with no app theme recorded")
    func rowSymbolWearsTheTint() throws {
        let saved = AppearanceThemePreset.activeAppThemes
        defer { AppearanceThemePreset.activeAppThemes = saved }
        AppearanceThemePreset.activeAppThemes = ActiveAppThemes()

        let row = Label("Row", systemImage: "square.fill")
            .labelStyle(IconConsistentLabelStyle())
            .foregroundStyle(Color.black)
            .tint(Color(red: 1, green: 0, blue: 0))
        let symbol = try #require(Self.pixel(at: CGPoint(x: 14, y: 14), of: row))
        #expect(symbol.red > 0.9 && symbol.green < 0.1 && symbol.blue < 0.1, "symbol drew \(symbol)")
    }

    /// An action or destructive row colours its title; its symbol matches the title.
    @Test("an action row's symbol keeps its title's colour")
    func actionRowSymbolMatchesTitle() throws {
        let row = Label("Row", systemImage: "square.fill")
            .labelStyle(IconConsistentLabelStyle(themesIcon: false))
            .foregroundStyle(Color(red: 0, green: 0, blue: 1))
            .tint(Color(red: 1, green: 0, blue: 0))
        let symbol = try #require(Self.pixel(at: CGPoint(x: 14, y: 14), of: row))
        #expect(symbol.blue > 0.9 && symbol.red < 0.1, "symbol drew \(symbol)")
    }

    /// 背景 is the page, exactly: the accent no longer tints it.
    @Test("the page is the theme's background, whatever the accent")
    func pageIsTheBackground() {
        for preset in [AppearanceThemePreset.classic] + AppearanceThemePreset.freeSolidPresets {
            #expect(preset.appPageBackground.rgbHex == preset.background.rgbHex, "\(preset.id)")
            let dark = preset.palette(for: .dark)
            #expect(dark.appPageBackground.rgbHex == dark.background.rgbHex, "\(preset.id) dark")
        }
    }

    /// 默認 keeps the system's grouped backgrounds, and the separators on them, until 背景
    /// itself is changed. An edit to 強調色 alone used to swap them for surfaces worked out
    /// from 默認's near-white 背景, and every page turned white (reported 2026-09-29; the
    /// user's call: only a change to 背景 changes the page).
    @Test("默認 with only its accent changed keeps the system backgrounds")
    func defaultKeepsSystemBackgroundsUnderAnAccentEdit() {
        var colors = AppearanceThemePreset.classic.customCopy(name: "默認")
        colors.accentHex = 0xB11405
        let edited = AppearanceThemePreset.classic.withEditedColors(colors)
        #expect(!edited.isClassic)
        #expect(edited.accent.rgbHex == 0xB11405)
        let themes = ActiveAppThemes(light: edited, dark: edited.palette(for: .dark))
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (name, drawn, system) in Self.surfaces(under: themes, style: style) {
                #expect(drawn.description == system.description, "\(name), \(style == .dark ? "dark" : "light")")
            }
        }
    }

    /// Once 背景 is changed the page wears it — light and dark apart, the dark one following
    /// the light while 自動深色配色 derives it.
    @Test("默認 wears its 背景 once it is changed, light and dark apart")
    func defaultWearsAChangedBackground() {
        var light = AppearanceThemePreset.classic.customCopy(name: "默認")
        light.backgroundHex = 0xE4E0D8
        light.hasEditedBackground = true
        let lightEdited = AppearanceThemePreset.classic.withEditedColors(light)
        #expect(!lightEdited.keepsSystemBackgrounds)
        #expect(!lightEdited.palette(for: .dark).keepsSystemBackgrounds, "自動深色配色 derives dark from it")
        #expect(Self.drawn(DSColor.groupedBackground, under: lightEdited, style: .light).rgbHex == 0xE4E0D8)

        var dark = AppearanceThemePreset.classic.customCopy(name: "默認")
        dark.dark = AppearanceCustomThemeDarkColors(
            backgroundHex: 0x202225, textHex: 0xEBEBF0, barHex: 0x2C2C2E, accentHex: 0x0A84FF, dialogueHex: 0x2A3A4A
        )
        dark.hasEditedDarkBackground = true
        let darkEdited = AppearanceThemePreset.classic.withEditedColors(dark)
        #expect(darkEdited.keepsSystemBackgrounds)
        #expect(!darkEdited.palette(for: .dark).keepsSystemBackgrounds)
        #expect(Self.drawn(DSColor.groupedBackground, under: darkEdited, style: .dark).rgbHex == 0x202225)

        // 自動深色配色 turned off seeds a dark palette; untouched, it changes nothing.
        var seeded = dark
        seeded.hasEditedDarkBackground = nil
        #expect(AppearanceThemePreset.classic.withEditedColors(seeded).palette(for: .dark).keepsSystemBackgrounds)
    }

    /// Only 默認 has the system's backgrounds to keep: every other built-in theme is its
    /// palette from the start, edited or not.
    @Test("an edited built-in theme other than 默認 keeps its own palette")
    func otherBuiltInThemesKeepTheirPalette() {
        let ocean = AppearanceThemePreset.freeSolidPresets[0]
        var colors = ocean.customCopy(name: ocean.localizedName)
        colors.accentHex = 0xB11405
        let edited = ocean.withEditedColors(colors)
        #expect(!edited.keepsSystemBackgrounds)
        #expect(!edited.palette(for: .dark).keepsSystemBackgrounds)
        #expect(Self.drawn(DSColor.groupedBackground, under: edited, style: .light).rgbHex == ocean.background.rgbHex)
    }

    /// A record written before the mark existed — the one on the test simulator, an accent
    /// edit only — decodes with it unset, and 默認 keeps the system's backgrounds.
    @Test("a record from before the mark reads as 背景 unchanged")
    func recordFromBeforeTheMarkKeepsSystemBackgrounds() throws {
        let json = #"{"id":"2CA1B03F-357F-47A8-AF33-97F9067C8809","name":"Default","backgroundHex":16053751,"textHex":3355443,"barHex":16777215,"accentHex":8071424,"dialogueHex":14215675}"#
        let record = try JSONDecoder().decode(AppearanceCustomTheme.self, from: Data(json.utf8))
        #expect(record.hasEditedBackground == nil)
        #expect(AppearanceThemePreset.classic.withEditedColors(record).keepsSystemBackgrounds)
    }

    /// Cards lift toward white off every built-in page, and step down off a white one,
    /// which has nowhere lighter to go.
    @Test("cards stay distinct from the page, a white one included")
    func cardsStayDistinctFromThePage() {
        for preset in [AppearanceThemePreset.classic] + AppearanceThemePreset.freeSolidPresets {
            #expect(Self.brightness(preset.appCardBackground) > Self.brightness(preset.appPageBackground), "\(preset.id)")
        }
        var white = AppearanceThemePreset.classic.customCopy(name: "White")
        white.backgroundHex = 0xFFFFFF
        let preset = AppearanceThemePreset.preset(from: white)
        #expect(preset.appPageBackground.rgbHex == 0xFFFFFF)
        #expect(Self.brightness(preset.appCardBackground) < Self.brightness(preset.appPageBackground))
        #expect(preset.appCardBackground.rgbHex != preset.appSecondaryBackground.rgbHex)
    }

    /// Disabled text is 弱文字 — and, with no theme, exactly the system's tertiary label.
    @Test("disabled text is the tertiary text level")
    func disabledTextIsTertiary() {
        var themed = AppearanceThemePreset.freeSolidPresets[0]
        themed.authoredTextColors = AppearanceThemeTextColors(primary: .red, secondary: .green, tertiary: .blue)
        let themes = ActiveAppThemes(light: themed, dark: nil)
        #expect(Self.resolved(DSColor.textDisabled, under: themes, style: .light).rgbHex == UIColor.blue.rgbHex)

        for style in [UIUserInterfaceStyle.light, .dark] {
            let drawn = Self.components(Self.resolved(DSColor.textDisabled, under: ActiveAppThemes(), style: style))
            let system = Self.components(UIColor.tertiaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
            #expect(abs(drawn.alpha - system.alpha) < 0.01 && abs(drawn.red - system.red) < 0.01, "\(style.rawValue)")
        }
    }

    // MARK: - Helpers

    struct RGBA: CustomStringConvertible {
        var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        var description: String {
            String(format: "(%.2f, %.2f, %.2f, %.2f)", red, green, blue, alpha)
        }
    }

    /// One pixel of `view` drawn at scale 1 on a clear background, un-premultiplied.
    static func pixel<Content: View>(at point: CGPoint, of view: Content) -> RGBA? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              Int(point.x) < image.width, Int(point.y) < image.height else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: -point.x, y: point.y - CGFloat(image.height) + 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let alpha = CGFloat(bytes[3]) / 255
        guard alpha > 0 else { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        return RGBA(
            red: CGFloat(bytes[0]) / 255 / alpha,
            green: CGFloat(bytes[1]) / 255 / alpha,
            blue: CGFloat(bytes[2]) / 255 / alpha,
            alpha: alpha
        )
    }

    /// Every themed surface token as drawn under `themes`, beside the system colour it
    /// falls back to with no theme.
    static func surfaces(
        under themes: ActiveAppThemes,
        style: UIUserInterfaceStyle
    ) -> [(name: String, drawn: RGBA, system: RGBA)] {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits[AppThemesTrait.self] = themes
        }
        let tokens: [(String, Color, UIColor)] = [
            ("groupedBackground", DSColor.groupedBackground, .systemGroupedBackground),
            ("background", DSColor.background, .systemBackground),
            ("surface", DSColor.surface, .secondarySystemGroupedBackground),
            ("surfaceTertiary", DSColor.surfaceTertiary, .tertiarySystemBackground),
            ("separator", DSColor.separator, .separator),
            ("border", DSColor.border, .systemGray4),
        ]
        return tokens.map { name, token, system in
            (name, components(resolved(token, under: themes, style: style)), components(system.resolvedColor(with: traits)))
        }
    }

    /// `token` as drawn in `style`, with `preset` on screen in both appearances.
    static func drawn(_ token: Color, under preset: AppearanceThemePreset, style: UIUserInterfaceStyle) -> UIColor {
        resolved(token, under: ActiveAppThemes(light: preset, dark: preset.palette(for: .dark)), style: style)
    }

    /// `token` as SwiftUI resolves it where it draws: in `style`, with `themes` on screen.
    /// Never `UIColor(token).resolvedColor(with:)`, which on iOS 17 resolves in light whatever
    /// it is asked (`DSUIColor`) and failed every dark check here while views drew right.
    static func resolved(_ token: Color, under themes: ActiveAppThemes, style: UIUserInterfaceStyle) -> UIColor {
        var environment = EnvironmentValues()
        environment.colorScheme = style == .dark ? .dark : .light
        environment.appThemes = themes
        return UIColor(cgColor: token.resolve(in: environment).cgColor)
    }

    static func components(_ color: UIColor) -> RGBA {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    static func brightness(_ color: UIColor) -> CGFloat {
        let rgba = components(color)
        return (rgba.red + rgba.green + rgba.blue) / 3
    }
}
