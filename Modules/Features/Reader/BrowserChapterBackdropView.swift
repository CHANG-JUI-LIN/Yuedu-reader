import UIKit
import YueduCoreText

/// A viewport-driven browser chapter's page background (`BrowserPageBackground`),
/// shown by the fragment host behind the chapter instead of by its paint fragments.
/// - It spans the whole screen width, like paged mode's page canvas: CSS gives the
///   html/body background to the canvas, not to the content box.
/// - It is on screen with the chapter. Fragments are painted off the main thread
///   and may arrive late; per the 2026-09-21 choice text may be late, the
///   background may not.
/// - Its image is sized, placed and repeated against one screen, as paged mode
///   does against one page (`BrowserPageBackground.imageTiling`). A `fixed` one stays put while the text scrolls; otherwise one page of
///   artwork per screen height scrolls with the chapter, as a CoreText chapter's
///   does (`CoreTextChunkBackdropView`).
/// Layer contents only: nothing is drawn, and every layer shares the one decoded image.
@MainActor
final class BrowserChapterBackdropView: UIView {
    private var background: BrowserPageBackground?
    private var pages: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Page layers currently shown, for tests.
    var visiblePageFrames: [CGRect] { pages.filter { !$0.isHidden }.map(\.frame) }

    /// Call with this view already framed at the chapter's full-width band;
    /// `viewport` and `retention` are in the superview's coordinates.
    func update(background: BrowserPageBackground, image: UIImage?, viewport: CGRect, retention: CGRect) {
        if self.background != background {
            self.background = background
            backgroundColor = background.color
        }
        guard let cgImage = image?.cgImage, let image, viewport.width > 0, viewport.height > 0 else {
            return showPages(at: [], image: nil, rect: .zero, contentsRect: .zero)
        }
        let page = CGRect(origin: .zero, size: viewport.size)
        guard let tiling = background.imageTiling(for: image.size, onPageOf: page.size) else {
            return showPages(at: [], image: nil, rect: .zero, contentsRect: .zero)
        }
        // An image that repeats is composed once into one page of artwork, so
        // a page stays one layer however small the tile is.
        let repeats = tiling.repeatsX || tiling.repeatsY
        guard let artwork = repeats ? tiledPage(tiling, image: image, pageSize: page.size) : cgImage else {
            return showPages(at: [], image: nil, rect: .zero, contentsRect: .zero)
        }
        let drawn = repeats ? page : tiling.tile
        let rect = drawn.intersection(page)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            return showPages(at: [], image: nil, rect: .zero, contentsRect: .zero)
        }
        // The part of the image a page shows, so no layer draws outside its page.
        let contentsRect = CGRect(x: (rect.minX - drawn.minX) / drawn.width, y: (rect.minY - drawn.minY) / drawn.height,
                                  width: rect.width / drawn.width, height: rect.height / drawn.height)
        let tops: [CGFloat]
        if background.isFixed {
            tops = [viewport.minY - frame.minY]
        } else {
            let band = retention.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds)
            if band.isNull || band.height <= 0 {
                tops = []
            } else {
                let first = Int(floor(band.minY / page.height))
                let last = max(first + 1, Int(ceil(band.maxY / page.height)))
                tops = (first..<last).map { CGFloat($0) * page.height }
            }
        }
        showPages(at: tops, image: artwork, rect: rect, contentsRect: contentsRect)
    }

    private var tiledPageCache: (tiling: BackgroundTiling, image: UIImage, pageSize: CGSize, page: CGImage)?

    /// One page of `image` laid out as `tiling` says, kept until any of them changes.
    private func tiledPage(_ tiling: BackgroundTiling, image: UIImage, pageSize: CGSize) -> CGImage? {
        if let cached = tiledPageCache, cached.tiling == tiling, cached.image === image, cached.pageSize == pageSize {
            return cached.page
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let composed = UIGraphicsImageRenderer(size: pageSize, format: format).image { _ in
            for tile in tiling.tiles() { image.draw(in: tile) }
        }
        guard let page = composed.cgImage else { return nil }
        tiledPageCache = (tiling, image, pageSize, page)
        return page
    }

    private func showPages(at tops: [CGFloat], image: CGImage?, rect: CGRect, contentsRect: CGRect) {
        while pages.count < tops.count {
            let page = CALayer()
            page.contentsGravity = .resize
            layer.addSublayer(page)
            pages.append(page)
        }
        for (index, page) in pages.enumerated() {
            guard index < tops.count, let image else {
                if !page.isHidden { page.isHidden = true }
                continue
            }
            if page.isHidden { page.isHidden = false }
            if (page.contents as AnyObject?) !== image { page.contents = image }
            if page.contentsRect != contentsRect { page.contentsRect = contentsRect }
            let frame = rect.offsetBy(dx: 0, dy: tops[index])
            if page.frame != frame { page.frame = frame }
        }
    }
}
