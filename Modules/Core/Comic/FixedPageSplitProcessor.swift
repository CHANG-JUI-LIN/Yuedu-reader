import CoreGraphics
import Foundation
import UIKit

// MARK: - Fixed page split processor
//
// Detects two-page spreads and splits them into two single pages for optimal
// reading on vertical screens, matching Aidoku's splitWideImages behavior.

enum FixedPageSplitProcessor {

    /// Whether an image has a landscape aspect ratio typical of a 2-page manga spread.
    static func isWideImage(_ image: UIImage) -> Bool {
        guard image.size.height > 0 else { return false }
        return (image.size.width / image.size.height) >= 1.15
    }

    /// Crops the requested sub-page half from a wide image.
    static func cropHalf(from image: UIImage, side: FixedPage.SubPageSide) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let totalW = CGFloat(cgImage.width)
        let totalH = CGFloat(cgImage.height)
        let halfW = floor(totalW / 2)

        let cropRect: CGRect
        switch side {
        case .left:
            cropRect = CGRect(x: 0, y: 0, width: halfW, height: totalH)
        case .right:
            cropRect = CGRect(x: halfW, y: 0, width: totalW - halfW, height: totalH)
        }

        guard let croppedCG = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Splits a wide image into left and right half images.
    static func split(image: UIImage) -> (left: UIImage, right: UIImage)? {
        guard isWideImage(image) else { return nil }
        return (
            left: cropHalf(from: image, side: .left),
            right: cropHalf(from: image, side: .right)
        )
    }
}
