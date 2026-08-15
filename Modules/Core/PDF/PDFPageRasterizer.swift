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

    /// Rendered pages, keyed by file + page + requested size.
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

    func image(fileURL: URL, pageIndex: Int, targetWidth: CGFloat, scale: CGFloat) -> UIImage? {
        guard targetWidth > 0, scale > 0 else { return nil }
        let key = cacheKey(fileURL: fileURL, pageIndex: pageIndex, targetWidth: targetWidth, scale: scale)
        if let cached = cache.object(forKey: key) { return cached }

        guard let document = document(for: fileURL) else {
            AppLogger.render("PDF rasterize failed: cannot open \(fileURL.lastPathComponent)")
            return nil
        }
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else {
            AppLogger.render("PDF rasterize failed: page \(pageIndex) out of range in \(fileURL.lastPathComponent)")
            return nil
        }
        guard let image = Self.renderPage(page, targetWidth: targetWidth, scale: scale) else {
            AppLogger.render("PDF rasterize failed: page \(pageIndex) of \(fileURL.lastPathComponent)")
            return nil
        }

        cache.setObject(image, forKey: key, cost: Self.byteCost(of: image))
        return image
    }

    /// Drop cached renders for one book (used when its pages are no longer on screen).
    func purge() {
        cache.removeAllObjects()
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

    private func cacheKey(fileURL: URL, pageIndex: Int, targetWidth: CGFloat, scale: CGFloat) -> NSString {
        "\(fileURL.path)#\(pageIndex)@\(Int(targetWidth.rounded()))x\(scale)" as NSString
    }

    private static func byteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Render one page, fitted to `targetWidth` points at `scale` pixels per point.
    nonisolated static func renderPage(_ page: PDFPage, targetWidth: CGFloat, scale: CGFloat) -> UIImage? {
        guard let pageRef = page.pageRef else { return nil }

        let box = pageRef.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        // A page rotated a quarter turn presents its height as its width.
        let isQuarterTurned = abs(pageRef.rotationAngle) % 180 == 90
        let displayWidth = isQuarterTurned ? box.height : box.width
        let displayHeight = isQuarterTurned ? box.width : box.height

        let size = CGSize(
            width: targetWidth,
            height: (targetWidth * displayHeight / displayWidth).rounded()
        )
        guard size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            // PDFs have no background of their own; paper is white.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let cgContext = context.cgContext
            cgContext.translateBy(x: 0, y: size.height)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.concatenate(
                pageRef.getDrawingTransform(
                    .cropBox,
                    rect: CGRect(origin: .zero, size: size),
                    rotate: 0,
                    preserveAspectRatio: true
                )
            )
            cgContext.drawPDFPage(pageRef)
        }
    }
}
