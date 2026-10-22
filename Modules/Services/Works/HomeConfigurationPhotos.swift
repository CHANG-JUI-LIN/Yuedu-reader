import Combine
import ImageIO
import UIKit

/// The photo the reader picks for a 首頁配置 (maintainer, 2026-10-22, after Rex's 管理配置): one
/// square JPEG per configuration, `<id>.jpg` in a folder beside `explore_home.json`. Like that
/// file it stays on this device: neither iCloud nor WebDAV carries the home. 預設 and 空白 can
/// have one too. Read when 首頁配置's page first asks, then kept.
@MainActor
final class HomeConfigurationPhotos: ObservableObject {
    enum PhotoError: Error {
        /// ImageIO could not read the picked bytes as an image.
        case unreadable
    }

    /// The square's side in pixels: 首頁配置's form draws it at 96pt, three pixels a point.
    nonisolated static let side = 288

    @Published private(set) var images: [HomeConfigurationID: UIImage] = [:]

    private let directory: URL
    private var isLoaded = false

    init(directory: URL) {
        self.directory = directory
    }

    /// Every saved photo, read once.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            AppLogger.cache("⟐ 首頁配置 photos could not be listed", error: error, context: ["folder": directory.path])
            return
        }
        var images: [HomeConfigurationID: UIImage] = [:]
        for file in files where file.pathExtension == "jpg" {
            let id = HomeConfigurationID(rawValue: file.deletingPathExtension().lastPathComponent)
            if let image = UIImage(contentsOfFile: file.path) {
                images[id] = image
            } else {
                AppLogger.cache("⟐ 首頁配置 photo could not be read", context: ["file": file.lastPathComponent])
            }
        }
        self.images = images
    }

    /// The picked image, cut to its middle square and made small off the main thread, saved
    /// as `id`'s photo in place of any before it.
    func setPhoto(_ data: Data, for id: HomeConfigurationID) async throws {
        let url = fileURL(for: id)
        let directory = directory
        let image = try await Task.detached(priority: .userInitiated) {
            guard let jpeg = Self.squareJPEG(from: data, side: Self.side), let image = UIImage(data: jpeg) else {
                throw PhotoError.unreadable
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: url, options: .atomic)
            return image
        }.value
        loadIfNeeded()
        images[id] = image
    }

    /// `id`'s photo gone, from the page and the disk.
    func removePhoto(for id: HomeConfigurationID) {
        images[id] = nil
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch CocoaError.fileNoSuchFile {
            // It had none.
        } catch {
            AppLogger.cache("⟐ 首頁配置 photo could not be removed", error: error, context: ["configuration": id.rawValue])
        }
    }

    private func fileURL(for id: HomeConfigurationID) -> URL {
        // 預設, 空白 or a UUID: nothing a file name cannot hold.
        directory.appendingPathComponent(id.rawValue).appendingPathExtension("jpg")
    }

    /// The image's middle square, `side` pixels across, upright, as JPEG. Nil when ImageIO
    /// cannot read `data`.
    nonisolated static func squareJPEG(from data: Data, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // The long edge at which the short one is `side`, never larger than the image.
        let longEdge = min(max(width, height), side * max(width, height) / min(width, height))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ] as [CFString: Any] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let square = min(thumbnail.width, thumbnail.height)
        let crop = CGRect(x: (thumbnail.width - square) / 2, y: (thumbnail.height - square) / 2,
                          width: square, height: square)
        guard let cropped = thumbnail.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
    }
}
