import Foundation
import SwiftUI
import UIKit

// MARK: - Recolorable surfaces

/// One recolorable surface of the reader's chrome. The top bar is system glass we
/// deliberately do not repaint, so only its symbols take a colour.
enum ReaderChromeSlot: String, CaseIterable, Codable, Hashable, Identifiable {
    case topIcon
    case bottomFill
    case bottomIcon
    case bottomAccent
    case panelFill
    case panelText

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .topIcon: return "頂部圖示顏色"
        case .bottomFill: return "底部底色"
        case .bottomIcon: return "底部圖示顏色"
        case .bottomAccent: return "底部強調色"
        case .panelFill: return "書卡面板底色"
        case .panelText: return "書卡面板文字顏色"
        }
    }
}

// MARK: - Customizable buttons

/// A button whose icon can be replaced and whose visibility can be switched off.
protocol ReaderChromeIconItem: Identifiable, Hashable {
    var storageID: String { get }
    var titleKey: String { get }
    var defaultSystemImage: String { get }
    /// A button that must never leave, because nothing else reaches what it opens.
    var isAlwaysVisible: Bool { get }
}

extension ReaderChromeIconItem {
    var isAlwaysVisible: Bool { false }
}

/// The tools in the bottom bar's capsule, in the order it draws them. 更多 follows
/// them and is not an item: it holds 書籤, which has nowhere else to live.
enum ReaderChromeToolItem: String, CaseIterable, Codable, Hashable, Identifiable, ReaderChromeIconItem {
    case tableOfContents
    case nightMode
    case listen
    /// Shown as 主題. The case keeps its old name so the stored `tool.settings` id —
    /// hidden lists, imported icons, theme packs — still points at this button.
    case settings

    var id: String { rawValue }
    var storageID: String { "tool.\(rawValue)" }

    var titleKey: String {
        switch self {
        case .tableOfContents: return "目錄"
        case .settings: return "主題"
        case .listen: return "聽書"
        // The live button says 白天 while night mode is on; this is the name the
        // settings screen lists it under.
        case .nightMode: return "深色"
        }
    }

    var defaultSystemImage: String { systemImage(isNight: false) }

    /// 深色 is the one entry whose symbol depends on the current reading theme. 主題 is
    /// drawn as a serif "Aa" in the bar; this symbol is what the settings rows show.
    func systemImage(isNight: Bool) -> String {
        switch self {
        case .tableOfContents: return "list.bullet"
        case .settings: return "textformat"
        case .listen: return "headphones"
        case .nightMode: return isNight ? "sun.min" : "moon"
        }
    }

    /// 主題 is the only way into the reader's own settings — hiding it would strand
    /// the reader with no way back. Same rule `RootTabItem.settings` follows for the
    /// app tab bar.
    var isAlwaysVisible: Bool { self == .settings }
}

/// The book-scoped actions: in the card behind the cover, except the AI ones, which are
/// in the bottom bar's 更多 (`isInMoreMenu`). Backed by `ReaderSecondaryAction.ID`, which
/// is what `ReaderView` actually builds the live lists from.
enum ReaderChromeActionItem: String, CaseIterable, Codable, Hashable, Identifiable, ReaderChromeIconItem {
    case refresh
    case changeSource
    case download
    case aiAssistant
    case translation
    case openWebPage

    var id: String { rawValue }
    var storageID: String { "action.\(rawValue)" }

    /// AI 助手 and AI 翻譯 are in 更多 rather than the book card.
    var isInMoreMenu: Bool {
        switch self {
        case .aiAssistant, .translation: return true
        case .refresh, .changeSource, .download, .openWebPage: return false
        }
    }

    var titleKey: String {
        switch self {
        case .refresh: return "刷新"
        case .changeSource: return "換源"
        case .download: return "下載"
        case .aiAssistant: return "AI 助手"
        case .translation: return "AI 翻譯"
        case .openWebPage: return "開啟網頁"
        }
    }

    var defaultSystemImage: String {
        switch self {
        case .refresh: return "arrow.clockwise"
        case .changeSource: return "arrow.left.and.right"
        case .download: return "arrow.down.circle"
        case .aiAssistant: return "sparkles"
        case .translation: return "translate"
        case .openWebPage: return "globe"
        }
    }

    /// nil for an action that is not a customization item (the source's own button).
    init?(_ id: ReaderSecondaryAction.ID) {
        switch id {
        case .refresh: self = .refresh
        case .changeSource: self = .changeSource
        case .download: self = .download
        case .aiAssistant: self = .aiAssistant
        case .translation: self = .translation
        case .openWebPage: self = .openWebPage
        case .sourceCustomButton, .sourceLogin: return nil
        }
    }
}

// MARK: - Imported icon storage

/// A user-imported replacement for one button's symbol, keyed by that button's
/// `storageID` so tools and actions share one store.
struct ReaderChromeIconAsset: Codable, Equatable, Identifiable {
    var id: String { itemID }
    let itemID: String
    let fileName: String
    let originalFileName: String
    let addedAt: Date
}

enum ReaderChromeIconStorageError: LocalizedError {
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
/// dark slot, this one by reader button).
final class ReaderChromeIconStorage: Sendable {
    static let shared = ReaderChromeIconStorage()

    private var fileManager: FileManager { .default }
    private let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif"]

    private init() {}

    func importIcon(fileURL: URL, itemID: String) throws -> ReaderChromeIconAsset {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw ReaderChromeIconStorageError.unsupportedImageFile
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ReaderChromeIconStorageError.cannotReadImage
        }
        return try importIcon(
            data: data,
            fallbackExtension: sourceExtension,
            originalFileName: fileURL.lastPathComponent,
            itemID: itemID
        )
    }

    /// Raw bytes: a photo-library pick has no path to read an extension from.
    func importIcon(
        data: Data,
        fallbackExtension: String = "",
        originalFileName: String,
        itemID: String
    ) throws -> ReaderChromeIconAsset {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ReaderChromeIconStorageError.cannotReadImage
        }
        guard let output = ImportedImageNormalizer.normalize(
            image: image,
            data: data,
            fallbackExtension: fallbackExtension,
            allowedExtensions: allowedExtensions
        ) else {
            throw ReaderChromeIconStorageError.cannotReadImage
        }

        let directory = try iconsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(itemID)-\(UUID().uuidString).\(output.fileExtension)"
        let destination = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try output.data.write(to: destination, options: .atomic)

        return ReaderChromeIconAsset(
            itemID: itemID,
            fileName: fileName,
            originalFileName: originalFileName,
            addedAt: Date()
        )
    }

    func delete(_ asset: ReaderChromeIconAsset) {
        guard let url = try? fileURL(for: asset) else { return }
        try? fileManager.removeItem(at: url)
    }

    func fileURL(for asset: ReaderChromeIconAsset) throws -> URL {
        try iconsDirectoryURL().appendingPathComponent(asset.fileName)
    }

    private func iconsDirectoryURL() throws -> URL {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ReaderChromeIconStorageError.missingDocumentsDirectory
        }
        return documentsURL.appendingPathComponent("reader-chrome-icons", isDirectory: true)
    }
}

// MARK: - Palette

/// Every colour the reader's chrome paints with, resolved once. 外觀 → 閱讀界面 →
/// 自定義 can override any slot; anything left alone follows the reading theme.
///
/// One type owns the fallbacks so the settings preview and the reader itself can
/// never disagree about what a picked colour looks like. Do not re-derive a
/// fallback at a call site.
struct ReaderChromePalette {
    /// Top bar symbols. The bar itself is system glass with no fill of ours.
    let topIcon: Color

    /// Bottom bar: the scrubber capsule and the tool capsule under it.
    let bottomFill: Color
    let bottomIcon: Color
    /// The 深色 button while night mode is on, and the book card's symbols.
    let bottomAccent: Color

    /// The book card hanging off the cover thumbnail.
    let panelFill: Color
    let panelText: Color

    @MainActor
    init(theme: ReaderTheme, settings: GlobalSettings) {
        func picked(_ slot: ReaderChromeSlot) -> Color? {
            settings.readerChromeColor(slot: slot)
                .map { Color(uiColor: AppearanceThemePreset.hex($0)) }
        }

        topIcon = picked(.topIcon) ?? theme.textColor
        bottomFill = picked(.bottomFill) ?? theme.barColor
        bottomIcon = picked(.bottomIcon) ?? theme.textColor
        bottomAccent = picked(.bottomAccent) ?? theme.accentColor
        panelFill = picked(.panelFill) ?? theme.barColor
        panelText = picked(.panelText) ?? theme.textColor
    }

    /// The resolved colour behind one slot, so a settings row can open its picker on
    /// what is actually on screen without re-deriving the fallback.
    func color(for slot: ReaderChromeSlot) -> Color {
        switch slot {
        case .topIcon: return topIcon
        case .bottomFill: return bottomFill
        case .bottomIcon: return bottomIcon
        case .bottomAccent: return bottomAccent
        case .panelFill: return panelFill
        case .panelText: return panelText
        }
    }
}

// MARK: - Settings

extension GlobalSettings {
    // MARK: Colours

    /// Stored as `"modern.<slot>"`. The prefix is from when 經典 and 現代 each kept their
    /// own colours; it stays so the colours people already picked — and the ones theme
    /// packs carry — keep applying. Keys under any other prefix are no longer read.
    private static func chromeColorKey(_ slot: ReaderChromeSlot) -> String {
        "modern.\(slot.rawValue)"
    }

    func readerChromeColor(slot: ReaderChromeSlot) -> UInt32? {
        readerChromeColors[Self.chromeColorKey(slot)]
    }

    /// Pass nil to hand the slot back to the reading theme.
    func setReaderChromeColor(_ rgbHex: UInt32?, slot: ReaderChromeSlot) {
        let key = Self.chromeColorKey(slot)
        var colors = readerChromeColors
        if let rgbHex {
            colors[key] = rgbHex
        } else {
            colors.removeValue(forKey: key)
        }
        guard colors != readerChromeColors else { return }
        readerChromeColors = colors
    }

    static func loadReaderChromeColors() -> [String: UInt32] {
        guard let stored = UserDefaults.standard.dictionary(forKey: readerChromeColorsKey) as? [String: Int] else {
            return [:]
        }
        return stored.mapValues { UInt32(clamping: $0) }
    }

    static func saveReaderChromeColors(_ colors: [String: UInt32]) {
        if colors.isEmpty {
            UserDefaults.standard.removeObject(forKey: readerChromeColorsKey)
        } else {
            UserDefaults.standard.set(colors.mapValues { Int($0) }, forKey: readerChromeColorsKey)
        }
    }

    // MARK: Visibility

    func isReaderChromeItemVisible(_ item: some ReaderChromeIconItem) -> Bool {
        item.isAlwaysVisible || !readerChromeHiddenIDs.contains(item.storageID)
    }

    func setReaderChromeItem(_ item: some ReaderChromeIconItem, visible: Bool) {
        guard !item.isAlwaysVisible else { return }
        var hidden = Set(readerChromeHiddenIDs)
        if visible {
            hidden.remove(item.storageID)
        } else {
            hidden.insert(item.storageID)
        }
        let sorted = hidden.sorted()
        guard sorted != readerChromeHiddenIDs else { return }
        readerChromeHiddenIDs = sorted
    }

    /// Bottom bar tools in `allCases` order, so persistence can never reshuffle the row.
    var visibleReaderChromeToolItems: [ReaderChromeToolItem] {
        ReaderChromeToolItem.allCases.filter { isReaderChromeItemVisible($0) }
    }

    /// Filters the live, book-dependent action list — `ReaderView` decides which
    /// actions *apply* to this book, this decides which of those the reader wants
    /// to see.
    func visibleReaderSecondaryActions(_ actions: [ReaderSecondaryAction]) -> [ReaderSecondaryAction] {
        actions.filter { action in
            // An action that is not a customization item cannot be hidden from here.
            ReaderChromeActionItem(action.id).map(isReaderChromeItemVisible) ?? true
        }
    }

    // MARK: Icons

    static func loadReaderChromeIcons() -> [ReaderChromeIconAsset] {
        guard let data = UserDefaults.standard.data(forKey: readerChromeIconsKey),
              let decoded = try? JSONDecoder().decode([ReaderChromeIconAsset].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func saveReaderChromeIcons(_ assets: [ReaderChromeIconAsset]) {
        if assets.isEmpty {
            UserDefaults.standard.removeObject(forKey: readerChromeIconsKey)
            return
        }
        if let data = try? JSONEncoder().encode(assets) {
            UserDefaults.standard.set(data, forKey: readerChromeIconsKey)
        }
    }

    func readerChromeIcon(for item: some ReaderChromeIconItem) -> ReaderChromeIconAsset? {
        readerChromeIcons.first { $0.itemID == item.storageID }
    }

    func readerChromeIconURL(for asset: ReaderChromeIconAsset) -> URL? {
        try? ReaderChromeIconStorage.shared.fileURL(for: asset)
    }

    func readerChromeIconImage(for item: some ReaderChromeIconItem) -> UIImage? {
        guard let asset = readerChromeIcon(for: item),
              let url = readerChromeIconURL(for: asset) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    @discardableResult
    func importReaderChromeIcon(from url: URL, item: some ReaderChromeIconItem) throws -> ReaderChromeIconAsset {
        adoptReaderChromeIcon(
            try ReaderChromeIconStorage.shared.importIcon(fileURL: url, itemID: item.storageID)
        )
    }

    @discardableResult
    func importReaderChromeIcon(
        data: Data,
        originalFileName: String,
        item: some ReaderChromeIconItem
    ) throws -> ReaderChromeIconAsset {
        adoptReaderChromeIcon(
            try ReaderChromeIconStorage.shared.importIcon(
                data: data,
                originalFileName: originalFileName,
                itemID: item.storageID
            )
        )
    }

    private func adoptReaderChromeIcon(_ asset: ReaderChromeIconAsset) -> ReaderChromeIconAsset {
        let replaced = readerChromeIcons.first { $0.itemID == asset.itemID }
        var assets = readerChromeIcons
        assets.removeAll { $0.itemID == asset.itemID }
        assets.append(asset)
        assets.sort { $0.itemID < $1.itemID }
        readerChromeIcons = assets
        discardReaderChromeIconFile(replaced)
        return asset
    }

    func deleteReaderChromeIcon(for item: some ReaderChromeIconItem) {
        guard let asset = readerChromeIcon(for: item) else { return }
        readerChromeIcons.removeAll { $0.id == asset.id }
        discardReaderChromeIconFile(asset)
    }

    /// Every caller changes `readerChromeIcons` *before* getting here: that assignment's
    /// write-back takes the old artwork off the selected theme, so the check below can
    /// tell "nobody wants this any more" from "another theme, a pack original or the
    /// user's own set still draws it". Deleting first — which all three used to do —
    /// pulled an imported pack's icon out from under 重置此主題 the moment it was
    /// replaced. Same rule as the tab icons (`discardRootTabIconFile`).
    private func discardReaderChromeIconFile(_ asset: ReaderChromeIconAsset?) {
        guard let asset, !isReaderChromeIconFileReferenced(asset.fileName) else { return }
        ReaderChromeIconStorage.shared.delete(asset)
    }

    // MARK: Reset

    /// Anything at all changed from the stock look.
    var hasReaderChromeOverride: Bool {
        ReaderChromeSlot.allCases.contains { readerChromeColor(slot: $0) != nil }
            || !readerChromeIcons.isEmpty
            || !readerChromeHiddenIDs.isEmpty
    }

    /// Back to the stock look: every colour follows the reading theme again, every
    /// button is visible, and imported icon files are deleted (not just forgotten)
    /// unless a theme still draws them.
    func resetReaderChrome() {
        readerChromeColors = [:]
        let removed = readerChromeIcons
        readerChromeIcons = []
        for asset in removed {
            discardReaderChromeIconFile(asset)
        }
        readerChromeHiddenIDs = []
    }
}
