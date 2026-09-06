import CoreGraphics
import Foundation
import Nuke
import UIKit

// MARK: - Crop borders processor
//
// Detects white and black scanning borders around manga pages and crops them out
// so the art fills the viewport, adapted from Aidoku's CropBordersProcessor.

struct FixedPageCropBordersProcessor: ImageProcessing {

    var identifier: String {
        "com.yuedu.reader.cropBorders"
    }

    private let whiteThreshold: UInt8 = 0xEA
    private let blackThreshold: UInt8 = 0x15
    private let downscale: CGFloat = 0.4

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard let cgImage = image.cgImage else { return image }

        return autoreleasepool {
            let origW = CGFloat(cgImage.width)
            let origH = CGFloat(cgImage.height)
            guard origW > 10, origH > 10 else { return image }

            let downsampledImage = downsample(image)
            guard let downsampledCG = downsampledImage.cgImage else { return image }
            let cropRect = createCropRect(downsampledCG, origW: origW, origH: origH)
            guard !cropRect.isEmpty else { return image }

            // Ensure the crop removes at least some border (e.g. > 1% change)
            // and does not aggressively discard more than 60% of the page.
            let widthDiff = origW - cropRect.width
            let heightDiff = origH - cropRect.height
            guard (widthDiff > origW * 0.01 || heightDiff > origH * 0.01),
                  cropRect.width > origW * 0.4,
                  cropRect.height > origH * 0.4 else {
                return image
            }

            if let cropped = cgImage.cropping(to: cropRect) {
                return PlatformImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
            }
            return image
        }
    }

    private func createCropRect(_ cgImage: CGImage, origW: CGFloat, origH: CGFloat) -> CGRect {
        let width = cgImage.width
        let height = cgImage.height
        let widthFloat = CGFloat(width)
        let heightFloat = CGFloat(height)

        guard let context = createARGBBitmapContext(width: width, height: height),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return .zero
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var lowX = widthFloat
        var lowY = heightFloat
        var highX: CGFloat = 0
        var highY: CGFloat = 0

        // Scan pixels for non-transparent, non-white, non-black content
        for y in 0..<height {
            let yF = CGFloat(y)
            for x in 0..<width {
                let xF = CGFloat(x)
                let pixelIndex = (width * y + x) * 4

                let r = data[pixelIndex]
                let g = data[pixelIndex + 1]
                let b = data[pixelIndex + 2]
                let a = data[pixelIndex + 3]

                // Alpha
                if a == 0 { continue }

                // White border
                if r > whiteThreshold && g > whiteThreshold && b > whiteThreshold {
                    continue
                }

                // Black border
                if r < blackThreshold && g < blackThreshold && b < blackThreshold {
                    continue
                }

                lowX = min(xF, lowX)
                highX = max(xF, highX)
                lowY = min(yF, lowY)
                highY = max(yF, highY)
            }
        }

        guard highX >= lowX, highY >= lowY else { return .zero }

        let scaleX = CGFloat(width) / origW
        let scaleY = CGFloat(height) / origH

        let cropX = max(0, round(lowX / scaleX))
        let cropY = max(0, round(lowY / scaleY))
        let cropW = min(origW - cropX, round((highX - lowX + 1) / scaleX))
        let cropH = min(origH - cropY, round((highY - lowY + 1) / scaleY))

        return CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
    }

    private func downsample(_ image: UIImage) -> UIImage {
        let targetW = max(50, image.size.width * downscale)
        let targetH = max(50, image.size.height * downscale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetW, height: targetH), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        }
    }

    private func createARGBBitmapContext(width: Int, height: Int) -> CGContext? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
