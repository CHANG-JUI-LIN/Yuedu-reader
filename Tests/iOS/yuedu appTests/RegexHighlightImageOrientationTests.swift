import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A regex-highlight background image has to land the way up it was drawn.
///
/// The painter runs in the line drawer's context, which is already flipped to
/// CoreText's y-up convention — where CoreGraphics draws images upright on its
/// own. Flipping again turns every background image upside down, which is
/// invisible on a symmetric texture and obvious on anything with a top and a
/// bottom.
@Suite("Regex highlight image orientation", .serialized)
struct RegexHighlightImageOrientationTests {
    private static let width: CGFloat = 200
    private static let fontSize: CGFloat = 24

    @Test("draws a background image the right way up")
    func drawsBackgroundUpright() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let asset = try await store.importImage(
            data: try #require(Self.halfAndHalfImage().pngData()),
            suggestedName: "half.png"
        )

        var style = ReaderStyleRuleStyle()
        style.decoration.backgroundImage = ReaderStyleImagePresentation(
            assetID: asset.id,
            contentMode: .stretch
        )
        let configuration = RegexHighlightConfiguration(
            isEnabled: true,
            rules: [],
            customRules: [
                RegexHighlightRule(
                    id: "orientation",
                    name: "orientation",
                    pattern: "AAAA",
                    isEnabled: true,
                    isBuiltIn: false,
                    options: [],
                    lightStyle: style,
                    darkStyle: style
                ),
            ]
        )
        await store.prewarmRegexHighlightAssets(
            configuration: configuration,
            appearance: .light
        )

        let attr = NSMutableAttributedString(
            string: "AAAA",
            attributes: [
                .font: UIFont.systemFont(ofSize: Self.fontSize),
                .foregroundColor: UIColor.clear,
            ]
        )
        _ = try RegexHighlightEngine.apply(
            configuration: configuration,
            appearance: .light,
            to: attr
        )

        let canvas = try render(attr)
        let top = try #require(canvas.dominantColor(inTopHalf: true))
        let bottom = try #require(canvas.dominantColor(inTopHalf: false))

        // The source image is red over blue.
        #expect(top == .red)
        #expect(bottom == .blue)
    }

    // MARK: - Fixtures

    private static func halfAndHalfImage() -> UIImage {
        let size = CGSize(width: 16, height: 16)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 8, width: 16, height: 8))
        }
    }

    private func render(_ attr: NSAttributedString) throws -> Canvas {
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let range = CFRange(location: 0, length: attr.length)
        let height: CGFloat = 80
        let frame = CTFramesetterCreateFrame(
            framesetter,
            range,
            CGPath(
                rect: CGRect(x: 0, y: 0, width: Self.width, height: height),
                transform: nil
            ),
            nil
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: Self.width, height: height),
            format: format
        ).image { context in
            let ctx = context.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: Self.width, height: height))
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
            CoreTextHorizontalLineDrawer.drawLines(
                of: frame,
                contentWidth: Self.width,
                contentMinX: 0,
                contentMinY: 0,
                isLastPage: true,
                attrStr: attr,
                hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                in: ctx
            )
            ctx.restoreGState()
        }
        return try Canvas(image: image)
    }

    private enum Swatch: Equatable {
        case red
        case blue
        case other
    }

    private struct Canvas {
        private let pixels: [UInt8]
        private let bytesPerRow: Int
        private let width: Int
        private let height: Int

        init(image: UIImage) throws {
            let cgImage = try #require(image.cgImage)
            width = cgImage.width
            height = cgImage.height
            bytesPerRow = width * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
            let context = try #require(
                CGContext(
                    data: &buffer,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = buffer
        }

        /// Most common swatch across the painted half of the highlight box.
        func dominantColor(inTopHalf: Bool) -> Swatch? {
            var counts: [Swatch: Int] = [:]
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let swatch = classify(
                        red: Int(pixels[offset]),
                        green: Int(pixels[offset + 1]),
                        blue: Int(pixels[offset + 2])
                    )
                    guard swatch != .other else { continue }
                    counts[swatch, default: 0] += 1
                }
            }
            guard !counts.isEmpty else { return nil }
            // Locate the painted band, then read the requested half of it.
            var minY = height
            var maxY = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    guard classify(
                        red: Int(pixels[offset]),
                        green: Int(pixels[offset + 1]),
                        blue: Int(pixels[offset + 2])
                    ) != .other else { continue }
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard minY <= maxY else { return nil }
            let middle = (minY + maxY) / 2
            let rows = inTopHalf ? minY...max(minY, middle - 1) : min(maxY, middle + 1)...maxY
            var half: [Swatch: Int] = [:]
            for y in rows {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let swatch = classify(
                        red: Int(pixels[offset]),
                        green: Int(pixels[offset + 1]),
                        blue: Int(pixels[offset + 2])
                    )
                    guard swatch != .other else { continue }
                    half[swatch, default: 0] += 1
                }
            }
            return half.max { $0.value < $1.value }?.key
        }

        private func classify(red: Int, green: Int, blue: Int) -> Swatch {
            if red > 150, green < 100, blue < 100 { return .red }
            if blue > 150, red < 100, green < 100 { return .blue }
            return .other
        }
    }
}
