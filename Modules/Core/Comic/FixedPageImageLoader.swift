import UIKit
import Nuke

// MARK: - Fixed page image loading
//
// Dispatches fixed-page render sources. Image archive pages use Nuke's shared
// pipeline; fixed-layout EPUB and PDF pages are rasterized on demand.

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

    /// Build a Nuke request for a page: headered URLRequest + resize-to-width.
    static func request(for page: FixedPage, targetWidth: CGFloat) -> ImageRequest {
        let resolved = page.localURL ?? URL(string: page.imageURL)
        var urlRequest = URLRequest(url: resolved ?? URL(fileURLWithPath: "/dev/null"))
        if page.localURL == nil {
            for (key, value) in page.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        }
        var processors: [any ImageProcessing] = []
        if targetWidth > 0 {
            processors.append(ImageProcessors.Resize(width: targetWidth, unit: .points, upscale: false))
        }
        return ImageRequest(urlRequest: urlRequest, processors: processors)
    }

    @MainActor
    static func loadImage(
        for page: FixedPage,
        targetWidth: CGFloat,
        renderScale: CGFloat? = nil
    ) async -> UIImage? {
        switch page.renderSource {
        case .fixedLayoutEPUB(let sourceFilename, let chapterIndex):
            return await FixedLayoutEPUBRenderer.shared.image(
                sourceURL: LocalMangaArchive.archiveURL(for: sourceFilename),
                pageIndex: chapterIndex,
                targetWidth: targetWidth
            )
        case .pdf(let sourceFilename, let pageIndex):
            return await PDFPageRasterizer.shared.image(
                fileURL: LocalPDFArchive.archiveURL(for: sourceFilename),
                pageIndex: pageIndex,
                targetWidth: targetWidth,
                scale: renderScale ?? defaultRenderScale
            )
        case .image:
            return try? await ImagePipeline.shared.image(for: request(for: page, targetWidth: targetWidth))
        }
    }

    @MainActor
    static func prefetch(_ pages: [FixedPage], targetWidth: CGFloat, using prefetcher: ImagePrefetcher) {
        var imageRequests: [ImageRequest] = []
        var rasterizedPages: [FixedPage] = []
        for page in pages {
            switch page.renderSource {
            case .image:
                imageRequests.append(request(for: page, targetWidth: targetWidth))
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
                _ = await loadImage(for: page, targetWidth: targetWidth)
            }
        }
    }
}
