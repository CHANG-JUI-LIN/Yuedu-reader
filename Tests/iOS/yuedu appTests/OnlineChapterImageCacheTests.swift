@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Offline download of a PROSE chapter's illustrations, and the reader reading them back.
///
/// Before this, only comics downloaded their images: a "downloaded" light novel still needed a
/// live connection to show its 插图 pages, and every re-open re-fetched every plate. Legado has
/// always cached chapter images per book (`BookHelp.saveImage` → `ImageProvider`).
@Suite("Offline chapter illustrations", .serialized)
@MainActor
struct OnlineChapterImageCacheTests {

    private static func pngData(pixels size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func temporaryRoots() -> (roots: OfflineStorageRoots, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yd-offline-\(UUID().uuidString)", isDirectory: true)
        let roots = OfflineStorageRoots(
            textRoot: base.appendingPathComponent("text", isDirectory: true),
            mangaRoot: base.appendingPathComponent("manga", isDirectory: true)
        )
        return (roots, { try? FileManager.default.removeItem(at: base) })
    }

    private static func renderSettings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 16,
            marginV: 16,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
    }

    // MARK: - Disk cache naming

    @Test("a URL maps to one stable filename, keeping a usable extension")
    func filenameIsStableAndKeepsExtension() {
        let url = "https://picture.302258.xyz/1/1614/54785/67547.jpg"
        let first = OnlineImageDiskCache.filename(for: url)
        #expect(first == OnlineImageDiskCache.filename(for: url))
        #expect(first.hasSuffix(".jpg"))
        #expect(first != OnlineImageDiskCache.filename(for: url + "?v=2"))
        // An endpoint-shaped URL has no extension to keep.
        #expect(OnlineImageDiskCache.filename(for: "https://a.example/img?id=7").hasSuffix(".img"))
    }

    // MARK: - Download

    @Test("illustrations are downloaded with the source's headers, failures skipped")
    func downloadsWhatItCanAndSkipsTheRest() async {
        let (roots, cleanup) = Self.temporaryRoots()
        defer { cleanup() }
        let bookId = UUID()
        let downloader = StubOfflineImageDownloader(
            payload: Self.pngData(pixels: CGSize(width: 40, height: 30)),
            failingURLs: ["https://plates.example/dead.jpg"]
        )
        let store = OfflineChapterStore(roots: roots, imageDownloader: downloader)

        let stored = await store.persistTextImages(
            OfflineTextImageRequest(
                bookId: bookId,
                images: [
                    OfflineMangaImageRequest(
                        sourceURL: "https://plates.example/1.jpg",
                        headers: ["User-Agent": "source-ua"]
                    ),
                    OfflineMangaImageRequest(
                        sourceURL: "https://plates.example/dead.jpg",
                        headers: ["User-Agent": "source-ua"]
                    ),
                    OfflineMangaImageRequest(
                        sourceURL: "https://plates.example/2.jpg",
                        headers: ["User-Agent": "source-ua"]
                    ),
                ]
            )
        )

        #expect(stored == 2)
        let cache = OnlineImageDiskCache(directory: roots.textImagesDirectory(bookId: bookId))
        #expect(cache.contains("https://plates.example/1.jpg"))
        #expect(cache.contains("https://plates.example/2.jpg"))
        // The dead plate must not leave a placeholder behind — a chapter with one missing
        // illustration is still a downloaded chapter.
        #expect(!cache.contains("https://plates.example/dead.jpg"))
        #expect(await downloader.userAgents.allSatisfy { $0 == "source-ua" })
    }

    @Test("a second run does not re-download what is already on disk")
    func alreadyCachedImagesAreSkipped() async {
        let (roots, cleanup) = Self.temporaryRoots()
        defer { cleanup() }
        let bookId = UUID()
        let downloader = StubOfflineImageDownloader(
            payload: Self.pngData(pixels: CGSize(width: 40, height: 30))
        )
        let store = OfflineChapterStore(roots: roots, imageDownloader: downloader)
        let request = OfflineTextImageRequest(
            bookId: bookId,
            images: [OfflineMangaImageRequest(sourceURL: "https://plates.example/1.jpg", headers: [:])]
        )

        #expect(await store.persistTextImages(request) == 1)
        let afterFirst = await downloader.requestCount
        #expect(await store.persistTextImages(request) == 0)
        #expect(await downloader.requestCount == afterFirst)
    }

    @Test("downloaded illustrations survive removeBook only until the book goes")
    func removeBookDropsTheImages() async throws {
        let (roots, cleanup) = Self.temporaryRoots()
        defer { cleanup() }
        let bookId = UUID()
        let store = OfflineChapterStore(
            roots: roots,
            imageDownloader: StubOfflineImageDownloader(
                payload: Self.pngData(pixels: CGSize(width: 40, height: 30))
            )
        )
        _ = await store.persistTextImages(
            OfflineTextImageRequest(
                bookId: bookId,
                images: [OfflineMangaImageRequest(sourceURL: "https://plates.example/1.jpg", headers: [:])]
            )
        )
        #expect(await store.storageByteCount(bookId: bookId) > 0)

        try await store.removeBook(bookId: bookId)
        #expect(await store.storageByteCount(bookId: bookId) == 0)
    }

    // MARK: - Read back

    @Test("the reader draws a downloaded illustration without touching the network")
    func readerPrefersTheDownloadedCopy() async throws {
        let (roots, cleanup) = Self.temporaryRoots()
        defer { cleanup() }
        let bookId = UUID()
        let src = "https://plates.example/\(UUID().uuidString).png"
        let cache = OnlineImageDiskCache(directory: roots.textImagesDirectory(bookId: bookId))
        try cache.write(Self.pngData(pixels: CGSize(width: 60, height: 40)), for: src)

        UnreachableHostURLProtocol.reset()
        URLProtocol.registerClass(UnreachableHostURLProtocol.self)
        defer { URLProtocol.unregisterClass(UnreachableHostURLProtocol.self) }

        let builder = OnlineProviderAttributedStringBuilder(
            provider: SingleHTMLChapterProvider(html: "<p><img src=\"\(src)\"></p>"),
            renderSize: CGSize(width: 320, height: 480),
            imageCacheDirectory: roots.textImagesDirectory(bookId: bookId)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(),
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        )

        #expect(result.attributedString.string.contains("\u{FFFC}"))
        #expect(UnreachableHostURLProtocol.requestCount == 0)
    }

    @Test("a cache miss still goes to the network")
    func cacheMissFallsThroughToTheFetch() async throws {
        let (roots, cleanup) = Self.temporaryRoots()
        defer { cleanup() }
        let bookId = UUID()
        let src = "https://plates.example/\(UUID().uuidString).png"

        UnreachableHostURLProtocol.reset()
        URLProtocol.registerClass(UnreachableHostURLProtocol.self)
        defer { URLProtocol.unregisterClass(UnreachableHostURLProtocol.self) }

        let builder = OnlineProviderAttributedStringBuilder(
            provider: SingleHTMLChapterProvider(html: "<p><img src=\"\(src)\"></p>"),
            renderSize: CGSize(width: 320, height: 480),
            imageCacheDirectory: roots.textImagesDirectory(bookId: bookId)
        )

        _ = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(),
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        )

        #expect(UnreachableHostURLProtocol.requestCount == 1)
    }
}

// MARK: - Fixtures

private final class SingleHTMLChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) {
        self.html = html
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第一卷 插图" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(
            index: 0,
            title: "第一卷 插图",
            plainText: "",
            body: .html(html),
            sourceHref: "https://example.invalid/chapter/1"
        )
    }
}

private actor StubOfflineImageDownloader: OfflineImageDownloading {
    private let payload: Data
    private let failingURLs: Set<String>
    private(set) var requestCount = 0
    private(set) var userAgents: [String] = []

    init(payload: Data, failingURLs: Set<String> = []) {
        self.payload = payload
        self.failingURLs = failingURLs
    }

    func response(for request: URLRequest) async throws -> OfflineImageResponse {
        requestCount += 1
        if let ua = request.value(forHTTPHeaderField: "User-Agent") {
            userAgents.append(ua)
        }
        let url = request.url?.absoluteString ?? ""
        guard !failingURLs.contains(url) else {
            return OfflineImageResponse(data: Data(), statusCode: 403, mimeType: "text/html")
        }
        return OfflineImageResponse(data: payload, statusCode: 200, mimeType: "image/png")
    }
}

/// Counts requests and fails them all — proves whether the reader went to the network at all.
private final class UnreachableHostURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int { lock.withLock { requests } }

    static func reset() {
        lock.withLock { requests = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "plates.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
