import Foundation
import SwiftUI
import UIKit

enum RootTabItem: String, CaseIterable, Codable, Hashable, Identifiable {
    case bookshelf
    case explore
    /// 資源庫 (Phase 5 plan, decisions 30 and 31): every library and source, RSS's feeds too.
    case library
    case search
    case settings
    /// No longer a tab (decision 30): its feeds are in 資源庫. Kept so a reader's custom RSS
    /// tab icon and the lists and theme packs naming it still decode; never drawn.
    case rss

    var id: String { rawValue }

    /// The tabs drawn, in order: 書架・探索・資源庫・設定・搜尋 (decision 30; 搜尋 moved to the far
    /// right, 2026-10-16). A saved list follows this order (`sanitizedRootTabVisibleIDs`).
    static let tabs: [RootTabItem] = [.bookshelf, .explore, .library, .settings, .search]

    /// Tabs added after readers had saved which tabs they show. A saved list that does not name
    /// one predates it, so the tab is shown; hiding it writes `hiddenMarker` into the list.
    static let addedLater: [RootTabItem] = [.library]

    /// What a saved list holds for a tab in `addedLater` the reader hid.
    var hiddenMarker: String { "-" + rawValue }

    var titleKey: String {
        switch self {
        case .bookshelf: return "書架"
        case .explore: return "探索"
        case .library: return "資源庫"
        case .rss: return "RSS 訂閱"
        case .settings: return "設定"
        case .search: return "搜索"
        }
    }

    var defaultSystemImage: String {
        switch self {
        case .bookshelf: return "books.vertical.fill"
        case .explore: return "safari.fill"
        case .library: return "building.columns.fill"
        case .rss: return "newspaper.fill"
        case .settings: return "gearshape.fill"
        // No filled variant exists for the glass; this is the intended icon.
        case .search: return "magnifyingglass"
        }
    }

    var isAlwaysVisible: Bool {
        self == .settings
    }

    var isContentTab: Bool {
        self != .settings
    }
}

enum RootTabIconSlot: String, CaseIterable, Codable, Hashable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .light: return "淺色圖標"
        case .dark: return "深色圖標"
        }
    }

    static func preferredSlots(colorScheme: ColorScheme) -> [RootTabIconSlot] {
        colorScheme == .dark ? [.dark, .light] : [.light]
    }
}

struct RootTabIconAsset: Codable, Equatable, Identifiable {
    var id: String { "\(tabID)-\(slotRawValue)" }
    let tabID: String
    let slotRawValue: String
    let fileName: String
    let originalFileName: String
    let addedAt: Date

    var tab: RootTabItem? { RootTabItem(rawValue: tabID) }
    var slot: RootTabIconSlot? { RootTabIconSlot(rawValue: slotRawValue) }
}

enum RootTabIconStorageError: LocalizedError {
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

final class RootTabIconStorageManager {
    static let shared = RootTabIconStorageManager()

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importIcon(fileURL: URL, tab: RootTabItem, slot: RootTabIconSlot) throws -> RootTabIconAsset {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw RootTabIconStorageError.unsupportedImageFile
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw RootTabIconStorageError.cannotReadImage
        }
        return try importIcon(
            data: data,
            fallbackExtension: sourceExtension,
            originalFileName: fileURL.lastPathComponent,
            tab: tab,
            slot: slot
        )
    }

    /// Import from raw bytes: a photo-library pick, or an icon restored out of a
    /// customization bundle. `fallbackExtension` is empty for a Photos pick,
    /// which has no file name to key the container off.
    func importIcon(
        data: Data,
        fallbackExtension: String = "",
        originalFileName: String,
        tab: RootTabItem,
        slot: RootTabIconSlot
    ) throws -> RootTabIconAsset {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw RootTabIconStorageError.cannotReadImage
        }
        guard let output = ImportedImageNormalizer.normalize(
            image: image,
            data: data,
            fallbackExtension: fallbackExtension,
            allowedExtensions: allowedExtensions
        ) else {
            throw RootTabIconStorageError.cannotReadImage
        }

        let directory = try iconsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(tab.rawValue)-\(slot.rawValue)-\(UUID().uuidString).\(output.fileExtension)"
        let destination = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try output.data.write(to: destination, options: .atomic)

        return RootTabIconAsset(
            tabID: tab.rawValue,
            slotRawValue: slot.rawValue,
            fileName: fileName,
            originalFileName: originalFileName,
            addedAt: Date()
        )
    }

    /// Bytes of a stored icon, for embedding into an export bundle.
    func fileData(for asset: RootTabIconAsset) -> Data? {
        guard let url = try? fileURL(for: asset) else { return nil }
        return try? Data(contentsOf: url)
    }

    func delete(_ asset: RootTabIconAsset) {
        guard let url = try? fileURL(for: asset) else { return }
        try? fileManager.removeItem(at: url)
    }

    func fileURL(for asset: RootTabIconAsset) throws -> URL {
        try iconsDirectoryURL().appendingPathComponent(asset.fileName)
    }

    private func iconsDirectoryURL() throws -> URL {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw RootTabIconStorageError.missingDocumentsDirectory
        }
        return documentsURL.appendingPathComponent("root-tab-icons", isDirectory: true)
    }
}

struct RootTabRenderedIcon {
    let image: UIImage
    let isTemplate: Bool
}

enum RootTabIconRenderer {
    @MainActor
    static func customIcon(
        for tab: RootTabItem,
        colorScheme: ColorScheme,
        pointSize: CGFloat,
        settings: GlobalSettings = .shared
    ) -> RootTabRenderedIcon? {
        let size = Self.sanitizedIconSize(pointSize)
        for slot in RootTabIconSlot.preferredSlots(colorScheme: colorScheme) {
            if let asset = settings.rootTabIconAsset(for: tab, slot: slot),
               let url = settings.rootTabIconURL(for: asset),
               let image = preparedImage(at: url, pointSize: size) {
                return RootTabRenderedIcon(image: image, isTemplate: false)
            }
        }
        return nil
    }

    /// Decoded and redrawn icons, by file, its modification date and the size drawn.
    ///
    /// `customIcon` is called from the root view's body, for every tab, on every root render;
    /// it read the file and redrew it each time. The modification date is part of the key, so
    /// an icon replaced under the same name is read again.
    private static let preparedImages = ConcurrentCache<UIImage>()

    private static func preparedImage(at url: URL, pointSize: CGFloat) -> UIImage? {
        let modified: Date
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes[.modificationDate] as? Date ?? .distantPast
        } catch {
            // A missing file is the ordinary "no custom icon here"; nothing to log.
            return nil
        }
        let key = "\(url.path)|\(modified.timeIntervalSince1970)|\(pointSize)"
        if let cached = preparedImages.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let prepared = image.rootTabIconPrepared(pointSize: pointSize)
        preparedImages.setObject(prepared, forKey: key)
        return prepared
    }

    static func systemIcon(
        for tab: RootTabItem,
        pointSize: CGFloat
    ) -> RootTabRenderedIcon {
        let size = Self.sanitizedIconSize(pointSize)
        let configuration = UIImage.SymbolConfiguration(
            pointSize: size,
            weight: .regular
        )
        let image = UIImage(systemName: tab.defaultSystemImage, withConfiguration: configuration)
            ?? UIImage(systemName: tab.defaultSystemImage, withConfiguration: configuration)
            ?? UIImage(systemName: "circle", withConfiguration: configuration)
            ?? UIImage()
        return RootTabRenderedIcon(image: image.withRenderingMode(.alwaysTemplate), isTemplate: true)
    }

    static func sanitizedIconSize(_ value: CGFloat) -> CGFloat {
        min(max(value, 22), 36)
    }
}

extension GlobalSettings {
    static let defaultRootTabIconSize = 0.0
    static let initialCustomRootTabIconSize = 28.0

    static var defaultRootTabVisibleIDs: [String] {
        RootTabItem.tabs.map(\.rawValue)
    }

    /// The tabs shown, in `RootTabItem.tabs` order, then the markers of the later tabs hidden.
    /// A tab added later that the list does not name is shown: the list predates it.
    static func sanitizedRootTabVisibleIDs(_ ids: [String]) -> [String] {
        let requested = Set(ids)
        let hidden = RootTabItem.addedLater.filter { requested.contains($0.hiddenMarker) && !requested.contains($0.rawValue) }
        var visible = RootTabItem.tabs.filter { tab in
            requested.contains(tab.rawValue) || (RootTabItem.addedLater.contains(tab) && !hidden.contains(tab))
        }
        if !visible.contains(.settings) {
            visible.append(.settings)
        }
        if !visible.contains(where: \.isContentTab) {
            visible.insert(.bookshelf, at: 0)
        }
        return RootTabItem.tabs.filter { visible.contains($0) }.map(\.rawValue)
            + hidden.filter { !visible.contains($0) }.map(\.hiddenMarker)
    }

    /// `ids` with `tab` shown or hidden; a later tab hidden leaves its marker.
    static func updatedRootTabVisibleIDs(_ ids: [String], setting tab: RootTabItem, visible: Bool) -> [String] {
        var ids = ids.filter { $0 != tab.rawValue && $0 != tab.hiddenMarker }
        if visible {
            ids.append(tab.rawValue)
        } else if RootTabItem.addedLater.contains(tab) {
            ids.append(tab.hiddenMarker)
        }
        return sanitizedRootTabVisibleIDs(ids)
    }

    static func sanitizedRootTabIconSize(_ value: Double) -> Double {
        guard value > 0.001 else { return defaultRootTabIconSize }
        return Double(RootTabIconRenderer.sanitizedIconSize(CGFloat(value)))
    }

    var usesCustomRootTabIconSize: Bool {
        rootTabIconSize > 0.001
    }

    var visibleRootTabs: [RootTabItem] {
        Self.sanitizedRootTabVisibleIDs(rootTabVisibleIDs)
            .compactMap(RootTabItem.init(rawValue:))
    }

    func isRootTabVisible(_ tab: RootTabItem) -> Bool {
        visibleRootTabs.contains(tab)
    }

    func setRootTab(_ tab: RootTabItem, visible: Bool) {
        guard !tab.isAlwaysVisible else { return }
        rootTabVisibleIDs = Self.updatedRootTabVisibleIDs(rootTabVisibleIDs, setting: tab, visible: visible)
    }

    func fallbackRootTab(for tab: RootTabItem) -> RootTabItem {
        visibleRootTabs.contains(tab) ? tab : visibleRootTabs.first ?? .bookshelf
    }

    static func loadRootTabIconAssets() -> [RootTabIconAsset] {
        guard let data = UserDefaults.standard.data(forKey: rootTabIconAssetsKey),
              let decoded = try? JSONDecoder().decode([RootTabIconAsset].self, from: data) else {
            return []
        }
        return decoded.filter { asset in
            asset.tab != nil && asset.slot != nil
        }
    }

    static func saveRootTabIconAssets(_ assets: [RootTabIconAsset]) {
        if assets.isEmpty {
            UserDefaults.standard.removeObject(forKey: rootTabIconAssetsKey)
            return
        }
        if let data = try? JSONEncoder().encode(assets) {
            UserDefaults.standard.set(data, forKey: rootTabIconAssetsKey)
        }
    }

    func rootTabIconAsset(for tab: RootTabItem, slot: RootTabIconSlot) -> RootTabIconAsset? {
        rootTabIconAssets.first { $0.tabID == tab.rawValue && $0.slotRawValue == slot.rawValue }
    }

    func rootTabIconURL(for asset: RootTabIconAsset) -> URL? {
        try? RootTabIconStorageManager.shared.fileURL(for: asset)
    }

    @discardableResult
    func importRootTabIcon(from url: URL, tab: RootTabItem, slot: RootTabIconSlot) throws -> RootTabIconAsset {
        try adoptRootTabIcon(
            RootTabIconStorageManager.shared.importIcon(fileURL: url, tab: tab, slot: slot),
            tab: tab,
            slot: slot
        )
    }

    @discardableResult
    func importRootTabIcon(
        data: Data,
        originalFileName: String,
        tab: RootTabItem,
        slot: RootTabIconSlot
    ) throws -> RootTabIconAsset {
        try adoptRootTabIcon(
            RootTabIconStorageManager.shared.importIcon(
                data: data,
                originalFileName: originalFileName,
                tab: tab,
                slot: slot
            ),
            tab: tab,
            slot: slot
        )
    }

    private func adoptRootTabIcon(
        _ asset: RootTabIconAsset,
        tab: RootTabItem,
        slot: RootTabIconSlot
    ) -> RootTabIconAsset {
        let replaced = rootTabIconAsset(for: tab, slot: slot)
        rootTabIconAssets.removeAll { $0.tabID == tab.rawValue && $0.slotRawValue == slot.rawValue }
        rootTabIconAssets.append(asset)
        rootTabIconAssets.sort {
            ($0.tabID, $0.slotRawValue) < ($1.tabID, $1.slotRawValue)
        }
        discardRootTabIconFile(replaced)
        return asset
    }

    func deleteRootTabIcon(tab: RootTabItem, slot: RootTabIconSlot) {
        guard let asset = rootTabIconAsset(for: tab, slot: slot) else { return }
        rootTabIconAssets.removeAll { $0.id == asset.id }
        discardRootTabIconFile(asset)
    }

    /// Both callers above mutate `rootTabIconAssets` *before* getting here on purpose:
    /// that assignment's write-back takes the old artwork off the selected theme, so
    /// the reference check below can tell "nobody wants this any more" from "another
    /// theme still draws it". Deleting first — which is what both used to do — would
    /// pull a shared icon out from under every other theme naming it.
    private func discardRootTabIconFile(_ asset: RootTabIconAsset?) {
        guard let asset, !isRootTabIconFileReferenced(asset.fileName) else { return }
        RootTabIconStorageManager.shared.delete(asset)
    }
}

private extension UIImage {
    func rootTabIconPrepared(pointSize: CGFloat) -> UIImage {
        guard size.width > 0, size.height > 0 else { return self }
        let ratio = min(pointSize / size.width, pointSize / size.height)
        let drawSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let origin = CGPoint(
            x: (pointSize - drawSize.width) / 2,
            y: (pointSize - drawSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize), format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: origin, size: drawSize))
        }.withRenderingMode(.alwaysOriginal)
    }
}
