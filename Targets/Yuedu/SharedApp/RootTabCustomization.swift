import Foundation
import SwiftUI
import UIKit

enum RootTabItem: String, CaseIterable, Codable, Hashable, Identifiable {
    case bookshelf
    case explore
    case rss
    case settings
    case search

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .bookshelf: return "書架"
        case .explore: return "探索"
        case .rss: return "RSS 訂閱"
        case .settings: return "設定"
        case .search: return "搜索書籍"
        }
    }

    var defaultSystemImage: String {
        switch self {
        case .bookshelf: return "books.vertical.fill"
        case .explore: return "safari.fill"
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
        guard let image = UIImage(contentsOfFile: fileURL.path), image.size.width > 0, image.size.height > 0 else {
            throw RootTabIconStorageError.cannotReadImage
        }

        let directory = try iconsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(tab.rawValue)-\(slot.rawValue)-\(UUID().uuidString).\(sourceExtension)"
        let destination = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: fileURL, to: destination)

        return RootTabIconAsset(
            tabID: tab.rawValue,
            slotRawValue: slot.rawValue,
            fileName: fileName,
            originalFileName: fileURL.lastPathComponent,
            addedAt: Date()
        )
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
               let image = UIImage(contentsOfFile: url.path) {
                return RootTabRenderedIcon(
                    image: image.rootTabIconPrepared(pointSize: size),
                    isTemplate: false
                )
            }
        }
        return nil
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
        RootTabItem.allCases.map(\.rawValue)
    }

    static func sanitizedRootTabVisibleIDs(_ ids: [String]) -> [String] {
        let requested = Set(ids)
        var visible = RootTabItem.allCases.filter { requested.contains($0.rawValue) }
        if !visible.contains(.settings) {
            visible.append(.settings)
        }
        if !visible.contains(where: \.isContentTab) {
            visible.insert(.bookshelf, at: 0)
        }
        return RootTabItem.allCases
            .filter { tab in visible.contains(tab) }
            .map(\.rawValue)
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
        var ids = rootTabVisibleIDs
        if visible {
            if !ids.contains(tab.rawValue) {
                ids.append(tab.rawValue)
            }
        } else {
            ids.removeAll { $0 == tab.rawValue }
        }
        rootTabVisibleIDs = Self.sanitizedRootTabVisibleIDs(ids)
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
        let oldAsset = rootTabIconAsset(for: tab, slot: slot)
        let asset = try RootTabIconStorageManager.shared.importIcon(fileURL: url, tab: tab, slot: slot)
        if let oldAsset {
            RootTabIconStorageManager.shared.delete(oldAsset)
        }
        rootTabIconAssets.removeAll { $0.tabID == tab.rawValue && $0.slotRawValue == slot.rawValue }
        rootTabIconAssets.append(asset)
        rootTabIconAssets.sort {
            ($0.tabID, $0.slotRawValue) < ($1.tabID, $1.slotRawValue)
        }
        return asset
    }

    func deleteRootTabIcon(tab: RootTabItem, slot: RootTabIconSlot) {
        guard let asset = rootTabIconAsset(for: tab, slot: slot) else { return }
        RootTabIconStorageManager.shared.delete(asset)
        rootTabIconAssets.removeAll { $0.id == asset.id }
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
