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

    /// A card's ground until its cover has drawn (`DSColor.coverTintPlaceholder`).
    static let placeholder = RGB(red: 0.30, green: 0.31, blue: 0.33)

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

    /// A cover's hue as a detail page's hero washes it in: the hue alone, drawn at the page's
    /// own lightness, so a muddy average cannot turn the wash grey.
    struct Wash: Equatable, Sendable {
        var hue: Double
        var saturation: Double

        /// Pale over a light page, deep over a dark one, faint in both.
        func color(dark: Bool) -> Color {
            Color(hue: hue, saturation: saturation,
                  brightness: dark ? DSLayout.bookDetailWashDarkBrightness : DSLayout.bookDetailWashLightBrightness)
                .opacity(dark ? DSLayout.bookDetailWashDarkOpacity : DSLayout.bookDetailWashLightOpacity)
        }
    }

    /// The wash for an average colour; nil when the cover is close to grey, which would only
    /// lay a haze over the page (black, white and grey covers, the Moby Dick kind of brown).
    static func wash(for rgb: RGB) -> Wash? {
        let high = max(rgb.red, rgb.green, rgb.blue)
        let low = min(rgb.red, rgb.green, rgb.blue)
        guard high > 0 else { return nil }
        let saturation = (high - low) / high
        guard saturation >= DSLayout.bookDetailWashMinimumSaturation else { return nil }
        var hue: Double
        let delta = high - low
        if high == rgb.red {
            hue = (rgb.green - rgb.blue) / delta
        } else if high == rgb.green {
            hue = (rgb.blue - rgb.red) / delta + 2
        } else {
            hue = (rgb.red - rgb.green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return Wash(hue: hue, saturation: min(saturation, DSLayout.bookDetailWashMaximumSaturation))
    }

    /// WCAG relative luminance of an sRGB colour.
    static func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// The WCAG contrast ratio between two colours, in either order.
    static func contrast(_ first: RGB, _ second: RGB) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The contrast ratio of white text on the colour.
    static func contrastWithWhite(_ rgb: RGB) -> Double {
        contrast(RGB(red: 1, green: 1, blue: 1), rgb)
    }

    /// 精簡閱讀卡片's kind line, as Apple Books draws 書籍・12% on its Continue card: the
    /// cover's hue, light, at no more than a set saturation; grey for a grey cover.
    /// A hue that stays dark at that brightness (blue, violet) is mixed towards white until it
    /// is as light as `DSLayout.homeContinueTintMinimumLuminance`, so a ground dark enough
    /// for 7:1 under it exists.
    static func lightTint(for rgb: RGB) -> RGB {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(hue: hue, saturation: min(saturation, DSLayout.homeContinueTintSaturation),
                brightness: DSLayout.homeContinueTintBrightness, alpha: 1)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let tint = RGB(red: red, green: green, blue: blue)
        let floor = DSLayout.homeContinueTintMinimumLuminance
        guard luminance(tint) < floor else { return tint }
        func mixed(_ white: Double) -> RGB {
            RGB(red: tint.red + (1 - tint.red) * white, green: tint.green + (1 - tint.green) * white,
                blue: tint.blue + (1 - tint.blue) * white)
        }
        // More white is monotonically lighter; white itself is past the floor.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if luminance(mixed(middle)) >= floor { high = middle } else { low = middle }
        }
        return mixed(high)
    }

    /// The colour as it is when white text on it already reaches `minimumContrast`, else
    /// darkened just enough that it does: a dark cover keeps its colour, a pale one deepens.
    static func background(for rgb: RGB, minimumContrast: Double) -> RGB {
        background(for: rgb, under: RGB(red: 1, green: 1, blue: 1), minimumContrast: minimumContrast)
    }

    /// The same for a light `foreground`: darkened just enough that it reaches
    /// `minimumContrast` on the colour. White, lighter still, then reads at least as well.
    static func background(for rgb: RGB, under foreground: RGB, minimumContrast: Double) -> RGB {
        guard contrast(foreground, rgb) < minimumContrast else { return rgb }
        // Darker is monotonically more contrast under a light foreground; black is the most.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if contrast(foreground, rgb.scaled(by: middle)) >= minimumContrast { low = middle } else { high = middle }
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
