import SwiftUI
import UIKit

/// Which appearance a default cover belongs to.
enum DefaultCoverScheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return localized("亮色封面")
        case .dark: return localized("深色封面")
        }
    }
}

enum DefaultCoverStorageError: LocalizedError {
    case unsupportedImageFile
    case cannotReadImage

    var messageKey: String {
        switch self {
        case .unsupportedImageFile: return "僅支援圖片檔案"
        case .cannotReadImage: return "無法讀取圖片。"
        }
    }

    var errorDescription: String? { localized(messageKey) }
}

/// Files behind 預設封面. Several images per appearance, unlike the launch image's
/// single slot, because the shelf picks one at random per book.
final class DefaultCoverStorageManager {
    static let shared = DefaultCoverStorageManager()

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["webp", "jpg", "jpeg", "png"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importImage(fileURL: URL, scheme: DefaultCoverScheme) throws -> String {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(sourceExtension) else {
            throw DefaultCoverStorageError.unsupportedImageFile
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw DefaultCoverStorageError.cannotReadImage
        }
        return try store(data: data, fallbackExtension: sourceExtension, scheme: scheme)
    }

    /// Photos picks arrive as raw data with no file name and are often HEIC, so
    /// the container is sniffed and re-encoded by `ImportedImageNormalizer`.
    func importImage(data: Data, scheme: DefaultCoverScheme) throws -> String {
        try store(data: data, fallbackExtension: "", scheme: scheme)
    }

    private func store(
        data: Data,
        fallbackExtension: String,
        scheme: DefaultCoverScheme
    ) throws -> String {
        guard let image = UIImage(data: data),
              image.size.width > 0,
              image.size.height > 0 else {
            throw DefaultCoverStorageError.cannotReadImage
        }
        guard let output = ImportedImageNormalizer.normalize(
            image: image,
            data: data,
            fallbackExtension: fallbackExtension,
            allowedExtensions: allowedExtensions
        ) else {
            throw DefaultCoverStorageError.cannotReadImage
        }

        let directory = try imagesDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "cover-\(scheme.rawValue)-\(UUID().uuidString).\(output.fileExtension)"
        try output.data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    func fileURL(fileName: String) throws -> URL {
        try imagesDirectoryURL().appendingPathComponent(fileName)
    }

    func delete(fileName: String) {
        guard let url = try? fileURL(fileName: fileName) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func imagesDirectoryURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("DefaultCovers", isDirectory: true)
    }
}

/// Resolves which default cover a coverless book gets.
///
/// Two things matter here and both are about the shelf redrawing constantly:
///
/// - The pick is a hash of the book's own key (`StableSeedHash`), not
///   `randomElement()`. A fresh random pick per body evaluation would reshuffle
///   every cover on each scroll.
/// - Decoded bitmaps are cached and downsampled through `BookCoverLoader`. A
///   full-size photo decoded per cell is the same main-thread stall documented
///   there for downloaded covers.
enum DefaultCoverLibrary {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 24
        return c
    }()

    /// File names for `scheme`, falling back to the light set when the dark set
    /// is empty — the same "set one, get both" rule the launch image uses.
    static func fileNames(for scheme: DefaultCoverScheme) -> [String] {
        let settings = GlobalSettings.shared
        let primary = settings.defaultCoverFileNames(for: scheme)
        if !primary.isEmpty { return primary }
        return scheme == .dark ? settings.defaultCoverFileNames(for: .light) : []
    }

    static func hasImages(for colorScheme: ColorScheme) -> Bool {
        !fileNames(for: colorScheme == .dark ? .dark : .light).isEmpty
    }

    /// The default cover for `seed` (a book id / title — anything stable for that
    /// book), or nil when the user has not added any — in which case the caller
    /// falls back to `GeneratedBookCover`, which is always available.
    static func image(seed: String, colorScheme: ColorScheme) -> UIImage? {
        let names = fileNames(for: colorScheme == .dark ? .dark : .light)
        guard let fileName = stableFileName(seed: seed, in: names) else { return nil }
        return image(fileName: fileName)
    }

    /// Which file `seed` maps to. Split out from `image(seed:colorScheme:)` so the
    /// mapping can be tested without any files on disk.
    static func stableFileName(seed: String, in fileNames: [String]) -> String? {
        guard !fileNames.isEmpty else { return nil }
        return fileNames[StableSeedHash.index(for: seed, count: fileNames.count)]
    }

    static func image(fileName: String) -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) { return cached }
        guard let url = try? DefaultCoverStorageManager.shared.fileURL(fileName: fileName),
              let data = try? Data(contentsOf: url),
              let image = BookCoverLoader.decodedCover(from: data) else { return nil }
        cache.setObject(image, forKey: fileName as NSString)
        return image
    }

    /// Drops decoded bitmaps after the library changes, so a removed or replaced
    /// image cannot keep drawing from memory.
    static func invalidateCache() {
        cache.removeAllObjects()
    }
}
