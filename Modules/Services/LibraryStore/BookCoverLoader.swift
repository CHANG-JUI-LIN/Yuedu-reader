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

    /// The memory budget (128 MB, costed by decoded bitmap size) and the in-flight
    /// coalescing live in the pipeline, shared with the covers saved on disk. A fully
    /// populated discover page holds several hundred covers; the budget is sized so
    /// scrolling back doesn't churn through evict → refetch → redecode. Concurrent
    /// loads of one URL coalesce: on 發現頁 the same book (and cover) appears in
    /// several sections, and prefetch races the cell-driven loads.
    private static var pipeline: CoverImagePipeline { .shared }

    /// The largest cover slot in the app renders at ~140pt ≈ 420px @3x; 640px
    /// keeps a comfortable margin while cutting a 1080×1440 original's decoded
    /// footprint by ~5×.
    private static let maxCoverPixelSize = CoverPixelSize.standard.longEdge

    /// 探索設定 › 封面並發數: at most this many covers downloading at once, anywhere in the
    /// app; 0 — the default, and how it always was — sets no limit beyond URLSession's own.
    static let downloadLimitKey = "coverDownloadLimit"
    static var downloadLimit: Int { UserDefaults.standard.integer(forKey: downloadLimitKey) }

    /// Headers for a cover request: browser UA + Referer (the source's base URL),
    /// with the source's own header rule layered on top (it may override the UA).
    ///
    /// Fallback note: Legado sends no automatic Referer — only the source's header
    /// rule. This one was added (e06ab753) as a guess against hotlink-protected
    /// CDNs. It is only sent when the base URL really is an http(s) URL: aggregate
    /// sources name themselves in `bookSourceUrl` (📚书山聚合 uses `书山聚合`), and
    /// byteimg answers that bogus Referer with 403 while accepting none or any real
    /// URL — the 書山聚合 detail covers that never loaded. Deleting the Referer
    /// entirely aligns with Legado, but this helper also serves chapter images and
    /// audio, so that needs its own regression pass.
    static func headers(sourceBaseURL: String?, sourceHeaders: [String: String]) -> [String: String] {
        var result: [String: String] = ["User-Agent": defaultUserAgent]
        if let base = sourceBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           let scheme = URL(string: base)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            result["Referer"] = base
        }
        for (key, value) in sourceHeaders { result[key] = value }
        return result
    }

    static func remoteSession(for book: ReadingBook, connections: OPDSCatalogStore = .shared) -> URLSession? {
        guard let reference = book.remoteSource,
              let connection = connections.connection(id: reference.connectionID) else { return nil }
        return connections.httpClient(for: connection).session
    }

    static func cacheKey(for urlString: String, session: URLSession? = nil) -> String {
        guard let session else { return urlString }
        return "\(session.sessionDescription ?? String(describing: ObjectIdentifier(session)))|\(urlString)"
    }

    static func cachedImage(for urlString: String, session: URLSession? = nil) -> UIImage? {
        pipeline.cachedNetworkImage(forKey: cacheKey(for: urlString, session: session))
    }

    /// Drops decoded cover bitmaps without touching the persisted cover files: memory
    /// reclaim only. When cover *files* change, the writer invalidates instead
    /// (`BookCoverFileStore`, `CoverImagePipeline.invalidateDownloadedBookCovers`), which
    /// is what also stops a load already in flight from putting the old bitmap back.
    static func clearMemoryCache() {
        pipeline.purgeMemory()
    }

    /// Fetch a cover image, honoring the in-memory cache and the supplied headers.
    static func loadImage(urlString: String, headers: [String: String], session: URLSession? = nil) async -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed) != nil else {
            AppLogger.network("⟐ cover URL is not a URL", context: ["url": String(trimmed.prefix(300))])
            return nil
        }
        let key = cacheKey(for: trimmed, session: session)
        if let cached = pipeline.cachedNetworkImage(forKey: key) { return cached }
        return await pipeline.coalescedNetworkLoad(key: key) {
            await fetchAndCache(urlString: trimmed, headers: headers, session: session, cacheKey: key)
        }
    }

    private static func fetchAndCache(urlString: String, headers: [String: String], session: URLSession?, cacheKey: String) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        if url.scheme == "data" {
            guard urlString.utf8.count <= 2 * 1024 * 1024,
                  let comma = urlString.firstIndex(of: ","),
                  urlString[..<comma].hasPrefix("data:image/"),
                  urlString[..<comma].hasSuffix(";base64"),
                  let bytes = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])),
                  let image = decodedCover(from: bytes) else {
                AppLogger.network("Invalid inline cover image")
                return nil
            }
            pipeline.storeNetworkImage(image, forKey: cacheKey)
            return image
        }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let data: Data
        let response: URLResponse
        await CoverDownloadGate.shared.enter(limit: downloadLimit)
        do { (data, response) = try await (session ?? .shared).data(for: request) }
        catch {
            await CoverDownloadGate.shared.leave()
            AppLogger.network("⟐ cover request failed", error: error, context: ["url": String(urlString.prefix(300))])
            return nil
        }
        await CoverDownloadGate.shared.leave()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            AppLogger.network(
                "⟐ cover request rejected",
                context: ["url": String(urlString.prefix(300)), "status": http.statusCode]
            )
            return nil
        }
        // Sources with `coverDecodeJs` serve encrypted cover bytes; decode falls
        // back to the raw data so a broken rule degrades, not disappears.
        let effectiveData = await SourceScriptThread.run {
            CoverDecodeService.shared.decodedIfRegistered(coverUrl: urlString, data: data)
        } ?? data
        guard let image = decodedCover(from: effectiveData) else {
            AppLogger.network(
                "⟐ cover bytes are not an image",
                context: ["url": String(urlString.prefix(300)), "bytes": effectiveData.count]
            )
            return nil
        }

        pipeline.storeNetworkImage(image, forKey: cacheKey)
        return image
    }

    /// Downsample to the largest size any cover slot renders at, forcing the
    /// decode here (already off-main) so cells draw a ready bitmap.
    ///
    /// Also used for covers that never came from the network — a photo-library
    /// pick is routinely 12MP, and storing that full size would put a full-size
    /// decode on the main thread in every shelf row that draws it.
    static func decodedCover(from data: Data) -> UIImage? {
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

    /// The cover already saved for a book, read from `ReadingBook.coverImagePath`,
    /// **blocking**, at the pipeline's largest size.
    ///
    /// Only for callers that need the artwork right now and are not a scrolling list:
    /// Now Playing, the reader's 現代 chrome, the download Live Activity. The bookshelf
    /// never calls this; it loads through `BookshelfCoverArtwork`, which reads memory
    /// in its body and leaves the disk to a task. Shares the pipeline's cache, decoder
    /// and invalidation, so what these callers get is exactly what the shelf shows.
    /// `StorageLocations` routes between `Covers` and `CustomCovers`; callers must not
    /// join that path themselves.
    static func localImage(filename: String?) -> UIImage? {
        guard let filename, !filename.isEmpty else { return nil }
        let request = CoverImageRequest(source: .bookCover(filename: filename), size: .largest)
        return pipeline.loadImmediately(request).image
    }

    /// Download a cover and save it as JPEG under Application Support/Covers; returns the saved
    /// filename (to store in `ReadingBook.coverImagePath`) or nil on failure.
    static func downloadAndSave(
        urlString: String,
        headers: [String: String],
        filename: String,
        session: URLSession? = nil
    ) async -> String? {
        guard let image = await loadImage(urlString: urlString, headers: headers, session: session),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try BookCoverFileStore.live.write(jpeg, filename: filename)
            return filename
        } catch {
            AppLogger.cache("⟐ downloaded cover could not be saved", error: error)
            return nil
        }
    }
}

/// The one way the app's own flows write or delete a saved cover: download
/// (`downloadAndSave`), 相簿 / 封面搜索 picks and 重設封面 (`BookStore`).
///
/// A write creates the directory first, since 快取管理 or the system may have removed
/// it since launch, and replaces the file atomically, so a decode running at the
/// same moment reads the old bytes or the new ones, never half of each. A failed
/// write throws and leaves the previous file and its cached bitmap untouched; a
/// successful one invalidates that filename, so the shelf redraws it without a
/// restart, and a load that read the old bytes cannot publish them afterwards.
struct BookCoverFileStore: Sendable {
    let root: URL
    let pipeline: CoverImagePipeline

    static var live: BookCoverFileStore {
        BookCoverFileStore(root: StorageLocations.applicationSupportRoot, pipeline: .shared)
    }

    func location(of filename: String) -> URL {
        StorageLocations.coverFileLocation(filename, in: root)
    }

    func write(_ data: Data, filename: String) throws {
        let url = location(of: filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        pipeline.invalidate([.bookCover(filename: filename)])
    }

    /// Deletes a saved cover. A file already gone is not an error; anything else is
    /// logged. The bitmap is invalidated either way, so nothing keeps drawing a file
    /// the book no longer points at.
    func remove(filename: String) {
        do {
            try FileManager.default.removeItem(at: location(of: filename))
        } catch CocoaError.fileNoSuchFile {
            // Already gone: the state the caller wanted.
        } catch {
            AppLogger.cache("⟐ cover file could not be removed", error: error)
        }
        pipeline.invalidate([.bookCover(filename: filename)])
    }
}
