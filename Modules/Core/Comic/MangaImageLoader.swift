import UIKit
import Nuke

// MARK: - Manga image loading (Nuke)
//
// Wraps Nuke's shared pipeline: builds a headered, downsampled request per page
// (downsampling to the screen width is the key memory lever for large pages),
// prefers a downloaded local file when present, and exposes a prefetcher.

enum MangaImageLoader {

    /// Build a Nuke request for a page: headered URLRequest + resize-to-width.
    static func request(for page: MangaPage, targetWidth: CGFloat) -> ImageRequest {
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
    static func loadImage(for page: MangaPage, targetWidth: CGFloat) async -> UIImage? {
        try? await ImagePipeline.shared.image(for: request(for: page, targetWidth: targetWidth))
    }

    @MainActor
    static func prefetch(_ pages: [MangaPage], targetWidth: CGFloat, using prefetcher: ImagePrefetcher) {
        prefetcher.startPrefetching(with: pages.map { request(for: $0, targetWidth: targetWidth) })
    }
}
