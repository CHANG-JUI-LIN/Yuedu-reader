import Foundation
import SwiftUI
import UIKit

enum AppearanceReaderInterface: String, CaseIterable, Identifiable, Codable {
    case classic
    case compact
    case immersive

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .classic: return "經典"
        case .compact: return "簡潔"
        case .immersive: return "沉浸"
        }
    }

    var localizedTitle: String { localized(titleKey) }
}

struct AppearanceCustomTheme: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var backgroundHex: UInt32
    var textHex: UInt32
    var barHex: UInt32
    var accentHex: UInt32
    var dialogueHex: UInt32

    init(
        id: String = UUID().uuidString,
        name: String,
        backgroundHex: UInt32,
        textHex: UInt32,
        barHex: UInt32,
        accentHex: UInt32,
        dialogueHex: UInt32
    ) {
        self.id = id
        self.name = name
        self.backgroundHex = backgroundHex
        self.textHex = textHex
        self.barHex = barHex
        self.accentHex = accentHex
        self.dialogueHex = dialogueHex
    }
}

/// App-level appearance theme. Free themes are solid color palettes; Pro theme
/// packs are loaded from bundled resource folders under `Assets/ReaderThemes`.
struct AppearanceThemePreset: Identifiable, Hashable {
    let id: String
    let nameKey: String
    let displayName: String?
    let background: UIColor
    let text: UIColor
    let bar: UIColor
    let accent: UIColor
    let dialogue: UIColor
    let previewBackground: UIColor
    let relativePreviewImagePath: String?
    let imagePaths: [String]
    let requiresPro: Bool
    let isImagePreset: Bool
    let isCustom: Bool

    var localizedName: String { displayName ?? localized(nameKey) }
    var backgroundColor: Color { Color(uiColor: background) }
    var textColor: Color { Color(uiColor: text) }
    var barColor: Color { Color(uiColor: bar) }
    var accentColor: Color { Color(uiColor: accent) }
    var dialogueColor: Color { Color(uiColor: dialogue) }
    var previewBackgroundColor: Color { Color(uiColor: previewBackground) }

    /// The app's original look: no tint override, system default accent.
    var isClassic: Bool { id == Self.classicID }

    // MARK: - App-wide surface colors (drive DSColor when a theme is active)

    /// Page / grouped-list background — the tinted "paper". Nudged toward the
    /// accent so the tint is actually visible against the near-white cards
    /// (the raw preset background alone reads as plain white).
    var appPageBackground: UIColor { Self.mix(background, accent, 0.12) }
    /// Cards, rows, sheets — near-white so they lift off the tinted page.
    var appCardBackground: UIColor { Self.mix(background, .white, 0.72) }
    /// Nested / secondary surfaces (slightly more tint than cards).
    var appSecondaryBackground: UIColor { Self.mix(background, .white, 0.45) }
    var appSeparator: UIColor { text.withAlphaComponent(0.12) }
    var appBorder: UIColor { text.withAlphaComponent(0.18) }

    /// Linear interpolation between two colors in sRGB.
    static func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(
            red: ar + (br - ar) * t,
            green: ag + (bg - ag) * t,
            blue: ab + (bb - ab) * t,
            alpha: aa + (ba - aa) * t
        )
    }

    static let classicID = "classic"

    /// "默認" — what the app looked like before appearance themes existed.
    /// Selecting it applies no tint override (see `ContentView`); the colors
    /// here only drive the preview tile and serve as a base for custom copies.
    static let classic = AppearanceThemePreset(
        id: classicID, nameKey: "默認",
        displayName: nil,
        background: hex(0xF4F5F7), text: hex(0x333333),
        bar: .white, accent: hex(0x007AFF), dialogue: hex(0xD8E9FB),
        previewBackground: .white,
        relativePreviewImagePath: nil, imagePaths: [],
        requiresPro: false, isImagePreset: false, isCustom: false
    )

    static var allDefaultPresets: [AppearanceThemePreset] {
        [classic] + freeSolidPresets + bundledThemePacks
    }

    /// Low-saturation six-hue palette (blue/orange/green/purple/pink/gold).
    /// IDs are stable storage keys — do not rename when display names change.
    static let freeSolidPresets: [AppearanceThemePreset] = [
        AppearanceThemePreset(
            id: "ocean_blue", nameKey: "海霧藍",
            displayName: nil,
            background: hex(0xEAF2FC), text: hex(0x263443),
            bar: hex(0xDCE9F8), accent: hex(0x3478F6), dialogue: hex(0xD4E4F7),
            previewBackground: hex(0xDCE9F8),
            relativePreviewImagePath: nil, imagePaths: [],
            requiresPro: false, isImagePreset: false, isCustom: false
        ),
        AppearanceThemePreset(
            id: "sunset_orange", nameKey: "暮色橙",
            displayName: nil,
            background: hex(0xFBF0E8), text: hex(0x40312A),
            bar: hex(0xF5E2D4), accent: hex(0xE8703A), dialogue: hex(0xF4DCCB),
            previewBackground: hex(0xF5E2D4),
            relativePreviewImagePath: nil, imagePaths: [],
            requiresPro: false, isImagePreset: false, isCustom: false
        ),
        AppearanceThemePreset(
            id: "forest_green", nameKey: "苔原綠",
            displayName: nil,
            background: hex(0xEBF4EC), text: hex(0x28382C),
            bar: hex(0xDCEBDE), accent: hex(0x3E9D63), dialogue: hex(0xD5E8D8),
            previewBackground: hex(0xDCEBDE),
            relativePreviewImagePath: nil, imagePaths: [],
            requiresPro: false, isImagePreset: false, isCustom: false
        ),
        AppearanceThemePreset(
            id: "lavender", nameKey: "薰衣紫",
            displayName: nil,
            background: hex(0xF3EEFB), text: hex(0x352C43),
            bar: hex(0xE7DDF6), accent: hex(0x8B5CD6), dialogue: hex(0xE3D8F4),
            previewBackground: hex(0xE7DDF6),
            relativePreviewImagePath: nil, imagePaths: [],
            requiresPro: false, isImagePreset: false, isCustom: false
        ),
        AppearanceThemePreset(
            id: "rose_pink", nameKey: "櫻語粉",
            displayName: nil,
            background: hex(0xFCEFF4), text: hex(0x422D36),
            bar: hex(0xF6DCE7), accent: hex(0xE05C8A), dialogue: hex(0xF5D5E2),
            previewBackground: hex(0xF6DCE7),
            relativePreviewImagePath: nil, imagePaths: [],
            requiresPro: false, isImagePreset: false, isCustom: false
        ),
        AppearanceThemePreset(
            id: "amber_gold", nameKey: "琥珀金",
            displayName: nil,
            background: hex(0xFAF3E3), text: hex(0x413723),
            bar: hex(0xF2E6C9), accent: hex(0xD69A2D), dialogue: hex(0xF0E1BD),
            previewBackground: hex(0xF2E6C9),
            relativePreviewImagePath: nil, imagePaths: [],
            requiresPro: false, isImagePreset: false, isCustom: false
        ),
    ]

    // Theme PACKS (imported image sets) are intentionally NOT built yet — the
    // app ships only classic + the free solid palettes. Kept empty rather than
    // scanning the bundle so nothing surfaces a half-built "pack" concept.
    static let bundledThemePacks: [AppearanceThemePreset] = []
    static let supportedThemeImageExtensions: Set<String> = ["jpg", "jpeg", "webp", "png"]

    /// Active reader-surface color override (nil = built-in reader theme).
    nonisolated(unsafe) static var activeReaderTheme: AppearanceThemePreset?

    /// Active app-wide appearance theme (nil = classic/system colors). Set by
    /// `ContentView`; consulted by `DSColor` so themed surfaces retint the whole
    /// app. Only ever mutated on the main thread.
    nonisolated(unsafe) static var activeAppTheme: AppearanceThemePreset?

    static func preset(
        id: String?,
        customThemes: [AppearanceCustomTheme] = []
    ) -> AppearanceThemePreset? {
        guard let id, !id.isEmpty else { return nil }
        if let custom = customThemes.first(where: { $0.id == id }) {
            return preset(from: custom)
        }
        return allDefaultPresets.first { $0.id == id }
    }

    static func preset(from custom: AppearanceCustomTheme) -> AppearanceThemePreset {
        AppearanceThemePreset(
            id: custom.id,
            nameKey: "",
            displayName: custom.name,
            background: hex(custom.backgroundHex),
            text: hex(custom.textHex),
            bar: hex(custom.barHex),
            accent: hex(custom.accentHex),
            dialogue: hex(custom.dialogueHex),
            previewBackground: hex(custom.backgroundHex),
            relativePreviewImagePath: nil,
            imagePaths: [],
            requiresPro: true,
            isImagePreset: false,
            isCustom: true
        )
    }

    func customCopy(name: String) -> AppearanceCustomTheme {
        AppearanceCustomTheme(
            name: name,
            backgroundHex: background.rgbHex ?? 0xFFF0EB,
            textHex: text.rgbHex ?? 0x3E2E28,
            barHex: bar.rgbHex ?? 0xFBE1D9,
            accentHex: accent.rgbHex ?? 0xFF6B3A,
            dialogueHex: dialogue.rgbHex ?? 0xF9D5C9
        )
    }

    /// Bundle root holding the theme pack folders. The `Assets` folder is a
    /// folder reference (pbxproj `explicitFolders`), so the hierarchy survives
    /// into the bundle; the bare `ReaderThemes` fallback covers a future move.
    static var themePacksRootURL: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL
                .appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent("ReaderThemes", isDirectory: true),
            resourceURL.appendingPathComponent("ReaderThemes", isDirectory: true),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func backgroundImageURL(colorScheme: ColorScheme) -> URL? {
        guard !imagePaths.isEmpty, let root = Self.themePacksRootURL else { return nil }

        let preferred = preferredImagePath(colorScheme: colorScheme) ?? relativePreviewImagePath ?? imagePaths.first
        guard let preferred else { return nil }
        return root.appendingPathComponent(preferred)
    }

    static func shouldIncludeBundledThemeImage(relativePath: String) -> Bool {
        guard supportedThemeImageExtensions.contains((relativePath as NSString).pathExtension.lowercased()) else {
            return false
        }
        return !hasSkippedPathComponent(relativePath)
    }

    private func preferredImagePath(colorScheme: ColorScheme) -> String? {
        if colorScheme == .dark {
            return imagePaths.first { Self.isDarkImageTheme(relativePath: $0) }
        }
        return imagePaths.first { path in
            let lower = path.lowercased()
            return lower.contains("日") || lower.contains("day") || lower.contains("light")
        }
    }

    private static func loadBundledThemePacks() -> [AppearanceThemePreset] {
        guard let root = themePacksRootURL else { return [] }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let imageURLs = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let relative = relativePath(for: url, root: root)
            guard shouldIncludeBundledThemeImage(relativePath: relative) else { return nil }
            return url
        }

        let grouped = Dictionary(grouping: imageURLs) { url in
            relativePath(for: url, root: root)
                .split(separator: "/")
                .map(String.init)
                .first ?? url.deletingLastPathComponent().lastPathComponent
        }

        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { folder in
                guard let urls = grouped[folder], !urls.isEmpty else { return nil }
                let paths = urls
                    .map { relativePath(for: $0, root: root) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let preview = paths.first { path in
                    let lower = path.lowercased()
                    return lower.contains("日") || lower.contains("day") || lower.contains("封面") || lower.contains("cover")
                } ?? paths.first
                let isDark = preview.map(isDarkImageTheme(relativePath:)) ?? false
                return imagePackPreset(
                    folderName: folder,
                    imagePaths: paths,
                    previewPath: preview,
                    isDark: isDark
                )
            }
    }

    private static func imagePackPreset(
        folderName: String,
        imagePaths: [String],
        previewPath: String?,
        isDark: Bool
    ) -> AppearanceThemePreset {
        AppearanceThemePreset(
            id: "pack_" + sanitizedID(folderName),
            nameKey: "",
            displayName: folderName,
            background: isDark ? UIColor(white: 0.02, alpha: 0.62) : UIColor(white: 1.0, alpha: 0.84),
            text: isDark ? hex(0xECE8DF) : hex(0x2E322F),
            bar: isDark ? UIColor(white: 0.03, alpha: 0.82) : UIColor(white: 0.98, alpha: 0.88),
            accent: isDark ? hex(0xE0B25E) : hex(0x5A8E78),
            dialogue: isDark ? UIColor(red: 1.0, green: 0.82, blue: 0.46, alpha: 0.18) : UIColor(red: 0.34, green: 0.56, blue: 0.47, alpha: 0.16),
            previewBackground: isDark ? hex(0x312B27) : hex(0xF2EDE4),
            relativePreviewImagePath: previewPath,
            imagePaths: imagePaths,
            requiresPro: true,
            isImagePreset: true,
            isCustom: false
        )
    }

    private static func hasSkippedPathComponent(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { component in
            let value = String(component)
            let lower = value.lowercased()
            // 图标/icons: tab-bar icon assets, not backgrounds.
            // 界面背景: loose background library reserved for the upcoming
            // background-import feature — not a coherent theme pack.
            return value == "图标" || value == "圖標" || lower == "icon" || lower == "icons"
                || value == "界面背景"
        }
    }

    private static func isDarkImageTheme(relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        return lower.contains("夜")
            || lower.contains("诡")
            || lower.contains("微恐")
            || lower.contains("dark")
            || lower.contains("night")
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        let start = urlPath.index(urlPath.startIndex, offsetBy: rootPath.count)
        return urlPath[start...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func sanitizedID(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar).lowercased()) : "_"
        }
        let collapsed = String(scalars).replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

extension UIColor {
    var rgbHex: UInt32? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (UInt32(red * 255) << 16) | (UInt32(green * 255) << 8) | UInt32(blue * 255)
    }
}

struct AppearanceThemeBackgroundView: View {
    let preset: AppearanceThemePreset?
    let colorScheme: ColorScheme

    var body: some View {
        if let url = preset?.backgroundImageURL(colorScheme: colorScheme),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }
}
