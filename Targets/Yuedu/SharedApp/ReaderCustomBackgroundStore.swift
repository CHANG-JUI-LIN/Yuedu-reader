import SwiftUI
import UIKit

/// A picture imported for a saved reading background, with what the background needs to
/// know about it: where it is and how dark it reads.
struct ReaderBackgroundPicture: Equatable {
    var fileName: String
    /// The picture's average colour — the page colour under it, and the chrome's.
    var averageColorHex: UInt32
    var isDark: Bool
}

/// The saved reading backgrounds (`ReaderCustomBackground`): the list, the one worn, and
/// every write to them. The list replaced a single custom slot that each new background
/// overwrote (2026-09-29).
extension GlobalSettings {
    // MARK: - Storage

    static func loadReaderCustomBackgrounds(defaults: UserDefaults = .standard) -> [ReaderCustomBackground] {
        guard let data = defaults.data(forKey: readerCustomBackgroundsKey) else { return [] }
        do {
            return ReaderCustomBackgroundLibrary.uniqued(
                try JSONDecoder().decode([ReaderCustomBackground].self, from: data)
            )
        } catch {
            AppLogger.error("⟐ saved reading backgrounds unreadable", error: error)
            return []
        }
    }

    static func saveReaderCustomBackgrounds(
        _ backgrounds: [ReaderCustomBackground],
        defaults: UserDefaults = .standard
    ) {
        guard !backgrounds.isEmpty else {
            defaults.removeObject(forKey: readerCustomBackgroundsKey)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(backgrounds), forKey: readerCustomBackgroundsKey)
        } catch {
            AppLogger.error("⟐ saved reading backgrounds not stored", error: error)
        }
    }

    // MARK: - Reading

    func readerCustomBackground(id: UUID) -> ReaderCustomBackground? {
        readerCustomBackgrounds.first { $0.id == id }
    }

    /// The saved background picked in the reader, if it still exists.
    var wornReaderCustomBackground: ReaderCustomBackground? {
        readerCustomBackgroundID.flatMap(readerCustomBackground(id:))
    }

    func readerBackgroundImageURL(for background: ReaderCustomBackground) -> URL? {
        // Read so a view drawing the picture redraws when iCloud brings it later.
        _ = readerBackgroundPicturesRevision
        guard let fileName = background.imageFileName, !fileName.isEmpty else { return nil }
        do {
            return try ReaderCustomBackgroundStorageManager.shared.fileURL(fileName: fileName)
        } catch {
            AppLogger.error("⟐ reading background folder unavailable", error: error)
            return nil
        }
    }

    /// The palette a saved background paints the reader with. A dark one is marked as a
    /// dark palette, which is what lets it paint 黑色 and nothing else.
    func readerBackgroundPreset(for background: ReaderCustomBackground) -> AppearanceThemePreset {
        // The page takes the picture's average colour, which shows only while the picture
        // is not there — before iCloud has brought it to this device, say.
        let page = AppearanceThemePreset.hex(background.colorHex)
        // A picture keeps the chrome plain, as the one custom picture always did: white
        // over a light picture, the night bar over a dark one.
        let bar: UIColor = background.isImage
            ? (background.isDark ? AppearanceThemePreset.hex(0x1A1A1A) : .white)
            : page
        let accent = AppearanceThemePreset.hex(background.isDark ? 0x0A84FF : 0x007AFF)
        var preset = AppearanceThemePreset(
            id: "reader_background_\(background.id.uuidString)",
            nameKey: "自定義",
            displayName: background.name,
            background: page,
            text: AppearanceThemePreset.hex(background.resolvedTextColorHex),
            bar: bar,
            accent: accent,
            dialogue: accent.withAlphaComponent(0.16),
            previewBackground: page,
            relativePreviewImagePath: nil,
            imagePaths: [],
            requiresPro: false,
            isImagePreset: background.isImage,
            isCustom: true
        )
        preset.isDarkAppearancePalette = background.isDark
        preset.readerBackgroundID = background.id
        return preset
    }

    /// What 淺色閱讀主題 / 深色閱讀主題 offer: the built-in choices, then every saved one.
    var boundReaderThemeOptions: [ReaderBoundTheme] {
        ReaderBoundTheme.builtInMenuOptions + readerCustomBackgrounds.map { .custom($0.id) }
    }

    func title(for choice: ReaderBoundTheme) -> String {
        switch choice {
        case .followAppearanceTheme:
            return localized("跟隨外觀主題")
        case .reading(let theme):
            return theme.localizedTitle
        case .custom(let id):
            // Only while a sync or a delete is still dropping the reference.
            return readerCustomBackground(id: id)?.name ?? localized("自定義")
        }
    }

    // MARK: - Editing

    /// Adds `background` to the list or replaces the saved one with its id, stamping the
    /// iCloud merge clock. Returns it as stored.
    @discardableResult
    func saveReaderCustomBackground(_ background: ReaderCustomBackground) -> ReaderCustomBackground {
        let updated = ReaderCustomBackgroundLibrary.upserting(background, into: readerCustomBackgrounds)
        let old = readerCustomBackgrounds
        readerCustomBackgrounds = updated
        reclaimReaderBackgroundPictures(droppedFrom: old)
        return updated.first { $0.id == background.id } ?? background
    }

    /// The reader's own pick, as tapping one of the reader's backgrounds has always been:
    /// it takes over from 綁定閱讀主題 and becomes the light mode's background, whatever
    /// its tone, with the reader put in light mode to show it. Returns the built-in
    /// background to sit on — 黑色 under a dark one, the light one in use under a light one.
    ///
    /// A dark one used to put the reader in dark mode and stay out of light mode
    /// (reported 2026-09-30): a background made in the reader is the light mode's, and
    /// dark mode gets one of its own only through 深色閱讀主題.
    func wearReaderCustomBackground(
        _ background: ReaderCustomBackground,
        over current: ReaderTheme,
        deviceIsDark: Bool
    ) -> ReaderTheme {
        appearanceBindReaderTheme = false
        // The mode first: wearing the background is noted for the other devices with
        // what the reader then follows.
        setReaderDarkMode(false, deviceIsDark: deviceIsDark)
        readerCustomBackgroundID = background.id
        return readerBackgroundResolution(mode: .light, wornTheme: current).theme
    }

    /// Removes it from the list, from the reader and from both bound picks, and deletes
    /// its picture once no other saved background shows it.
    func deleteReaderCustomBackground(id: UUID) {
        let old = readerCustomBackgrounds
        readerCustomBackgrounds = ReaderCustomBackgroundLibrary.deleting(id: id, from: old)
        dropReferences(toDeleted: [id])
        reclaimReaderBackgroundPictures(droppedFrom: old)
    }

    /// Nil goes back to the text colour picked for the background automatically.
    func setReaderCustomBackgroundTextColor(_ rgbHex: UInt32?, id: UUID) {
        guard var background = readerCustomBackground(id: id), background.textColorHex != rgbHex else { return }
        background.textColorHex = rgbHex
        saveReaderCustomBackground(background)
    }

    // MARK: - Pictures

    func importReaderBackgroundPicture(data: Data) throws -> ReaderBackgroundPicture {
        try describeReaderBackgroundPicture(
            fileName: ReaderCustomBackgroundStorageManager.shared.importBackground(data: data)
        )
    }

    func importReaderBackgroundPicture(from url: URL) throws -> ReaderBackgroundPicture {
        try describeReaderBackgroundPicture(
            fileName: ReaderCustomBackgroundStorageManager.shared.importBackground(fileURL: url)
        )
    }

    /// A picture imported for a background that was never saved: deleted, unless a saved
    /// background shows it after all.
    func discardReaderBackgroundPicture(fileName: String) {
        guard !readerCustomBackgrounds.contains(where: { $0.imageFileName == fileName }) else { return }
        ReaderCustomBackgroundStorageManager.shared.delete(fileName: fileName)
    }

    private func describeReaderBackgroundPicture(fileName: String) throws -> ReaderBackgroundPicture {
        guard let picture = Self.readerBackgroundPicture(fileName: fileName) else {
            ReaderCustomBackgroundStorageManager.shared.delete(fileName: fileName)
            throw ReaderCustomBackgroundStorageError.cannotReadImage
        }
        return picture
    }

    /// Reads a stored picture back to measure it. Nil when the file is missing or unreadable.
    nonisolated static func readerBackgroundPicture(fileName: String) -> ReaderBackgroundPicture? {
        let url: URL
        do {
            url = try ReaderCustomBackgroundStorageManager.shared.fileURL(fileName: fileName)
        } catch {
            AppLogger.error("⟐ reading background folder unavailable", error: error)
            return nil
        }
        guard let image = UIImage(contentsOfFile: url.path),
              let average = ReaderBackgroundTone.averageColorHex(image: image) else {
            AppLogger.error("⟐ reading background picture unreadable", context: ["file": fileName])
            return nil
        }
        return ReaderBackgroundPicture(
            fileName: fileName,
            averageColorHex: average,
            isDark: ReaderBackgroundTone.isDark(rgbHex: average)
        )
    }

    // MARK: - 匯出全部自訂

    /// Puts a bundle's saved backgrounds into the list — replacing any with the same id,
    /// so importing one bundle twice does not list its backgrounds twice — and returns the
    /// one the exporter wore. A bundle from before saved backgrounds carries only the worn
    /// one, which becomes a saved background of its own.
    func restoreReaderBackgrounds(
        from bundle: AppearanceCustomizationBundle,
        into summary: inout AppearanceImportSummary
    ) -> UUID? {
        if let saved = bundle.savedReaderBackgrounds, !saved.isEmpty {
            for payload in saved {
                var imageFileName: String?
                if let image = payload.image {
                    guard let data = Data(base64Encoded: image.base64) else {
                        AppLogger.error("⟐ bundle reading background picture undecodable", context: ["name": payload.name])
                        continue
                    }
                    do {
                        imageFileName = try ReaderCustomBackgroundStorageManager.shared.importBackground(data: data)
                    } catch {
                        AppLogger.error("⟐ bundle reading background picture unreadable", error: error)
                        continue
                    }
                }
                saveReaderCustomBackground(ReaderCustomBackground(
                    id: payload.id,
                    name: payload.name,
                    colorHex: payload.colorHex,
                    imageFileName: imageFileName,
                    textColorHex: payload.textColorHex,
                    isDark: payload.isDark
                ))
                summary.restoredReaderBackground = true
            }
            return bundle.wornReaderBackgroundID.flatMap { readerCustomBackground(id: $0)?.id }
        }

        guard let legacy = bundle.readerBackground,
              let mode = ReaderCustomBackgroundMode(rawValue: legacy.mode) else { return nil }
        let name = ReaderCustomBackgroundLibrary.unusedName(
            base: localized("自訂背景"),
            among: readerCustomBackgrounds
        )
        let background: ReaderCustomBackground
        switch mode {
        case .image:
            guard let base64 = legacy.image?.base64, let data = Data(base64Encoded: base64) else { return nil }
            do {
                let picture = try importReaderBackgroundPicture(data: data)
                background = ReaderCustomBackground(
                    name: name,
                    colorHex: picture.averageColorHex,
                    imageFileName: picture.fileName,
                    isDark: picture.isDark
                )
            } catch {
                AppLogger.error("⟐ bundle reading background picture unreadable", error: error)
                return nil
            }
        case .color:
            let colorHex = legacy.colorHex ?? 0xF4F5F7
            background = ReaderCustomBackground(
                name: name,
                colorHex: colorHex,
                isDark: ReaderBackgroundTone.isDark(rgbHex: colorHex)
            )
        case .none:
            return nil
        }
        summary.restoredReaderBackground = true
        return saveReaderCustomBackground(background).id
    }

    // MARK: - iCloud

    /// Takes the merged list from iCloud (per-background last-write-wins). Stamps nothing:
    /// the merged values carry the winning device's clock. Anything the merge removed is
    /// taken off the reader and the bound picks, and its picture deleted.
    @MainActor
    func applyReaderCustomBackgroundsSync(_ backgrounds: [ReaderCustomBackground]) {
        let old = readerCustomBackgrounds
        let merged = ReaderCustomBackgroundLibrary.uniqued(backgrounds)
        guard merged != old else { return }
        readerCustomBackgrounds = merged
        let removed = Set(old.map(\.id)).subtracting(merged.map(\.id))
        // Taking a background deleted elsewhere off the reader is the sync's doing, not a
        // choice made here — noted as one, it would outrank the other device's real one.
        let wasApplying = isApplyingReadingSettingsSync
        isApplyingReadingSettingsSync = true
        defer { isApplyingReadingSettingsSync = wasApplying }
        dropReferences(toDeleted: removed)
        reclaimReaderBackgroundPictures(droppedFrom: old)
    }

    // MARK: - Invariants

    /// A bound pick as it can be worn: one naming a saved background that is gone — a
    /// theme's stored pick, say, after the background was deleted — reads as the pick's
    /// starting value, so the picker never shows an empty selection.
    func liveBoundReaderTheme(_ storageValue: String, for appearance: ColorScheme) -> String {
        guard case .custom(let id) = ReaderBoundTheme(storageValue: storageValue),
              readerCustomBackground(id: id) == nil else {
            return storageValue
        }
        return Self.startingBoundReaderTheme(for: appearance).storageValue
    }

    /// What the binding starts as: the appearance theme paints light, 黑色 is dark.
    static func startingBoundReaderTheme(for appearance: ColorScheme) -> ReaderBoundTheme {
        appearance == .dark ? .reading(.night) : .followAppearanceTheme
    }

    /// A reference to a background that is gone falls back to what the setting starts
    /// as: no saved background in the reader, and the binding's starting picks.
    private func dropReferences(toDeleted ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let worn = readerCustomBackgroundID, ids.contains(worn) {
            readerCustomBackgroundID = nil
        }
        for appearance in [ColorScheme.light, .dark] {
            guard case .custom(let id) = boundReaderTheme(for: appearance), ids.contains(id) else { continue }
            setBoundReaderTheme(Self.startingBoundReaderTheme(for: appearance), for: appearance)
        }
    }

    /// Deletes the pictures `old` showed that no saved background shows any more.
    private func reclaimReaderBackgroundPictures(droppedFrom old: [ReaderCustomBackground]) {
        let kept = Set(readerCustomBackgrounds.compactMap(\.imageFileName))
        for fileName in Set(old.compactMap(\.imageFileName)).subtracting(kept) {
            ReaderCustomBackgroundStorageManager.shared.delete(fileName: fileName)
        }
    }
}
