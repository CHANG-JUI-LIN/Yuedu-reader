import Foundation
import SwiftUI
import UIKit

// MARK: - Which interface a colour belongs to

/// The two reader interfaces that own hand-paintable chrome. Apple Books is
/// deliberately absent: it renders through system toolbars with no surface of its
/// own to recolor.
enum ReaderChromeInterface: String, CaseIterable, Codable, Hashable, Identifiable {
    case classic
    case modern

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .classic: return "經典"
        case .modern: return "現代"
        }
    }

    init?(_ interface: AppearanceReaderInterface) {
        switch interface {
        case .classic: self = .classic
        case .modern: self = .modern
        case .appleBooks: return nil
        }
    }
}

/// One recolorable surface. Not every interface has every one — 現代's top bar is
/// system glass we deliberately do not repaint, and only 經典 floats circle buttons
/// over the page — so `appliesTo` decides which rows the settings screen offers.
enum ReaderChromeSlot: String, CaseIterable, Codable, Hashable, Identifiable {
    case topFill
    case topIcon
    case bottomFill
    case bottomIcon
    case bottomAccent
    case circleFill
    case circleIcon
    case panelFill
    case panelText

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .topFill: return "頂部底色"
        case .topIcon: return "頂部圖示顏色"
        case .bottomFill: return "底部底色"
        case .bottomIcon: return "底部圖示顏色"
        case .bottomAccent: return "底部強調色"
        case .circleFill: return "圓形按鈕底色"
        case .circleIcon: return "圓形按鈕圖示顏色"
        case .panelFill: return "書卡面板底色"
        case .panelText: return "書卡面板文字顏色"
        }
    }

    func appliesTo(_ interface: ReaderChromeInterface) -> Bool {
        switch self {
        case .bottomFill, .bottomIcon, .bottomAccent, .topIcon:
            return true
        // 現代's navigation bar is the system's own glass and its background is
        // hidden on purpose; painting a fill behind it would fight that design.
        case .topFill:
            return interface == .classic
        // Only 經典 floats circle buttons over the page.
        case .circleFill, .circleIcon:
            return interface == .classic
        // Only 現代 has the book card popover behind the cover.
        case .panelFill, .panelText:
            return interface == .modern
        }
    }

    static func slots(for interface: ReaderChromeInterface) -> [ReaderChromeSlot] {
        allCases.filter { $0.appliesTo(interface) }
    }
}

// MARK: - Customizable buttons

/// A button whose icon can be replaced and whose visibility can be switched off.
/// Both families are shared across 經典 and 現代 on purpose: the reader uses one
/// interface at a time, and having to re-import the same artwork per interface
/// would be busywork with no upside.
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

/// The bottom bar's four tools. 經典 draws them in a flat row, 現代 inside its
/// floating panel — same four, same customization.
enum ReaderChromeToolItem: String, CaseIterable, Codable, Hashable, Identifiable, ReaderChromeIconItem {
    case tableOfContents
    case bookmarks
    case nightMode
    case settings

    var id: String { rawValue }
    var storageID: String { "tool.\(rawValue)" }

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

    var defaultSystemImage: String { systemImage(isNight: false) }

    /// 深色 is the one entry whose symbol depends on the current reading theme.
    func systemImage(isNight: Bool) -> String {
        switch self {
        case .tableOfContents: return "list.bullet"
        case .bookmarks: return "bookmark"
        case .nightMode: return isNight ? "sun.min" : "moon"
        case .settings: return "gearshape"
        }
    }

    /// 設置 is the only way into the reader's own settings from either interface —
    /// hiding it would strand the reader with no way back. Same rule
    /// `RootTabItem.settings` follows for the app tab bar.
    var isAlwaysVisible: Bool { self == .settings }
}

/// The book-scoped actions: 經典 floats them as circles over the page, 現代 puts
/// them in the card behind the cover. Backed by `ReaderSecondaryAction.ID`, which
/// is what `ReaderView` actually builds the live list from.
enum ReaderChromeActionItem: String, CaseIterable, Codable, Hashable, Identifiable, ReaderChromeIconItem {
    case refresh
    case changeSource
    case download
    case playback
    case aiAssistant

    var id: String { rawValue }
    var storageID: String { "action.\(rawValue)" }

    var titleKey: String {
        switch self {
        case .refresh: return "刷新"
        case .changeSource: return "換源"
        case .download: return "下載"
        case .playback: return "聽書"
        case .aiAssistant: return "AI 助手"
        }
    }

    var defaultSystemImage: String {
        switch self {
        case .refresh: return "arrow.clockwise"
        case .changeSource: return "arrow.left.and.right"
        case .download: return "arrow.down.circle"
        case .playback: return "headphones"
        case .aiAssistant: return "sparkles"
        }
    }

    init(_ id: ReaderSecondaryAction.ID) {
        switch id {
        case .refresh: self = .refresh
        case .changeSource: self = .changeSource
        case .download: self = .download
        case .playback: self = .playback
        case .aiAssistant: self = .aiAssistant
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
final class ReaderChromeIconStorage {
    static let shared = ReaderChromeIconStorage()

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

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

/// Every colour one reader interface's chrome paints with, resolved once.
/// 外觀 → 閱讀界面 → 自定義 can override any slot the interface exposes; anything
/// left alone follows the reading theme exactly as it did before that section
/// existed.
///
/// One type owns the fallbacks so the settings preview and the reader itself can
/// never disagree about what a picked colour looks like. Do not re-derive a
/// fallback at a call site.
struct ReaderChromePalette {
    let interface: ReaderChromeInterface

    /// Top bar: 返回 / 書籤 / 書籍詳情 in 經典, the navigation controls in 現代
    /// (where only the symbol colour applies — see `ReaderChromeSlot.appliesTo`).
    let topFill: Color
    let topIcon: Color

    /// Bottom bar: the progress row and the tool row behind it.
    let bottomFill: Color
    let bottomIcon: Color
    /// Progress slider, and the 深色 button while night mode is on.
    let bottomAccent: Color

    /// 經典 only: the circles floating on the page (刷新／換源／下載／聽書).
    let circleFill: Color
    let circleIcon: Color
    let circleBorder: Color

    /// 現代 only: the book card hanging off the cover thumbnail.
    let panelFill: Color
    let panelText: Color

    init(interface: ReaderChromeInterface, theme: ReaderTheme, settings: GlobalSettings) {
        self.interface = interface
        func picked(_ slot: ReaderChromeSlot) -> Color? {
            guard slot.appliesTo(interface) else { return nil }
            return settings.readerChromeColor(interface: interface, slot: slot)
                .map { Color(uiColor: AppearanceThemePreset.hex($0)) }
        }

        topFill = picked(.topFill) ?? theme.barColor
        topIcon = picked(.topIcon) ?? theme.textColor
        bottomFill = picked(.bottomFill) ?? theme.barColor
        bottomIcon = picked(.bottomIcon) ?? theme.textColor
        bottomAccent = picked(.bottomAccent) ?? theme.accentColor
        panelFill = picked(.panelFill) ?? theme.barColor
        panelText = picked(.panelText) ?? theme.textColor

        circleFill = picked(.circleFill) ?? theme.barColor
        if let hand = picked(.circleIcon) {
            // A hand-picked symbol colour is used exactly as picked — the 0.9 fade
            // only exists to soften the theme's body-text colour into chrome.
            circleIcon = hand
            circleBorder = hand.opacity(0.35)
        } else {
            circleIcon = theme.textColor.opacity(0.9)
            circleBorder = theme.textColor.opacity(0.35)
        }
    }

    /// The resolved colour behind one slot, so a settings row can open its picker on
    /// what is actually on screen without re-deriving the fallback.
    func color(for slot: ReaderChromeSlot) -> Color {
        switch slot {
        case .topFill: return topFill
        case .topIcon: return topIcon
        case .bottomFill: return bottomFill
        case .bottomIcon: return bottomIcon
        case .bottomAccent: return bottomAccent
        case .circleFill: return circleFill
        case .circleIcon: return circleIcon
        case .panelFill: return panelFill
        case .panelText: return panelText
        }
    }
}

// MARK: - Settings

extension GlobalSettings {
    // MARK: Colours

    private static func chromeColorKey(
        _ interface: ReaderChromeInterface,
        _ slot: ReaderChromeSlot
    ) -> String {
        "\(interface.rawValue).\(slot.rawValue)"
    }

    func readerChromeColor(
        interface: ReaderChromeInterface,
        slot: ReaderChromeSlot
    ) -> UInt32? {
        readerChromeColors[Self.chromeColorKey(interface, slot)]
    }

    /// Pass nil to hand the slot back to the reading theme.
    func setReaderChromeColor(
        _ rgbHex: UInt32?,
        interface: ReaderChromeInterface,
        slot: ReaderChromeSlot
    ) {
        let key = Self.chromeColorKey(interface, slot)
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
        var colors: [String: UInt32] = [:]
        if let stored = UserDefaults.standard.dictionary(forKey: readerChromeColorsKey) as? [String: Int] {
            for (key, value) in stored {
                colors[key] = UInt32(clamping: value)
            }
        }
        // 經典's colours shipped first under one key per slot. Fold them in once so
        // an existing setup does not silently reset. Delete this block (and the
        // legacy keys below) once no install can still be carrying them.
        for (legacyKey, slot) in legacyClassicChromeKeys where colors[chromeColorKey(.classic, slot)] == nil {
            guard let stored = UserDefaults.standard.object(forKey: legacyKey) as? Int else { continue }
            colors[chromeColorKey(.classic, slot)] = UInt32(clamping: stored)
        }
        return colors
    }

    private static let legacyClassicChromeKeys: [(String, ReaderChromeSlot)] = [
        ("yd_reader_classic_top_fill_hex", .topFill),
        ("yd_reader_classic_top_icon_hex", .topIcon),
        ("yd_reader_classic_bottom_fill_hex", .bottomFill),
        ("yd_reader_classic_bottom_icon_hex", .bottomIcon),
        ("yd_reader_classic_bottom_accent_hex", .bottomAccent),
        ("yd_reader_classic_circle_fill_hex", .circleFill),
        ("yd_reader_classic_circle_icon_hex", .circleIcon),
    ]

    static func saveReaderChromeColors(_ colors: [String: UInt32]) {
        if colors.isEmpty {
            UserDefaults.standard.removeObject(forKey: readerChromeColorsKey)
        } else {
            UserDefaults.standard.set(colors.mapValues { Int($0) }, forKey: readerChromeColorsKey)
        }
        // The migrated originals must go, or clearing a slot would resurrect the old
        // value on next launch.
        for (legacyKey, _) in legacyClassicChromeKeys {
            UserDefaults.standard.removeObject(forKey: legacyKey)
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
        actions.filter { isReaderChromeItemVisible(ReaderChromeActionItem($0.id)) }
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
        if let old = readerChromeIcons.first(where: { $0.itemID == asset.itemID }) {
            ReaderChromeIconStorage.shared.delete(old)
        }
        var assets = readerChromeIcons
        assets.removeAll { $0.itemID == asset.itemID }
        assets.append(asset)
        assets.sort { $0.itemID < $1.itemID }
        readerChromeIcons = assets
        return asset
    }

    func deleteReaderChromeIcon(for item: some ReaderChromeIconItem) {
        guard let asset = readerChromeIcon(for: item) else { return }
        ReaderChromeIconStorage.shared.delete(asset)
        readerChromeIcons.removeAll { $0.id == asset.id }
    }

    // MARK: Reset

    /// Anything at all changed from the stock look of this interface. Icons and
    /// visibility are shared, so they count for both.
    func hasReaderChromeOverride(interface: ReaderChromeInterface) -> Bool {
        ReaderChromeSlot.slots(for: interface)
            .contains { readerChromeColor(interface: interface, slot: $0) != nil }
            || !readerChromeIcons.isEmpty
            || !readerChromeHiddenIDs.isEmpty
    }

    /// Back to the stock look: this interface's colours follow the reading theme
    /// again, every button is visible, and imported icon files are deleted (not
    /// just forgotten). Icons and visibility are shared, so both interfaces return
    /// to stock together — the colours of the other one are left alone.
    func resetReaderChrome(interface: ReaderChromeInterface) {
        var colors = readerChromeColors
        for slot in ReaderChromeSlot.allCases {
            colors.removeValue(forKey: Self.chromeColorKey(interface, slot))
        }
        readerChromeColors = colors
        for asset in readerChromeIcons {
            ReaderChromeIconStorage.shared.delete(asset)
        }
        readerChromeIcons = []
        readerChromeHiddenIDs = []
    }
}
