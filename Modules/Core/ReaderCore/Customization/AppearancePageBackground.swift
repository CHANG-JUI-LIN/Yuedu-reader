import Foundation
import SwiftUI
import UIKit

// MARK: - Scope

/// Which app page a page-background config applies to. `global` is the default
/// every tab falls back to; the tab cases mirror `RootTabItem` raw values so a
/// tab and its scope stay in sync by construction.
enum AppearancePageBackgroundScope: String, CaseIterable, Codable, Identifiable {
    case global
    case bookshelf
    case explore
    case rss
    case settings
    case search

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .global: return "全局默認"
        case .bookshelf: return "書架"
        case .explore: return "探索"
        case .rss: return "RSS 訂閱"
        case .settings: return "設定"
        case .search: return "搜索書籍"
        }
    }

    var localizedTitle: String { localized(titleKey) }
}

// MARK: - Config

/// Per-scope page background: a light and a dark gradient (primary → secondary)
/// plus an optional background image per appearance. Every field is optional so
/// old persisted JSON keeps decoding as the struct grows.
struct AppearancePageBackgroundConfig: Codable, Hashable {
    var lightPrimaryHex: UInt32?
    var lightSecondaryHex: UInt32?
    var darkPrimaryHex: UInt32?
    var darkSecondaryHex: UInt32?
    var lightImageFileName: String?
    var darkImageFileName: String?
    var lightImageOpacity: Double?
    var darkImageOpacity: Double?

    var isEmpty: Bool {
        lightPrimaryHex == nil && lightSecondaryHex == nil
            && darkPrimaryHex == nil && darkSecondaryHex == nil
            && normalizedImageFileName(lightImageFileName) == nil
            && normalizedImageFileName(darkImageFileName) == nil
    }

    /// Whether this config paints anything for the given appearance.
    func hasContent(for colorScheme: ColorScheme) -> Bool {
        slice(for: colorScheme) != nil
    }

    func imageFileName(for colorScheme: ColorScheme) -> String? {
        normalizedImageFileName(colorScheme == .dark ? darkImageFileName : lightImageFileName)
    }

    func imageOpacity(for colorScheme: ColorScheme) -> Double {
        let raw = colorScheme == .dark ? darkImageOpacity : lightImageOpacity
        return raw ?? 1.0
    }

    mutating func setImageOpacity(_ opacity: Double?, for colorScheme: ColorScheme) {
        if colorScheme == .dark {
            darkImageOpacity = opacity
        } else {
            lightImageOpacity = opacity
        }
    }

    mutating func setImageFileName(_ fileName: String?, for colorScheme: ColorScheme) {
        if colorScheme == .dark {
            darkImageFileName = fileName
        } else {
            lightImageFileName = fileName
        }
    }

    func primaryHex(for colorScheme: ColorScheme) -> UInt32? {
        colorScheme == .dark ? darkPrimaryHex : lightPrimaryHex
    }

    func secondaryHex(for colorScheme: ColorScheme) -> UInt32? {
        colorScheme == .dark ? darkSecondaryHex : lightSecondaryHex
    }

    mutating func setPrimaryHex(_ hex: UInt32?, for colorScheme: ColorScheme) {
        if colorScheme == .dark { darkPrimaryHex = hex } else { lightPrimaryHex = hex }
    }

    mutating func setSecondaryHex(_ hex: UInt32?, for colorScheme: ColorScheme) {
        if colorScheme == .dark { darkSecondaryHex = hex } else { lightSecondaryHex = hex }
    }

    /// All image files this config references.
    var imageFileNames: [String] {
        [lightImageFileName, darkImageFileName].compactMap(normalizedImageFileName)
    }

    /// The renderable layer for one appearance, or nil when nothing is set for
    /// that appearance (callers then fall back to the global scope / system look).
    func slice(for colorScheme: ColorScheme) -> AppearancePageBackgroundSlice? {
        let slice = AppearancePageBackgroundSlice(
            primaryHex: primaryHex(for: colorScheme),
            secondaryHex: secondaryHex(for: colorScheme),
            imageFileName: imageFileName(for: colorScheme),
            imageOpacity: imageOpacity(for: colorScheme)
        )
        return slice.isEmpty ? nil : slice
    }

    private func normalizedImageFileName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - Resolved slice

/// What actually gets drawn behind a page for one appearance: a gradient made
/// of the configured colors, with an optional image painted over it.
struct AppearancePageBackgroundSlice: Hashable {
    var primaryHex: UInt32?
    var secondaryHex: UInt32?
    var imageFileName: String?
    var imageOpacity: Double

    init(
        primaryHex: UInt32? = nil,
        secondaryHex: UInt32? = nil,
        imageFileName: String? = nil,
        imageOpacity: Double = 1.0
    ) {
        self.primaryHex = primaryHex
        self.secondaryHex = secondaryHex
        self.imageFileName = imageFileName
        self.imageOpacity = imageOpacity
    }

    var isEmpty: Bool {
        primaryHex == nil && secondaryHex == nil && imageFileName == nil
    }

    /// Gradient stops. A single configured color renders as a solid fill.
    var gradientColors: [Color]? {
        let hexes = [primaryHex, secondaryHex].compactMap { $0 }
        guard !hexes.isEmpty else { return nil }
        let colors = hexes.map { Color(uiColor: AppearanceThemePreset.hex($0)) }
        return colors.count == 1 ? [colors[0], colors[0]] : colors
    }

    var imageURL: URL? {
        guard let imageFileName else { return nil }
        return try? AppearancePageBackgroundImageStore.shared.fileURL(fileName: imageFileName)
    }
}

// MARK: - Image storage

enum AppearancePageBackgroundImageError: Error {
    case unsupportedImageFile
    case cannotReadImage

    var messageKey: String {
        switch self {
        case .unsupportedImageFile:
            return "只支援 WebP、JPG、JPEG 或 PNG 圖片。"
        case .cannotReadImage:
            return "無法讀取圖片。"
        }
    }
}

/// Copies imported page-background images into Application Support/PageBackgrounds
/// and hands back stable file names persisted in `GlobalSettings`. Large photos
/// are downsampled on import so full-screen wallpapers never carry a 4K decode
/// cost while scrolling.
final class AppearancePageBackgroundImageStore {
    static let shared = AppearancePageBackgroundImageStore()

    /// Longest-side cap for imported images; covers iPad fullscreen at 2×.
    private static let maxPixelSize: CGFloat = 2200

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["webp", "jpg", "jpeg", "png"]
    private let imageCache = NSCache<NSString, UIImage>()

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        imageCache.countLimit = 12
    }

    /// Import from a file URL (Files app / export payloads).
    func importImage(fileURL: URL) throws -> String {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw AppearancePageBackgroundImageError.unsupportedImageFile
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw AppearancePageBackgroundImageError.cannotReadImage
        }
        return try store(data: data, fallbackExtension: sourceExtension)
    }

    /// Import from raw data (Photos picker), sniffing the container format.
    func importImage(data: Data) throws -> String {
        try store(data: data, fallbackExtension: "jpg")
    }

    func fileURL(fileName: String) throws -> URL {
        try imagesDirectoryURL().appendingPathComponent(fileName)
    }

    func image(fileName: String) -> UIImage? {
        if let cached = imageCache.object(forKey: fileName as NSString) {
            return cached
        }
        guard let url = try? fileURL(fileName: fileName),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        imageCache.setObject(image, forKey: fileName as NSString)
        return image
    }

    func delete(fileName: String) {
        imageCache.removeObject(forKey: fileName as NSString)
        guard let url = try? fileURL(fileName: fileName) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Copies an existing stored image under a new name, so a saved theme owns
    /// its snapshot independently of the live settings (either side can be
    /// deleted without dangling the other).
    func duplicate(fileName: String) -> String? {
        guard let source = try? fileURL(fileName: fileName),
              fileManager.fileExists(atPath: source.path) else {
            return nil
        }
        let copyName = "pagebg-\(UUID().uuidString).\((fileName as NSString).pathExtension)"
        guard let destination = try? fileURL(fileName: copyName) else { return nil }
        do {
            try fileManager.copyItem(at: source, to: destination)
            return copyName
        } catch {
            return nil
        }
    }

    func fileData(fileName: String) -> Data? {
        guard let url = try? fileURL(fileName: fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: Internals

    /// Validates, downsamples oversized images, and writes to disk. PNG data
    /// stays PNG (keeps transparency); everything else is stored as JPEG.
    private func store(data: Data, fallbackExtension: String) throws -> String {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw AppearancePageBackgroundImageError.cannotReadImage
        }

        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let needsDownsample = max(pixelWidth, pixelHeight) > Self.maxPixelSize

        let outputData: Data
        let outputExtension: String
        if !needsDownsample, isPNG || isJPEG || allowedExtensions.contains(fallbackExtension.lowercased()) {
            // Already reasonable and in a supported container: keep bytes as-is.
            outputData = data
            outputExtension = isPNG ? "png" : (isJPEG ? "jpg" : fallbackExtension.lowercased())
        } else {
            let resized = needsDownsample ? downsample(image, maxPixelSize: Self.maxPixelSize) : image
            if isPNG, let png = resized.pngData() {
                outputData = png
                outputExtension = "png"
            } else if let jpeg = resized.jpegData(compressionQuality: 0.9) {
                outputData = jpeg
                outputExtension = "jpg"
            } else {
                throw AppearancePageBackgroundImageError.cannotReadImage
            }
        }

        let directory = try imagesDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "pagebg-\(UUID().uuidString).\(outputExtension)"
        try outputData.write(to: directory.appendingPathComponent(fileName))
        return fileName
    }

    private func downsample(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let ratio = maxPixelSize / max(pixelWidth, pixelHeight)
        guard ratio < 1 else { return image }
        let targetSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func imagesDirectoryURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PageBackgrounds", isDirectory: true)
    }
}

// MARK: - Theme export file

/// Single-file JSON theme package: the theme's five surface colors plus every
/// scope's page background with images embedded as base64, so a theme survives
/// AirDrop / iCloud Drive to another device intact.
struct AppearanceThemeExportFile: Codable {
    struct ImagePayload: Codable {
        var fileExtension: String
        var base64: String
    }

    struct PageBackgroundPayload: Codable {
        var lightPrimaryHex: UInt32?
        var lightSecondaryHex: UInt32?
        var darkPrimaryHex: UInt32?
        var darkSecondaryHex: UInt32?
        var lightImage: ImagePayload?
        var darkImage: ImagePayload?
        var lightImageOpacity: Double?
        var darkImageOpacity: Double?
    }

    static let formatIdentifier = "yuedu-appearance-theme"

    var format: String
    var version: Int
    var name: String
    var backgroundHex: UInt32
    var textHex: UInt32
    var barHex: UInt32
    var accentHex: UInt32
    var dialogueHex: UInt32
    var pageBackgrounds: [String: PageBackgroundPayload]?
}

enum AppearanceThemeImportError: Error {
    case invalidFile

    var messageKey: String {
        switch self {
        case .invalidFile:
            return "不支援的主題檔案。"
        }
    }
}

// MARK: - Background layer view

/// The layer painted behind a page: configured gradient with the optional
/// background image on top. Renders nothing when the slice is empty.
struct AppearancePageBackgroundLayerView: View {
    let slice: AppearancePageBackgroundSlice

    var body: some View {
        ZStack {
            if let colors = slice.gradientColors {
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            if let fileName = slice.imageFileName,
               let image = AppearancePageBackgroundImageStore.shared.image(fileName: fileName) {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(slice.imageOpacity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Gradient slice") {
    AppearancePageBackgroundLayerView(
        slice: AppearancePageBackgroundSlice(
            primaryHex: 0xEAF2FC,
            secondaryHex: 0xD5E8D8,
            imageFileName: nil
        )
    )
    .ignoresSafeArea()
}
