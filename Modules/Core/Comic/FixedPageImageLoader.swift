import UIKit
import Nuke

// MARK: - Fixed page image loading
//
// Dispatches fixed-page render sources. Image pages — remote, downloaded, or an entry of
// a local comic archive — use Nuke's shared pipeline; fixed-layout EPUB and PDF pages are
// rasterized on demand.

enum FixedPageImageLoader {

    /// Pixels per point for a rasterized page. Native screen scale keeps PDF text
    /// crisp at 1x; `FixedPagePageViewController` re-renders above this when the
    /// reader zooms in.
    @MainActor
    static var defaultRenderScale: CGFloat { UIScreen.main.scale }

    /// Ceiling for a single rasterized page, in pixels of width. A zoomed-in page is
    /// re-rendered rather than upscaled, and without a cap a 5x zoom on a 3x screen
    /// would ask for a ~65 MB bitmap.
    static let maxRasterPixelWidth: CGFloat = 2000

    /// Build a Nuke request for a page: headered URLRequest + resize-to-width + optional border crop.
    static func request(for page: FixedPage, targetWidth: CGFloat, cropBorders: Bool = false) -> ImageRequest {
        var processors: [any ImageProcessing] = []
        if cropBorders {
            processors.append(FixedPageCropBordersProcessor())
        }
        if targetWidth > 0 {
            processors.append(ImageProcessors.Resize(width: targetWidth, unit: .points, upscale: false))
        }
        if case .archiveImage(let sourceFilename, let entryPath) = page.renderSource {
            // A local comic page is read out of its archive on demand, one entry, through
            // the reader's open archive. The shared pipeline has no data cache, so the
            // decoded page lives only in Nuke's memory cache, under this id.
            let archiveURL = LocalMangaArchive.archiveURL(for: sourceFilename)
            return ImageRequest(
                id: "local-comic:" + sourceFilename + "#" + entryPath,
                data: { try await LocalMangaArchiveReader.shared.data(entryPath: entryPath, in: archiveURL) },
                processors: processors
            )
        }
        let resolved = page.localURL ?? URL(string: page.imageURL)
        var urlRequest = URLRequest(url: resolved ?? URL(fileURLWithPath: "/dev/null"))
        if page.localURL == nil {
            for (key, value) in page.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        }
        guard let decoder = page.imageDecoder else {
            return ImageRequest(urlRequest: urlRequest, processors: processors)
        }
        // The source's `imageDecode` runs on the bytes before anything decodes them, so the
        // crop, the resize, the ratio the webtoon sizes its cell by, and Live Text all see the
        // real picture. Bytes are fetched through the same pipeline (its HTTP cache keeps the
        // raw download) and decoded on every fetch; only the decoded image is cached, under
        // a key of its own, so a cache hit can never hand back the scrambled one. A
        // downloaded page is stored raw, like the network's, and goes through here too.
        let rawRequest = ImageRequest(urlRequest: urlRequest)
        let src = page.imageDecodeSrc
        let pageID = page.id
        let name = diagnosticName(for: page)
        return ImageRequest(
            id: decoder.cacheKeyPrefix + src,
            data: {
                let (raw, _) = try await ImagePipeline.shared.data(for: rawRequest)
                // Nothing to decode; the pipeline reports the empty page itself.
                guard !raw.isEmpty else { return raw }
                if let decoded = await decoder.decode(raw, src: src) { return decoded }
                // The project's decode contract (`SourceImageDecoder`, the text reader's
                // illustrations): a rule that returns nothing leaves the bytes as downloaded,
                // so a broken rule shows a wrong-looking page rather than none. Legado's
                // manga loader fails the page instead.
                AppLogger.parse(
                    "Comic page imageDecode returned no bytes; showing the page as downloaded",
                    context: ["page": pageID, "image": name, "source": decoder.source.bookSourceName],
                    level: .warning
                )
                return raw
            },
            processors: processors
        )
    }

    @MainActor
    static func loadImage(
        for page: FixedPage,
        targetWidth: CGFloat,
        renderScale: CGFloat? = nil,
        cropBorders: Bool = false
    ) async -> UIImage? {
        var baseImage: UIImage?
        switch page.renderSource {
        case .fixedLayoutEPUB(let sourceFilename, let chapterIndex):
            baseImage = await FixedLayoutEPUBRenderer.shared.image(
                sourceURL: LocalMangaArchive.archiveURL(for: sourceFilename),
                pageIndex: chapterIndex,
                targetWidth: targetWidth,
                cropBorders: cropBorders
            )
        case .pdf(let sourceFilename, let pageIndex):
            baseImage = await PDFPageRasterizer.shared.image(
                fileURL: LocalPDFArchive.archiveURL(for: sourceFilename),
                pageIndex: pageIndex,
                targetWidth: targetWidth,
                scale: renderScale ?? defaultRenderScale,
                cropBorders: cropBorders
            )
        case .image, .archiveImage:
            do {
                baseImage = try await ImagePipeline.shared.image(
                    for: request(for: page, targetWidth: targetWidth, cropBorders: cropBorders)
                )
            } catch {
                // A reused or scrolled-away cell cancels its load all the time; that is
                // not a failure. Anything else is, and the page stays blank until it is
                // displayed again (the webtoon's `willDisplay`, the paged retry button).
                guard !Task.isCancelled, !(error is CancellationError) else { return nil }
                AppLogger.network(
                    "Fixed page image failed to load",
                    error: error,
                    context: ["page": page.id, "image": diagnosticName(for: page)],
                    level: .error
                )
                return nil
            }
        }

        guard var image = baseImage else { return nil }

        if let side = page.subPageSide {
            image = FixedPageSplitProcessor.cropHalf(from: image, side: side)
        }
        return image
    }

    /// Where a page's image comes from, for the log: archive and entry name of a local
    /// comic page, the file name of a downloaded page,
    /// or host and last path component of a remote one — CDN query strings often carry
    /// signed tokens.
    static func diagnosticName(for page: FixedPage) -> String {
        if case .archiveImage(let sourceFilename, let entryPath) = page.renderSource {
            return "\(sourceFilename)#\((entryPath as NSString).lastPathComponent)"
        }
        if let localURL = page.localURL { return localURL.lastPathComponent }
        guard let url = URL(string: page.imageURL) else { return "unparseable-url" }
        return "\(url.host ?? "")/\(url.lastPathComponent)"
    }

    /// Prefetch must ask for the same variant the page will display: the crop flag is
    /// part of both Nuke's processor key and the rasterizer's cache key, so a prefetch
    /// without it warms a render the reader never reads.
    @MainActor
    static func prefetch(_ pages: [FixedPage], targetWidth: CGFloat, cropBorders: Bool, using prefetcher: ImagePrefetcher) {
        var imageRequests: [ImageRequest] = []
        var rasterizedPages: [FixedPage] = []
        for page in pages {
            switch page.renderSource {
            case .image, .archiveImage:
                imageRequests.append(request(for: page, targetWidth: targetWidth, cropBorders: cropBorders))
            case .pdf, .fixedLayoutEPUB:
                rasterizedPages.append(page)
            }
        }

        if !imageRequests.isEmpty {
            prefetcher.startPrefetching(with: imageRequests)
        }
        guard !rasterizedPages.isEmpty else { return }

        // Warms the renderers' own caches, which is what `loadImage` reads from.
        // Sequential on purpose: both renderers serialize internally anyway, and
        // running ahead of the reader shouldn't compete with the visible page.
        Task(priority: .utility) {
            for page in rasterizedPages {
                _ = await loadImage(for: page, targetWidth: targetWidth, cropBorders: cropBorders)
            }
        }
    }
}
