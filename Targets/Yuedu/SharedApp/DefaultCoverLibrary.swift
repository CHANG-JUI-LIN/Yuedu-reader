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
final class DefaultCoverStorageManager: Sendable {
    static let shared = DefaultCoverStorageManager()

    private var fileManager: FileManager { .default }
    private let allowedExtensions: Set<String> = ["webp", "jpg", "jpeg", "png"]

    private init() {}

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

    /// Where a library image lives, from its name alone: no directory creation, no
    /// `stat`. The shelf resolves one of these per card that falls back to 預設封面,
    /// so it must stay free of file-system calls; `fileURL` above is for the import
    /// and delete paths, which want the directory to exist.
    static func imageLocation(fileName: String) -> URL {
        StorageLocations.applicationSupportRoot
            .appendingPathComponent(imagesDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static let imagesDirectoryName = "DefaultCovers"

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
        return base.appendingPathComponent(Self.imagesDirectoryName, isDirectory: true)
    }
}

/// Resolves which default cover a coverless book gets.
///
/// Two things matter here and both are about the shelf redrawing constantly:
///
/// - The pick is a hash of the book's own key (`StableSeedHash`), not
///   `randomElement()`. A fresh random pick per body evaluation would reshuffle
///   every cover on each scroll.
/// - Decoding goes through `CoverImagePipeline`: downsampled, decoded off the main
///   thread for the shelf, and inside the same memory budget as every other cover.
///   A full-size photo decoded per cell is the same main-thread stall documented in
///   `BookCoverLoader` for downloaded covers.
enum DefaultCoverLibrary {
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

    /// The library file `seed` (a book id / title — anything stable for that book)
    /// maps to, or nil when the user has not added any. Pure: settings and a hash,
    /// no file access. The shelf decides its fallback with this and only loads the
    /// image if it actually gets that far.
    static func fileName(seed: String, colorScheme: ColorScheme) -> String? {
        stableFileName(seed: seed, in: fileNames(for: colorScheme == .dark ? .dark : .light))
    }

    /// The default cover for `seed`, **blocking**, or nil when the library is empty —
    /// in which case the caller falls back to `GeneratedBookCover`, which is always
    /// available. Not for the shelf, which loads through `BookshelfCoverArtwork`.
    static func image(seed: String, colorScheme: ColorScheme) -> UIImage? {
        guard let fileName = fileName(seed: seed, colorScheme: colorScheme) else { return nil }
        return image(fileName: fileName)
    }

    /// Which file `seed` maps to. Split out from `image(seed:colorScheme:)` so the
    /// mapping can be tested without any files on disk.
    static func stableFileName(seed: String, in fileNames: [String]) -> String? {
        guard !fileNames.isEmpty else { return nil }
        return fileNames[StableSeedHash.index(for: seed, count: fileNames.count)]
    }

    /// One library image, **blocking**, at the size these have always been decoded
    /// to. For the 預設封面 settings grid, which shows a handful of them once.
    static func image(fileName: String) -> UIImage? {
        CoverImagePipeline.shared.loadImmediately(request(fileName: fileName)).image
    }

    /// Memory only: the default cover for `seed` if it is already decoded at `size`.
    /// Nil also while it is still loading, so callers must load it themselves.
    static func cachedImage(
        seed: String,
        colorScheme: ColorScheme,
        size: CoverPixelSize = .standard
    ) -> UIImage? {
        guard let fileName = fileName(seed: seed, colorScheme: colorScheme) else { return nil }
        return CoverImagePipeline.shared.cachedImage(for: request(fileName: fileName, size: size))
    }

    static func request(fileName: String, size: CoverPixelSize = .standard) -> CoverImageRequest {
        CoverImageRequest(source: .defaultCover(fileName: fileName), size: size)
    }

    /// Drops decoded bitmaps after the library changes, so a removed image cannot
    /// keep drawing from memory and views showing one pick again.
    static func invalidateCache() {
        CoverImagePipeline.shared.invalidateDefaultCovers()
    }
}
