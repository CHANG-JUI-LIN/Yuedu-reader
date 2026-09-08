import UIKit

/// One appearance's card artwork. A card background is authored per appearance
/// because a picture that reads on paper-white almost never reads on near-black.
struct AppearanceCardBackgroundLayer: Codable, Hashable, Sendable {
    /// How the artwork fills a card that is not the image's own size.
    enum Mode: String, Codable, Sendable {
        /// Stretch the whole picture. Right for a card-shaped painting.
        case stretch
        /// Keep the corners fixed and stretch only the middle bands, the way a
        /// bordered or ornamented frame has to be resized.
        case nineSlice
    }

    var imageFileName: String?
    var mode: Mode
    /// Cap insets for `nineSlice`, as a **fraction of the image's own size** rather
    /// than pixels: the store downsamples large artwork, so a pixel inset recorded
    /// at import would point at the wrong band once the file shrank.
    var sliceTop: Double
    var sliceLeft: Double
    var sliceBottom: Double
    var sliceRight: Double
    var imageOpacity: Double
    /// Painted under the artwork, and used alone when there is no artwork.
    var fillHex: UInt32?
    var borderHex: UInt32?
    var borderWidth: Double
    var borderOpacity: Double

    init(
        imageFileName: String? = nil,
        mode: Mode = .stretch,
        sliceTop: Double = 0,
        sliceLeft: Double = 0,
        sliceBottom: Double = 0,
        sliceRight: Double = 0,
        imageOpacity: Double = 1,
        fillHex: UInt32? = nil,
        borderHex: UInt32? = nil,
        borderWidth: Double = 0,
        borderOpacity: Double = 1
    ) {
        self.imageFileName = imageFileName
        self.mode = mode
        // Opposite caps must leave a stretchable band between them, or the middle
        // slice has zero or negative width and the image renders undefined.
        let (top, bottom) = Self.balanced(sliceTop, sliceBottom)
        let (leading, trailing) = Self.balanced(sliceLeft, sliceRight)
        self.sliceTop = top
        self.sliceBottom = bottom
        self.sliceLeft = leading
        self.sliceRight = trailing
        self.imageOpacity = min(max(imageOpacity, 0), 1)
        self.fillHex = fillHex.map { $0 & 0xFFFFFF }
        self.borderHex = borderHex.map { $0 & 0xFFFFFF }
        self.borderWidth = min(max(borderWidth, 0), 12)
        self.borderOpacity = min(max(borderOpacity, 0), 1)
    }

    /// Clamps a pair of opposing cap fractions into `0..<1` combined.
    private static func balanced(_ a: Double, _ b: Double) -> (Double, Double) {
        let first = min(max(a.isFinite ? a : 0, 0), 0.49)
        let second = min(max(b.isFinite ? b : 0, 0), 0.49)
        return (first, second)
    }

    /// Nothing to draw — the caller keeps the plain themed surface.
    var isEmpty: Bool {
        imageFileName == nil && fillHex == nil && (borderHex == nil || borderWidth <= 0)
    }

    private enum CodingKeys: String, CodingKey {
        case imageFileName, mode, sliceTop, sliceLeft, sliceBottom, sliceRight
        case imageOpacity, fillHex, borderHex, borderWidth, borderOpacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            imageFileName: try c.decodeIfPresent(String.self, forKey: .imageFileName),
            mode: try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .stretch,
            sliceTop: try c.decodeIfPresent(Double.self, forKey: .sliceTop) ?? 0,
            sliceLeft: try c.decodeIfPresent(Double.self, forKey: .sliceLeft) ?? 0,
            sliceBottom: try c.decodeIfPresent(Double.self, forKey: .sliceBottom) ?? 0,
            sliceRight: try c.decodeIfPresent(Double.self, forKey: .sliceRight) ?? 0,
            imageOpacity: try c.decodeIfPresent(Double.self, forKey: .imageOpacity) ?? 1,
            fillHex: try c.decodeIfPresent(UInt32.self, forKey: .fillHex),
            borderHex: try c.decodeIfPresent(UInt32.self, forKey: .borderHex),
            borderWidth: try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0,
            borderOpacity: try c.decodeIfPresent(Double.self, forKey: .borderOpacity) ?? 1
        )
    }
}

/// The card background for both appearances.
///
/// Deliberately carries no corner radius: every call site already passes the shape
/// it wants (a list row is square and the list rounds it, a `DSCard` is a rounded
/// rectangle), so a radius here would fight the caller rather than describe it.
struct AppearanceCardBackground: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var light: AppearanceCardBackgroundLayer
    var dark: AppearanceCardBackgroundLayer

    init(
        isEnabled: Bool = true,
        light: AppearanceCardBackgroundLayer = .init(),
        dark: AppearanceCardBackgroundLayer = .init()
    ) {
        self.isEnabled = isEnabled
        self.light = light
        self.dark = dark
    }

    func layer(for style: UIUserInterfaceStyle) -> AppearanceCardBackgroundLayer {
        style == .dark ? dark : light
    }

    var isEmpty: Bool { !isEnabled || (light.isEmpty && dark.isEmpty) }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, light, dark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            light: try c.decodeIfPresent(AppearanceCardBackgroundLayer.self, forKey: .light) ?? .init(),
            dark: try c.decodeIfPresent(AppearanceCardBackgroundLayer.self, forKey: .dark) ?? .init()
        )
    }
}

/// Everything an appearance theme owns beyond its five surface colours.
///
/// These used to be loose `GlobalSettings` keys, which is why switching back to
/// 默認 left an imported pack's tab icons, font, covers and effects in place with
/// no way to undo them. Holding them on the theme makes a pack one selectable
/// thing: `GlobalSettings.applyAppearanceThemeExtras` writes the active theme's
/// values and restores the user's own the moment a theme without extras is chosen.
///
/// Every field is optional and means "this theme does not speak for that
/// setting" — a colour-only theme leaves all of them nil and changes nothing.
struct AppearanceThemeExtras: Codable, Hashable, Sendable {
    /// Keyed `"<tabID>.<slot>"`, e.g. `"bookshelf.light"`, to a stored icon file name.
    var tabIcons: [String: String]?
    var tabIconSize: Double?
    var hidesTabLabels: Bool?

    var launchImageEnabled: Bool?
    var launchImageLightFileName: String?
    var launchImageDarkFileName: String?

    var defaultCoverLightFileNames: [String]?
    var defaultCoverDarkFileNames: [String]?
    var forceDefaultCover: Bool?

    var globalFontPostScript: String?

    var frostedGlass: Bool?
    var glassTransparency: Double?
    var glowIntensity: Double?

    var bookshelfGridColumnCount: Int?
    var bookshelfCoverCornerRadius: Double?

    /// `AppearanceReaderInterface` raw value.
    var readerInterface: String?

    var cardBackground: AppearanceCardBackground?

    init() {}

    /// True when the theme speaks for nothing — the common case for the built-in
    /// colour presets, and the signal that selecting it should restore the user's
    /// own settings rather than write anything.
    var isEmpty: Bool {
        tabIcons?.isEmpty != false
            && tabIconSize == nil && hidesTabLabels == nil
            && launchImageEnabled == nil
            && launchImageLightFileName == nil && launchImageDarkFileName == nil
            && defaultCoverLightFileNames?.isEmpty != false
            && defaultCoverDarkFileNames?.isEmpty != false
            && forceDefaultCover == nil
            && globalFontPostScript == nil
            && frostedGlass == nil && glassTransparency == nil && glowIntensity == nil
            && bookshelfGridColumnCount == nil && bookshelfCoverCornerRadius == nil
            && readerInterface == nil
            && (cardBackground?.isEmpty ?? true)
    }
}

// MARK: - Card background image storage

enum AppearanceCardBackgroundImageError: Error {
    case unsupportedImageFile
    case cannotReadImage
}

/// Card artwork on disk. A separate store from `AppearancePageBackgrounds` so
/// resetting page backgrounds cannot delete a card image that a theme still
/// references, and vice versa.
final class AppearanceCardBackgroundImageStore {
    static let shared = AppearanceCardBackgroundImageStore()

    /// Card art is drawn at card size, never full-bleed, so it needs far fewer
    /// pixels than a page background.
    private static let maxPixelSize: CGFloat = 1400

    private let fileManager: FileManager
    private let allowedExtensions: Set<String> = ["webp", "jpg", "jpeg", "png"]
    private let imageCache = NSCache<NSString, UIImage>()

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        imageCache.countLimit = 8
    }

    @discardableResult
    func importImage(data: Data, fallbackExtension: String = "") throws -> String {
        guard let image = UIImage(data: data) else {
            throw AppearanceCardBackgroundImageError.cannotReadImage
        }
        let sourceWasPNG = ImportedImageNormalizer.isPNG(data)
        let resized = downsample(image, maxPixelSize: Self.maxPixelSize)
        // `normalize` deliberately keeps PNG/JPEG bytes untouched, which would throw the
        // downsample away — so re-encode when the image actually shrank, and normalize
        // only when it did not.
        let output: ImportedImageNormalizer.Output?
        if resized === image {
            output = ImportedImageNormalizer.normalize(
                image: image,
                data: data,
                fallbackExtension: fallbackExtension,
                allowedExtensions: allowedExtensions
            )
        } else {
            output = ImportedImageNormalizer.encode(resized: resized, preservingPNG: sourceWasPNG)
        }
        guard let output else {
            throw AppearanceCardBackgroundImageError.cannotReadImage
        }
        let directory = try imagesDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "cardbg-\(UUID().uuidString).\(output.fileExtension)"
        try output.data.write(to: directory.appendingPathComponent(fileName))
        return fileName
    }

    func image(fileName: String) -> UIImage? {
        if let cached = imageCache.object(forKey: fileName as NSString) { return cached }
        guard let url = try? imagesDirectoryURL().appendingPathComponent(fileName),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        imageCache.setObject(image, forKey: fileName as NSString)
        return image
    }

    func fileData(fileName: String) -> Data? {
        guard let url = try? imagesDirectoryURL().appendingPathComponent(fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    func delete(fileName: String) {
        imageCache.removeObject(forKey: fileName as NSString)
        guard let url = try? imagesDirectoryURL().appendingPathComponent(fileName) else { return }
        try? fileManager.removeItem(at: url)
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
        return base.appendingPathComponent("CardBackgrounds", isDirectory: true)
    }
}
