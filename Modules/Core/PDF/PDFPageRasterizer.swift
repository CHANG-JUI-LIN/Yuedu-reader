import CoreGraphics
import Foundation
import PDFKit
import UIKit

// MARK: - PDF page rasterizer
//
// Renders PDF pages to `UIImage` so they can flow through the existing fixed-page
// reader (which is image-based, shared with manga and fixed-layout EPUB).
//
// Everything runs inside the actor: `PDFDocument` / `CGPDFPage` are not thread
// safe, and the open document is kept alive between pages — reopening per page is
// what made the fixed-layout EPUB path expensive.
//
// Drawing goes through `CGPDFPage.getDrawingTransform`, the one API that resolves
// the page's own /Rotate and box origin for us; `PDFPage.bounds(for:)` does not.
actor PDFPageRasterizer {

    static let shared = PDFPageRasterizer()

    /// Rendered pages, keyed by file + page + requested size + crop.
    ///
    /// Cost is the image's byte size. A full-screen page on a 3x device is ~7 MB,
    /// so the limits below hold roughly the current page plus its neighbours; the
    /// reader only prefetches 2 pages ahead for the same reason.
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Each page's content region in page proportions (top-left origin), detected once
    /// and shared by every render width. A zoomed re-render must crop exactly the region
    /// the base render did; detecting again on a larger bitmap can land a pixel off and
    /// make the page jump. A stored `nil` is a page with no border worth cropping.
    private var contentRects: [String: CGRect?] = [:]

    /// Width of the throwaway render that border detection scans. The crop processor
    /// downsamples to 40% before scanning, so screen resolution buys nothing here.
    private static let contentDetectionWidth: CGFloat = 800

    /// Only the book being read stays open — switching books drops the previous one.
    private var openPath: String?
    private var openDocument: PDFDocument?

    func pageCount(fileURL: URL) -> Int {
        document(for: fileURL)?.pageCount ?? 0
    }

    /// The document's own bookmarks, read from the already-open document.
    func sections(fileURL: URL) -> [FixedPageDocumentSection] {
        guard let document = document(for: fileURL) else { return [] }
        return LocalPDFArchive.sections(in: document)
    }

    func image(
        fileURL: URL,
        pageIndex: Int,
        targetWidth: CGFloat,
        scale: CGFloat,
        cropBorders: Bool = false
    ) -> UIImage? {
        guard targetWidth > 0, scale > 0 else { return nil }
        let key = cacheKey(
            fileURL: fileURL,
            pageIndex: pageIndex,
            targetWidth: targetWidth,
            scale: scale,
            cropBorders: cropBorders
        )
        if let cached = cache.object(forKey: key) { return cached }
        // A load its view gave up on — the cell scrolled away or was reused, the reader closed —
        // still waits its turn on this actor behind the pages asked for before it, and drawing
        // it anyway is work nobody sees: a fling down a scanned PDF strip spent 90 s of CPU in
        // 140 s scaling pages in `renderPage` (Crashlytics 19bca592, MetricKit cpu-exception).
        // The draw itself cannot stop once it starts, so the checks sit before each one.
        guard !Task.isCancelled else { return nil }

        guard let document = document(for: fileURL) else {
            AppLogger.render("PDF rasterize failed: cannot open \(fileURL.lastPathComponent)")
            return nil
        }
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else {
            AppLogger.render("PDF rasterize failed: page \(pageIndex) out of range in \(fileURL.lastPathComponent)")
            return nil
        }
        let contentRect = cropBorders ? self.contentRect(of: page, fileURL: fileURL, pageIndex: pageIndex) : nil
        guard !Task.isCancelled else { return nil }
        guard let image = Self.renderPage(page, targetWidth: targetWidth, scale: scale, contentRect: contentRect) else {
            AppLogger.render("PDF rasterize failed: page \(pageIndex) of \(fileURL.lastPathComponent)")
            return nil
        }

        cache.setObject(image, forKey: key, cost: Self.byteCost(of: image))
        return image
    }

    /// Drop cached renders for one book (used when its pages are no longer on screen).
    func purge() {
        cache.removeAllObjects()
        contentRects.removeAll()
        openPath = nil
        openDocument = nil
    }

    private func document(for fileURL: URL) -> PDFDocument? {
        if openPath == fileURL.path, let openDocument { return openDocument }
        guard let document = try? LocalPDFArchive.openDocument(at: fileURL) else { return nil }
        openPath = fileURL.path
        openDocument = document
        return document
    }

    private func contentRect(of page: PDFPage, fileURL: URL, pageIndex: Int) -> CGRect? {
        let key = "\(fileURL.path)#\(pageIndex)"
        if let known = contentRects[key] { return known }
        // A page that cannot render here cannot render for the caller either; the caller's
        // own render reports that failure, so nothing is recorded or logged twice.
        guard let probe = Self.renderPage(page, targetWidth: Self.contentDetectionWidth, scale: 1),
              let pixels = probe.cgImage else { return nil }
        let width = CGFloat(pixels.width)
        let height = CGFloat(pixels.height)
        let detected = FixedPageCropBordersProcessor().contentRect(in: probe).map {
            CGRect(x: $0.minX / width, y: $0.minY / height, width: $0.width / width, height: $0.height / height)
        }
        contentRects[key] = detected
        return detected
    }

    private func cacheKey(
        fileURL: URL,
        pageIndex: Int,
        targetWidth: CGFloat,
        scale: CGFloat,
        cropBorders: Bool
    ) -> NSString {
        "\(fileURL.path)#\(pageIndex)@\(Int(targetWidth.rounded()))x\(scale)\(cropBorders ? "#crop" : "")" as NSString
    }

    private static func byteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Render one page, fitted to `targetWidth` points at `scale` pixels per point.
    ///
    /// With a `contentRect` (page proportions, top-left origin) only that region is drawn,
    /// widened to fill `targetWidth`.
    nonisolated static func renderPage(
        _ page: PDFPage,
        targetWidth: CGFloat,
        scale: CGFloat,
        contentRect: CGRect? = nil
    ) -> UIImage? {
        guard let pageRef = page.pageRef else { return nil }

        let box = pageRef.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        // A page rotated a quarter turn presents its height as its width.
        let isQuarterTurned = abs(pageRef.rotationAngle) % 180 == 90
        let displayWidth = isQuarterTurned ? box.height : box.width
        let displayHeight = isQuarterTurned ? box.width : box.height

        // The whole page is laid out this wide, so that the kept region comes out at `targetWidth`.
        let pageWidth = contentRect.map { targetWidth / $0.width } ?? targetWidth
        let pageSize = CGSize(
            width: pageWidth,
            height: (pageWidth * displayHeight / displayWidth).rounded()
        )
        let size = contentRect.map {
            CGSize(width: targetWidth, height: (pageSize.height * $0.height).rounded())
        } ?? pageSize
        guard size.height > 0 else { return nil }

        // `getDrawingTransform` only ever shrinks a page into its rect: handed a rect wider
        // than the page it draws the page 1:1, centered, with blank paper around it. So it
        // gets a rect no larger than the page and the rest of the scaling happens here. At
        // or below the page's own width this is 1 and the drawing is exactly the old one.
        let upscale = max(1, pageSize.width / displayWidth)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            // PDFs have no background of their own; paper is white.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let cgContext = context.cgContext
            if let contentRect {
                cgContext.translateBy(
                    x: -contentRect.minX * pageSize.width,
                    y: -contentRect.minY * pageSize.height
                )
            }
            cgContext.translateBy(x: 0, y: pageSize.height)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.scaleBy(x: upscale, y: upscale)
            cgContext.concatenate(
                pageRef.getDrawingTransform(
                    .cropBox,
                    rect: CGRect(
                        origin: .zero,
                        size: CGSize(width: pageSize.width / upscale, height: pageSize.height / upscale)
                    ),
                    rotate: 0,
                    preserveAspectRatio: true
                )
            )
            cgContext.drawPDFPage(pageRef)
        }
    }
}
