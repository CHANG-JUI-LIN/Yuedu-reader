import ImageIO
import UIKit

/// Loads and caches remote book covers, applying the headers many book-source
/// CDNs require (browser `User-Agent` + `Referer`) — `AsyncImage` sends neither,
/// which is why hotlink-protected source covers came back blank.
///
/// Covers are downsampled and force-decoded off the main thread before caching:
/// CDN originals are frequently 1080×1440+, and handing those to a list cell as
/// `UIImage(data:)` defers the full-size decode to first draw — on the main
/// thread, mid-scroll — which is where the 發現頁 frame drops came from.
///
/// Also used at add-to-shelf time to persist a cover to disk (`downloadAndSave`).
enum BookCoverLoader {

    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        // Entries carry their decoded-bitmap byte size as cost (~1.1MB at the
        // 640px ceiling). A fully-populated discover page holds several hundred
        // covers; size the budget so scrolling back doesn't churn through
        // evict → refetch → redecode. NSCache still dumps entries on memory
        // pressure regardless of this limit.
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    /// The largest cover slot in the app renders at ~140pt ≈ 420px @3x; 640px
    /// keeps a comfortable margin while cutting a 1080×1440 original's decoded
    /// footprint by ~5×.
    private static let maxCoverPixelSize = 640

    /// Coalesces concurrent loads of one URL: on 發現頁 the same book (and cover)
    /// appears in several sections, and prefetch races the cell-driven loads.
    private static let inflight = CoverInflightStore()

    /// Headers for a cover request: browser UA + Referer (the source's base URL),
    /// with the source's own header rule layered on top (it may override the UA).
    static func headers(sourceBaseURL: String?, sourceHeaders: [String: String]) -> [String: String] {
        var result: [String: String] = ["User-Agent": defaultUserAgent]
        if let base = sourceBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            result["Referer"] = base
        }
        for (key, value) in sourceHeaders { result[key] = value }
        return result
    }

    static func cachedImage(for urlString: String) -> UIImage? {
        cache.object(forKey: urlString as NSString)
    }

    /// Fetch a cover image, honoring the in-memory cache and the supplied headers.
    static func loadImage(urlString: String, headers: [String: String]) async -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return nil }
        if let cached = cache.object(forKey: trimmed as NSString) { return cached }
        return await inflight.value(for: trimmed) {
            await fetchAndCache(urlString: trimmed, headers: headers)
        }
    }

    private static func fetchAndCache(urlString: String, headers: [String: String]) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        // Sources with `coverDecodeJs` serve encrypted cover bytes; decode falls
        // back to the raw data so a broken rule degrades, not disappears.
        let effectiveData = CoverDecodeService.shared.decodedIfRegistered(
            coverUrl: urlString, data: data
        ) ?? data
        guard let image = decodedCover(from: effectiveData) else { return nil }

        cache.setObject(image, forKey: urlString as NSString, cost: bitmapCost(of: image))
        return image
    }

    /// Downsample to the largest size any cover slot renders at, forcing the
    /// decode here (already off-main) so cells draw a ready bitmap.
    private static func decodedCover(from data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxCoverPixelSize
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func bitmapCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Download a cover and save it as JPEG under Documents; returns the saved
    /// filename (to store in `ReadingBook.coverImagePath`) or nil on failure.
    static func downloadAndSave(
        urlString: String,
        headers: [String: String],
        filename: String
    ) async -> String? {
        guard let image = await loadImage(urlString: urlString, headers: headers),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let fileURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        do {
            try jpeg.write(to: fileURL)
            return filename
        } catch {
            return nil
        }
    }
}

/// Serializes "is someone already fetching this URL?" bookkeeping; the fetches
/// themselves run concurrently in their own tasks.
private actor CoverInflightStore {
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func value(
        for key: String,
        make: @escaping @Sendable () async -> UIImage?
    ) async -> UIImage? {
        if let existing = tasks[key] {
            return await existing.value
        }
        let task = Task { await make() }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}
