import Foundation
import SwiftUI
import UIKit

// MARK: - Bottom tool row items

/// One button in 經典's bottom tool row. The row used to be four hardcoded
/// `toolBtn` calls; it is a list now so 外觀 → 閱讀界面 → 經典 → 自定義 can hide
/// entries and swap their icons.
enum ReaderClassicToolItem: String, CaseIterable, Codable, Hashable, Identifiable {
    case tableOfContents
    case bookmarks
    case nightMode
    case settings

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .tableOfContents: return "目錄"
        case .bookmarks: return "書籤"
        // The live button says 白天 while night mode is on; this is the name the
        // settings screen lists it under.
        case .nightMode: return "深色"
        case .settings: return "設置"
        }
    }

    var defaultSystemImage: String {
        systemImage(isNight: false)
    }

    /// 深色 is the one entry whose symbol depends on the current reading theme.
    func systemImage(isNight: Bool) -> String {
        switch self {
        case .tableOfContents: return "list.bullet"
        case .bookmarks: return "bookmark"
        case .nightMode: return isNight ? "sun.min" : "moon"
        case .settings: return "gearshape"
        }
    }

    /// 設置 is the only way into the reader's own settings from 經典 — hiding it
    /// would strand the reader with no way back. Same rule `RootTabItem.settings`
    /// follows for the app tab bar.
    var isAlwaysVisible: Bool { self == .settings }
}

/// A user-imported replacement for one tool button's symbol.
struct ReaderClassicToolIconAsset: Codable, Equatable, Identifiable {
    var id: String { itemID }
    let itemID: String
    let fileName: String
    let originalFileName: String
    let addedAt: Date

    var item: ReaderClassicToolItem? { ReaderClassicToolItem(rawValue: itemID) }
}

enum ReaderClassicToolIconStorageError: LocalizedError {
    case unsupportedImageFile
    case cannotReadImage
    case missingDocumentsDirectory

    var errorDescription: String? {
        switch self {
        case .unsupportedImageFile:
            return localized("僅支援圖片檔案")
        case .cannotReadImage:
            return localized("無法讀取圖片檔案")
        case .missingDocumentsDirectory:
            return localized("無法存取文件資料夾")
        }
    }
}

/// Own directory, own file names — but the bytes-and-extension decision goes
/// through `ImportedImageNormalizer`, the same one every other image store in the
/// app uses. That normalization is the part that must not fork; the container
/// around it is per-store on purpose (the tab-bar store is keyed by tab + light /
/// dark slot, this one by tool item).
final class ReaderClassicToolIconStorage {
    static let shared = ReaderClassicToolIconStorage()

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importIcon(fileURL: URL, item: ReaderClassicToolItem) throws -> ReaderClassicToolIconAsset {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw ReaderClassicToolIconStorageError.unsupportedImageFile
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ReaderClassicToolIconStorageError.cannotReadImage
        }
        return try importIcon(
            data: data,
            fallbackExtension: sourceExtension,
            originalFileName: fileURL.lastPathComponent,
            item: item
        )
    }

    /// Raw bytes: a photo-library pick has no path to read an extension from.
    func importIcon(
        data: Data,
        fallbackExtension: String = "",
        originalFileName: String,
        item: ReaderClassicToolItem
    ) throws -> ReaderClassicToolIconAsset {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ReaderClassicToolIconStorageError.cannotReadImage
        }
        guard let output = ImportedImageNormalizer.normalize(
            image: image,
            data: data,
            fallbackExtension: fallbackExtension,
            allowedExtensions: allowedExtensions
        ) else {
            throw ReaderClassicToolIconStorageError.cannotReadImage
        }

        let directory = try iconsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(item.rawValue)-\(UUID().uuidString).\(output.fileExtension)"
        let destination = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try output.data.write(to: destination, options: .atomic)

        return ReaderClassicToolIconAsset(
            itemID: item.rawValue,
            fileName: fileName,
            originalFileName: originalFileName,
            addedAt: Date()
        )
    }

    func delete(_ asset: ReaderClassicToolIconAsset) {
        guard let url = try? fileURL(for: asset) else { return }
        try? fileManager.removeItem(at: url)
    }

    func fileURL(for asset: ReaderClassicToolIconAsset) throws -> URL {
        try iconsDirectoryURL().appendingPathComponent(asset.fileName)
    }

    private func iconsDirectoryURL() throws -> URL {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ReaderClassicToolIconStorageError.missingDocumentsDirectory
        }
        return documentsURL.appendingPathComponent("reader-classic-tool-icons", isDirectory: true)
    }
}

// MARK: - Palette

/// Every colour 經典's chrome paints with, resolved once. 外觀 → 閱讀界面 → 經典 →
/// 自定義 can override any of them; anything left alone follows the reading theme
/// exactly as it did before that section existed.
///
/// One type owns the fallbacks so the settings preview and the reader itself can
/// never disagree about what a picked colour looks like. Do not re-derive a
/// fallback at a call site.
struct ReaderClassicChromePalette {
    /// Top bar: 返回 / 書籤 / 書籍詳情.
    let topFill: Color
    let topIcon: Color

    /// Bottom bar: the progress row and the tool row behind it.
    let bottomFill: Color
    let bottomIcon: Color
    /// Progress slider, and the 深色 button while night mode is on.
    let bottomAccent: Color

    /// The four circles floating on the page (刷新／換源／下載／聽書).
    let circleFill: Color
    let circleIcon: Color
    let circleBorder: Color

    init(theme: ReaderTheme, settings: GlobalSettings) {
        topFill = Self.color(settings.readerClassicTopBarFillHex) ?? theme.barColor
        topIcon = Self.color(settings.readerClassicTopBarIconHex) ?? theme.textColor

        bottomFill = Self.color(settings.readerClassicBottomBarFillHex) ?? theme.barColor
        bottomIcon = Self.color(settings.readerClassicBottomBarIconHex) ?? theme.textColor
        bottomAccent = Self.color(settings.readerClassicBottomBarAccentHex) ?? theme.accentColor

        circleFill = Self.color(settings.readerClassicCircleFillHex) ?? theme.barColor
        if let picked = Self.color(settings.readerClassicCircleIconHex) {
            // A hand-picked symbol colour is used exactly as picked — the 0.9 fade
            // only exists to soften the theme's body-text colour into chrome.
            circleIcon = picked
            circleBorder = picked.opacity(0.35)
        } else {
            circleIcon = theme.textColor.opacity(0.9)
            circleBorder = theme.textColor.opacity(0.35)
        }
    }

    private static func color(_ hex: UInt32?) -> Color? {
        hex.map { Color(uiColor: AppearanceThemePreset.hex($0)) }
    }
}

// MARK: - Settings

extension GlobalSettings {
    static var defaultReaderClassicToolVisibleIDs: [String] {
        ReaderClassicToolItem.allCases.map(\.rawValue)
    }

    /// Drops unknown ids (a tool removed in a later version) and force-includes
    /// 設置, mirroring `sanitizedRootTabVisibleIDs`. Order always follows
    /// `allCases` so the row cannot be reshuffled by persistence order.
    static func sanitizedReaderClassicToolVisibleIDs(_ ids: [String]) -> [String] {
        let requested = Set(ids)
        return ReaderClassicToolItem.allCases
            .filter { requested.contains($0.rawValue) || $0.isAlwaysVisible }
            .map(\.rawValue)
    }

    var visibleReaderClassicToolItems: [ReaderClassicToolItem] {
        Self.sanitizedReaderClassicToolVisibleIDs(readerClassicToolVisibleIDs)
            .compactMap(ReaderClassicToolItem.init(rawValue:))
    }

    func isReaderClassicToolVisible(_ item: ReaderClassicToolItem) -> Bool {
        visibleReaderClassicToolItems.contains(item)
    }

    func setReaderClassicTool(_ item: ReaderClassicToolItem, visible: Bool) {
        guard !item.isAlwaysVisible else { return }
        var ids = readerClassicToolVisibleIDs
        if visible {
            if !ids.contains(item.rawValue) { ids.append(item.rawValue) }
        } else {
            ids.removeAll { $0 == item.rawValue }
        }
        readerClassicToolVisibleIDs = Self.sanitizedReaderClassicToolVisibleIDs(ids)
    }

    static func loadReaderClassicToolIcons() -> [ReaderClassicToolIconAsset] {
        guard let data = UserDefaults.standard.data(forKey: readerClassicToolIconsKey),
              let decoded = try? JSONDecoder().decode([ReaderClassicToolIconAsset].self, from: data)
        else {
            return []
        }
        return decoded.filter { $0.item != nil }
    }

    static func saveReaderClassicToolIcons(_ assets: [ReaderClassicToolIconAsset]) {
        if assets.isEmpty {
            UserDefaults.standard.removeObject(forKey: readerClassicToolIconsKey)
            return
        }
        if let data = try? JSONEncoder().encode(assets) {
            UserDefaults.standard.set(data, forKey: readerClassicToolIconsKey)
        }
    }

    func readerClassicToolIcon(for item: ReaderClassicToolItem) -> ReaderClassicToolIconAsset? {
        readerClassicToolIcons.first { $0.itemID == item.rawValue }
    }

    func readerClassicToolIconURL(for asset: ReaderClassicToolIconAsset) -> URL? {
        try? ReaderClassicToolIconStorage.shared.fileURL(for: asset)
    }

    func readerClassicToolIconImage(for item: ReaderClassicToolItem) -> UIImage? {
        guard let asset = readerClassicToolIcon(for: item),
              let url = readerClassicToolIconURL(for: asset) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    @discardableResult
    func importReaderClassicToolIcon(
        from url: URL,
        item: ReaderClassicToolItem
    ) throws -> ReaderClassicToolIconAsset {
        adoptReaderClassicToolIcon(
            try ReaderClassicToolIconStorage.shared.importIcon(fileURL: url, item: item),
            item: item
        )
    }

    @discardableResult
    func importReaderClassicToolIcon(
        data: Data,
        originalFileName: String,
        item: ReaderClassicToolItem
    ) throws -> ReaderClassicToolIconAsset {
        adoptReaderClassicToolIcon(
            try ReaderClassicToolIconStorage.shared.importIcon(
                data: data,
                originalFileName: originalFileName,
                item: item
            ),
            item: item
        )
    }

    private func adoptReaderClassicToolIcon(
        _ asset: ReaderClassicToolIconAsset,
        item: ReaderClassicToolItem
    ) -> ReaderClassicToolIconAsset {
        if let old = readerClassicToolIcon(for: item) {
            ReaderClassicToolIconStorage.shared.delete(old)
        }
        var assets = readerClassicToolIcons
        assets.removeAll { $0.itemID == item.rawValue }
        assets.append(asset)
        assets.sort { $0.itemID < $1.itemID }
        readerClassicToolIcons = assets
        return asset
    }

    func deleteReaderClassicToolIcon(for item: ReaderClassicToolItem) {
        guard let asset = readerClassicToolIcon(for: item) else { return }
        ReaderClassicToolIconStorage.shared.delete(asset)
        readerClassicToolIcons.removeAll { $0.id == asset.id }
    }

    /// Anything at all changed from the stock 經典 look.
    var hasReaderClassicChromeOverride: Bool {
        readerClassicTopBarFillHex != nil
            || readerClassicTopBarIconHex != nil
            || readerClassicBottomBarFillHex != nil
            || readerClassicBottomBarIconHex != nil
            || readerClassicBottomBarAccentHex != nil
            || readerClassicCircleFillHex != nil
            || readerClassicCircleIconHex != nil
            || !readerClassicToolIcons.isEmpty
            || visibleReaderClassicToolItems.count != ReaderClassicToolItem.allCases.count
    }

    /// Back to the stock look: colours follow the reading theme again, every tool
    /// button is visible, and imported icon files are deleted (not just forgotten).
    func resetReaderClassicChrome() {
        readerClassicTopBarFillHex = nil
        readerClassicTopBarIconHex = nil
        readerClassicBottomBarFillHex = nil
        readerClassicBottomBarIconHex = nil
        readerClassicBottomBarAccentHex = nil
        readerClassicCircleFillHex = nil
        readerClassicCircleIconHex = nil
        for asset in readerClassicToolIcons {
            ReaderClassicToolIconStorage.shared.delete(asset)
        }
        readerClassicToolIcons = []
        readerClassicToolVisibleIDs = Self.defaultReaderClassicToolVisibleIDs
    }
}
