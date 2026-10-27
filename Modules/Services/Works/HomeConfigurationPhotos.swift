import Combine
import CryptoKit
import ImageIO
import UIKit

/// The photo the reader picks for a 首頁配置 (maintainer, 2026-10-22, after Rex's 管理配置): one
/// square JPEG per configuration. 預設 can have one too.
typealias HomeConfigurationPhotos = HomePhotoFolder<HomeConfigurationID>

/// The photo the reader picks for a 大圖卡片 card (maintainer, 2026-10-27: 「分類卡的圖片可以自定義」),
/// in place of the face designed from its name (`HomeCategoryArt`): one per card, the card's shape.
typealias HomeListCardPhotos = HomePhotoFolder<HomeListCardPhotoID>

/// Photos the reader picks for the home: one JPEG per id, `<id>.jpg` in a folder beside
/// `explore_home.json`, cut to one shape. Like that file they stay on this device: neither
/// iCloud nor WebDAV carries the home. Read when a page first asks, then kept.
@MainActor
final class HomePhotoFolder<ID: RawRepresentable & Hashable & Sendable>: ObservableObject where ID.RawValue == String {
    enum PhotoError: Error {
        /// ImageIO could not read the picked bytes as an image.
        case unreadable
    }

    @Published private(set) var images: [ID: UIImage] = [:]

    /// A photo's size in pixels: the picked image's middle cut to this shape, made no larger.
    let pixelSize: CGSize
    private let directory: URL
    private var isLoaded = false

    init(directory: URL, pixelSize: CGSize) {
        self.directory = directory
        self.pixelSize = pixelSize
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
            AppLogger.cache("⟐ home photos could not be listed", error: error, context: ["folder": directory.path])
            return
        }
        var images: [ID: UIImage] = [:]
        for file in files where file.pathExtension == "jpg" {
            guard let id = ID(rawValue: file.deletingPathExtension().lastPathComponent) else { continue }
            if let image = UIImage(contentsOfFile: file.path) {
                images[id] = image
            } else {
                AppLogger.cache("⟐ home photo could not be read", context: ["file": file.lastPathComponent])
            }
        }
        self.images = images
    }

    /// The picked image, cut to the folder's shape and made small off the main thread, saved
    /// as `id`'s photo in place of any before it.
    func setPhoto(_ data: Data, for id: ID) async throws {
        let url = fileURL(for: id)
        let directory = directory
        let pixelSize = pixelSize
        let image = try await Task.detached(priority: .userInitiated) {
            guard let jpeg = Self.croppedJPEG(from: data, size: pixelSize), let image = UIImage(data: jpeg) else {
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
    func removePhoto(for id: ID) {
        images[id] = nil
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch CocoaError.fileNoSuchFile {
            // It had none.
        } catch {
            AppLogger.cache("⟐ home photo could not be removed", error: error, context: ["photo": id.rawValue])
        }
    }

    /// `old`'s photo kept as `new`'s, when what it belongs to is named anew (a card's 地區).
    func movePhoto(from old: ID, to new: ID) {
        guard old != new else { return }
        loadIfNeeded()
        guard let image = images[old] else { return }
        do {
            do {
                try FileManager.default.removeItem(at: fileURL(for: new))
            } catch CocoaError.fileNoSuchFile {
                // Nothing there to replace.
            }
            try FileManager.default.moveItem(at: fileURL(for: old), to: fileURL(for: new))
        } catch {
            AppLogger.cache("⟐ home photo could not be moved", error: error, context: ["from": old.rawValue, "to": new.rawValue])
            return
        }
        images[old] = nil
        images[new] = image
    }

    /// Every saved photo whose id is not in `ids` gone from the disk, read or not: what was left
    /// by what it belonged to going.
    func removePhotos(keeping ids: Set<ID>) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            AppLogger.cache("⟐ home photos could not be listed", error: error, context: ["folder": directory.path])
            return
        }
        for file in files where file.pathExtension == "jpg" {
            guard let id = ID(rawValue: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            removePhoto(for: id)
        }
    }

    private func fileURL(for id: ID) -> URL {
        // 預設's `default`, a 空白 kept from before 2026-10-23, a UUID, or a card's
        // `HomeListCardPhotoID`: nothing a file name cannot hold.
        directory.appendingPathComponent(id.rawValue).appendingPathExtension("jpg")
    }

    /// The image's middle cut to `size`'s shape, `size` at most and never larger than the
    /// image, upright, as JPEG. Nil when ImageIO cannot read `data`.
    nonisolated static func croppedJPEG(from data: Data, size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // The scale at which the image covers `size`, never above 1.
        let scale = min(1, max(size.width / CGFloat(width), size.height / CGFloat(height)))
        let longEdge = Int((CGFloat(max(width, height)) * scale).rounded(.up))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ] as [CFString: Any] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // The largest box of `size`'s shape inside the thumbnail, at most `size`, in its middle.
        let aspect = size.width / size.height
        let fitWidth = min(CGFloat(thumbnail.width), CGFloat(thumbnail.height) * aspect, size.width)
        let crop = CGRect(x: ((CGFloat(thumbnail.width) - fitWidth) / 2).rounded(.down),
                          y: ((CGFloat(thumbnail.height) - fitWidth / aspect) / 2).rounded(.down),
                          width: fitWidth.rounded(), height: (fitWidth / aspect).rounded())
        guard let cropped = thumbnail.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
    }
}

/// A 大圖卡片 card's photo: the section it is in and the list it shows (its binding and
/// parameters, not its place), so it stays with the card when the cards are reordered. A card
/// that gives several lists (精選書單, the 書架's groups) gives each of them its photo.
struct HomeListCardPhotoID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    /// The photo of `section`'s card `card`.
    init?(section: HomeSection, card: HomeListCard) {
        self.init(section: section.id, binding: card.binding, parameters: card.parameters)
    }

    /// Every card's photo on the home, in every 首頁配置: each card a section keeps, those this
    /// build cannot draw too, in whatever layout it is in now, so a section turned to a layout
    /// of books has its photos when it is turned back.
    static func all(in home: HomeConfigurations) -> Set<Self> {
        let sections = home.sections + home.configurations.flatMap(\.sections)
        return Set(sections.flatMap { section -> [Self] in
            var asLists = section
            asLists.layout = .bannerCards
            let cards = if case .lists(let stored) = section.binding { stored } else { asLists.listCards }
            return cards.compactMap { Self(section: section, card: $0) }
        })
    }

    /// Nil, logged, when the list cannot be encoded; the card then keeps its designed face.
    init?(section: UUID, binding: HomeSectionBinding, parameters: [String: String]) {
        // Sorted keys: the same list encodes the same every time.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data
        do {
            data = try encoder.encode(HomeListCard(binding: binding, parameters: parameters))
        } catch {
            AppLogger.cache("⟐ 大圖卡片 photo id could not be made", error: error, context: ["section": section.uuidString])
            return nil
        }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        rawValue = "\(section.uuidString)-\(digest)"
    }
}
