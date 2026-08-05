import Foundation

/// Everything the user has customised about the app's look, in one `.json`:
/// custom themes, the live page backgrounds, the bottom-tab icons, the launch
/// images, and the reader's own background — with every image embedded as
/// base64 so the file survives AirDrop to another device.
///
/// A theme file only ever carried colors plus page backgrounds. That leaves the
/// rest of a user's look — the tab icons they drew, their launch splash, their
/// reading background — stranded on one device, which is the gap this closes.
/// Lives in the app target rather than ReaderCore because it composes app-level
/// stores (tab icons, launch images) that ReaderCore has no business knowing.
struct AppearanceCustomizationBundle: Codable {
    typealias ImagePayload = AppearanceThemeExportFile.ImagePayload
    typealias PageBackgroundPayload = AppearanceThemeExportFile.PageBackgroundPayload

    struct TabIcon: Codable {
        var tabID: String
        var slot: String
        var originalFileName: String
        var image: ImagePayload
    }

    struct ReaderBackground: Codable {
        /// `ReaderCustomBackgroundMode` raw value.
        var mode: String
        var colorHex: UInt32?
        var image: ImagePayload?
    }

    static let formatIdentifier = "yuedu-appearance-bundle"

    var format: String
    var version: Int
    var themes: [AppearanceThemeExportFile]
    /// The page backgrounds in effect, independent of any saved theme — without
    /// these a bundle would restore nothing for a user who never pressed 保存為新主題.
    var pageBackgrounds: [String: PageBackgroundPayload]?
    var tabIcons: [TabIcon]?
    var launchImageLight: ImagePayload?
    var launchImageDark: ImagePayload?
    var readerBackground: ReaderBackground?

    init(snapshot: AppearanceCustomizationSnapshot) {
        format = Self.formatIdentifier
        version = 1
        themes = snapshot.themes.map(AppearanceThemeExportFile.init(customTheme:))

        var backgrounds: [String: PageBackgroundPayload] = [:]
        for (key, config) in snapshot.pageBackgrounds {
            backgrounds[key] = PageBackgroundPayload(
                lightPrimaryHex: config.lightPrimaryHex,
                lightSecondaryHex: config.lightSecondaryHex,
                darkPrimaryHex: config.darkPrimaryHex,
                darkSecondaryHex: config.darkSecondaryHex,
                lightImage: Self.pageBackgroundImage(config.lightImageFileName),
                darkImage: Self.pageBackgroundImage(config.darkImageFileName),
                lightImageOpacity: config.lightImageOpacity,
                darkImageOpacity: config.darkImageOpacity
            )
        }
        pageBackgrounds = backgrounds.isEmpty ? nil : backgrounds

        let icons = snapshot.tabIcons.compactMap { asset -> TabIcon? in
            guard let data = RootTabIconStorageManager.shared.fileData(for: asset) else { return nil }
            return TabIcon(
                tabID: asset.tabID,
                slot: asset.slotRawValue,
                originalFileName: asset.originalFileName,
                image: ImagePayload(
                    fileExtension: (asset.fileName as NSString).pathExtension,
                    base64: data.base64EncodedString()
                )
            )
        }
        tabIcons = icons.isEmpty ? nil : icons

        launchImageLight = Self.launchImage(snapshot.launchImageLightFileName)
        launchImageDark = Self.launchImage(snapshot.launchImageDarkFileName)

        // `.none` carries nothing worth restoring, and writing it would let a
        // bundle silently switch off the receiving device's reading background.
        if snapshot.readerBackgroundMode != ReaderCustomBackgroundMode.none.rawValue {
            readerBackground = ReaderBackground(
                mode: snapshot.readerBackgroundMode,
                colorHex: snapshot.readerBackgroundColorHex,
                image: Self.readerBackgroundImage(snapshot.readerBackgroundImageFileName)
            )
        }
    }

    // MARK: - Reading the stored bytes

    private static func payload(at url: URL?, fileName: String?) -> ImagePayload? {
        guard let url, let fileName, let data = try? Data(contentsOf: url) else { return nil }
        return ImagePayload(
            fileExtension: (fileName as NSString).pathExtension,
            base64: data.base64EncodedString()
        )
    }

    private static func pageBackgroundImage(_ fileName: String?) -> ImagePayload? {
        guard let fileName, !fileName.isEmpty,
              let data = AppearancePageBackgroundImageStore.shared.fileData(fileName: fileName) else {
            return nil
        }
        return ImagePayload(
            fileExtension: (fileName as NSString).pathExtension,
            base64: data.base64EncodedString()
        )
    }

    private static func launchImage(_ fileName: String?) -> ImagePayload? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return payload(
            at: try? LaunchImageStorageManager.shared.fileURL(fileName: fileName),
            fileName: fileName
        )
    }

    private static func readerBackgroundImage(_ fileName: String?) -> ImagePayload? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return payload(
            at: try? ReaderCustomBackgroundStorageManager.shared.fileURL(fileName: fileName),
            fileName: fileName
        )
    }
}

/// The cheap main-actor read of everything a bundle needs: values and *file
/// names*, no image bytes. Taken on the main actor, then handed to
/// `AppearanceCustomizationBundle` (which does the disk reads and base64) from
/// wherever the export actually runs — a `ShareLink` transfer closure, not a
/// layout pass.
struct AppearanceCustomizationSnapshot {
    var themes: [AppearanceCustomTheme] = []
    var pageBackgrounds: [String: AppearancePageBackgroundConfig] = [:]
    var tabIcons: [RootTabIconAsset] = []
    var launchImageLightFileName: String?
    var launchImageDarkFileName: String?
    var readerBackgroundMode: String = ReaderCustomBackgroundMode.none.rawValue
    var readerBackgroundColorHex: UInt32?
    var readerBackgroundImageFileName: String?

    var isEmpty: Bool {
        themes.isEmpty
            && pageBackgrounds.isEmpty
            && tabIcons.isEmpty
            && launchImageLightFileName == nil
            && launchImageDarkFileName == nil
            && readerBackgroundMode == ReaderCustomBackgroundMode.none.rawValue
    }
}

/// What an import actually restored, so the confirmation can say so instead of
/// claiming a flat "done".
struct AppearanceImportSummary {
    var themes = 0
    var tabIcons = 0
    var launchImages = 0
    var restoredPageBackgrounds = false
    var restoredReaderBackground = false

    var isEmpty: Bool {
        themes == 0
            && tabIcons == 0
            && launchImages == 0
            && !restoredPageBackgrounds
            && !restoredReaderBackground
    }

    /// One line per kind of thing restored, joined — "已匯入 2 個主題、5 個 Tab 圖示".
    var localizedDescription: String {
        var parts: [String] = []
        if themes > 0 {
            parts.append(String(format: localized("%d 個主題"), themes))
        }
        if restoredPageBackgrounds {
            parts.append(localized("頁面背景"))
        }
        if tabIcons > 0 {
            parts.append(String(format: localized("%d 個 Tab 圖示"), tabIcons))
        }
        if launchImages > 0 {
            parts.append(String(format: localized("%d 張啟動圖"), launchImages))
        }
        if restoredReaderBackground {
            parts.append(localized("閱讀背景"))
        }
        guard !parts.isEmpty else { return localized("這個檔案沒有可匯入的內容。") }
        return String(
            format: localized("已匯入 %@。"),
            parts.joined(separator: localized("、"))
        )
    }
}
