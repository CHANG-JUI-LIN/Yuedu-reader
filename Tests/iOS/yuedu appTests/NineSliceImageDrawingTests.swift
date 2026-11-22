import CoreGraphics
import Foundation
import Testing
@testable import yuedu_app

/// FB-238: a translucent nine-slice frame showed a thin line where its slices meet.
/// A uniform half-transparent image drawn through the nine-patch must come out uniform:
/// any row or column whose alpha differs from the rest is a seam.
@Suite("Nine-slice drawing leaves no seams")
struct NineSliceImageDrawingTests {
    /// 高透绿／高透蓝: 956×256, every pixel but a 1px centre is corner.
    private static let slices = NineSliceImageDrawing.Insets(top: 128, right: 477, bottom: 127, left: 478)
    private static let deviceScale: CGFloat = 3
    private static let canvas = CGSize(width: 260, height: 60)

    private static func uniformImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 956, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: 956, height: 256))
        return try #require(context.makeImage())
    }

    /// Alpha of every device pixel that lies wholly inside `rect`, drawn the way the
    /// highlight renderer draws: y-up, 3x, high interpolation, an offset translation.
    private static func interiorAlpha(
        rect: CGRect,
        offset: CGSize = .zero
    ) throws -> (alpha: [[UInt8]], image: CGImage) {
        let width = Int(canvas.width * deviceScale)
        let height = Int(canvas.height * deviceScale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: deviceScale, y: deviceScale)
        context.translateBy(x: offset.width, y: offset.height)
        context.interpolationQuality = .high
        let image = try uniformImage()
        NineSliceImageDrawing.draw(
            image,
            slices: slices,
            scale: rect.height / CGFloat(image.height),
            in: rect,
            context: context
        )

        let device = rect.offsetBy(dx: offset.width, dy: offset.height)
            .applying(CGAffineTransform(scaleX: deviceScale, y: deviceScale))
        let minX = Int(device.minX.rounded(.up)), maxX = Int(device.maxX.rounded(.down))
        let minY = Int(device.minY.rounded(.up)), maxY = Int(device.maxY.rounded(.down))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var rows: [[UInt8]] = []
        for y in minY..<maxY {
            // The context is y-up; its bytes start at the top row.
            let line = height - 1 - y
            rows.append((minX..<maxX).map { data[(line * width + $0) * 4 + 3] })
        }
        return (rows, try #require(context.makeImage()))
    }

    private static func describeSeams(_ alpha: [[UInt8]]) -> String {
        let all = alpha.flatMap { $0 }
        let counts = Dictionary(grouping: all, by: { $0 }).mapValues(\.count)
        let common = counts.max { $0.value < $1.value }?.key ?? 0
        var rows: [String] = []
        for (index, row) in alpha.enumerated() {
            let off = row.filter { abs(Int($0) - Int(common)) > 1 }
            if off.count > row.count / 2 { rows.append("row \(index)=\(off[0])") }
        }
        var columns: [String] = []
        for column in 0..<(alpha.first?.count ?? 0) {
            let off = alpha.map { $0[column] }.filter { abs(Int($0) - Int(common)) > 1 }
            if off.count > alpha.count / 2 { columns.append("column \(column)=\(off[0])") }
        }
        return "common alpha \(common); \(rows.joined(separator: ", ")); \(columns.joined(separator: ", "))"
    }

    private static func expectUniform(_ alpha: [[UInt8]]) {
        let all = alpha.flatMap { $0 }
        let low = all.min() ?? 0, high = all.max() ?? 0
        #expect(!all.isEmpty)
        #expect(Int(high) - Int(low) <= 1, "seam: \(describeSeams(alpha))")
    }

    @Test("a wide fragment at a fractional origin and height has no line through its middle")
    func wideFragmentHasNoSeam() throws {
        let rendered = try Self.interiorAlpha(
            rect: CGRect(x: 10.3, y: 12.4, width: 200.3, height: 30.5)
        )
        Self.expectUniform(rendered.alpha)
    }

    @Test("a short quote, whose corners are shrunk to meet, has no line where they meet")
    func narrowFragmentHasNoSeam() throws {
        let rendered = try Self.interiorAlpha(
            rect: CGRect(x: 10.3, y: 12.4, width: 80.2, height: 30.5)
        )
        Self.expectUniform(rendered.alpha)
    }

    @Test("the background-image offset the renderer translates by does not bring the seam back")
    func translatedFragmentHasNoSeam() throws {
        let rendered = try Self.interiorAlpha(
            rect: CGRect(x: 10, y: 12, width: 200, height: 30),
            offset: CGSize(width: 0.4, height: -0.7)
        )
        Self.expectUniform(rendered.alpha)
    }
}
