import CoreImage
import SwiftUI
import UIKit

// A cover's main colour, for a surface drawn in it: the audiobook player's background, and
// 精簡閱讀卡片 on Explore's home (unified library 5d-3c, decision 20). One average for both.
//
// A card does not load its cover a second time to find the colour. The views that draw a
// cover (`BookCoverImage`, `BookshelfCoverArtwork`, `GeneratedBookCover`, the home's file
// cover) report the image they show to a `coverImageObserver` above them, so the colour is
// the one of the cover on screen, whichever of the shelf's fallbacks it came from.

enum CoverTint {
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }

        func scaled(by factor: Double) -> RGB {
            RGB(red: red * factor, green: green * factor, blue: blue * factor)
        }
    }

    /// Thread-safe; one for every average instead of a context per call.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// The image's average colour (`CIAreaAverage`), or nil when it has no bitmap.
    static func average(of image: UIImage) -> RGB? {
        guard let cg = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cg)
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: CIVector(cgRect: ciImage.extent)]
        ), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return RGB(red: Double(bitmap[0]) / 255, green: Double(bitmap[1]) / 255, blue: Double(bitmap[2]) / 255)
    }

    /// WCAG relative luminance of an sRGB colour.
    static func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// The contrast ratio of white text on the colour.
    static func contrastWithWhite(_ rgb: RGB) -> Double {
        1.05 / (luminance(rgb) + 0.05)
    }

    /// The colour as it is when white text on it already reaches `minimumContrast`, else
    /// darkened just enough that it does: a dark cover keeps its colour, a pale one deepens.
    static func background(for rgb: RGB, minimumContrast: Double) -> RGB {
        guard contrastWithWhite(rgb) < minimumContrast else { return rgb }
        // Darker is monotonically more contrast; black gives 21:1, so a factor exists.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if contrastWithWhite(rgb.scaled(by: middle)) >= minimumContrast { low = middle } else { high = middle }
        }
        return rgb.scaled(by: low)
    }
}

extension EnvironmentValues {
    /// Told the image each cover view below draws; nil (the default) everywhere but where a
    /// surface takes its colour from the cover.
    @Entry var coverImageObserver: (@MainActor (UIImage) -> Void)?
}

extension View {
    /// Reports the image this cover draws to the `coverImageObserver` above, if there is one.
    func reportsCoverImage(_ image: UIImage?) -> some View {
        modifier(CoverImageReport(image: image))
    }
}

private struct CoverImageReport: ViewModifier {
    let image: UIImage?
    @Environment(\.coverImageObserver) private var observer

    func body(content: Content) -> some View {
        content.onChange(of: image.map(ObjectIdentifier.init), initial: true) {
            if let image, let observer { observer(image) }
        }
    }
}
