import CoreGraphics
import Testing
import UIKit
@testable import yuedu_app

@Suite("MathML baseline raster metrics", .serialized)
struct MathMLBaselineTests {
    @Test func overWideFormulaScalesWidthHeightAndBaselineTogether() throws {
        let metrics = try #require(MathMLAttachmentMetrics.resolve(
            naturalSize: CGSize(width: 600, height: 120),
            naturalAscent: 90,
            naturalDescent: 30,
            availableWidth: 240,
            horizontalPadding: 0
        ))

        #expect(metrics.drawWidth == 240)
        #expect(metrics.drawHeight == 48)
        #expect(metrics.ascent == 36)
        #expect(metrics.descent == 12)
        #expect(metrics.totalWidth == 240)
        #expect(metrics.logicalScale == 0.4)
    }

    @Test func formulaMetricPolicyRejectsInvalidGeometry() {
        #expect(MathMLAttachmentMetrics.resolve(
            naturalSize: .zero,
            naturalAscent: 0,
            naturalDescent: 0,
            availableWidth: 240,
            horizontalPadding: 0
        ) == nil)
        #expect(MathMLAttachmentMetrics.resolve(
            naturalSize: CGSize(width: 100, height: 20),
            naturalAscent: 15,
            naturalDescent: 5,
            availableWidth: .infinity,
            horizontalPadding: 0
        ) == nil)
    }

    @Test @MainActor func inlineIdentifierBaselineTracksInkBottom() throws {
        let rendered = try #require(MathMLImageRenderer.render(
            latex: "x",
            fontSize: 24,
            textColor: .black,
            displayMode: .inline,
            targetWidth: 320
        ))
        let bounds = try #require(Self.inkBounds(in: rendered.image))
        let height = CGFloat(rendered.image.cgImage?.height ?? 0)
        let declaredBaseline = height - rendered.descentFraction * height
        let inkBottom = bounds.maxY

        #expect(
            abs(inkBottom - declaredBaseline) <= 2,
            "inkBottom \(inkBottom) should sit on declared baseline \(declaredBaseline)"
        )
        // The bitmap must be exactly ascent+descent tall — no vertical centering padding from
        // MTMathUILabel's fontSize/2 minimum height. Padding here is what made short inline
        // formulas sink below the text baseline.
        let scale = CGFloat(rendered.image.cgImage?.height ?? 0) / max(1, rendered.image.size.height)
        #expect(
            bounds.height >= height - 3 * scale,
            "ink height \(bounds.height) should fill bitmap height \(height) (no label padding)"
        )
        #expect(
            abs((rendered.ascent + rendered.descent) * scale - height) <= 1.5 * scale,
            "declared ascent+descent must match the bitmap height"
        )
    }

    @Test @MainActor func linearAlgebraFixtureMathRunMetricsMatchDrawHeight() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(
            entries: EPUBTestFixtures.linearAlgebra().entries
        )
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 360, height: 640)
        )
        let result = try await builder.buildChapter(
            at: 0,
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let mathRun = try #require(
            EPUBTestFixtures.imageRunInfos(in: result.attributedString)
                .first { $0.info.source.hasPrefix("mathml:") }
        )
        let info = mathRun.info
        #expect(
            abs((info.ascent + info.descent) - info.drawHeight) <= 1,
            "reserved line box (\(info.ascent)+\(info.descent)) must equal drawn height \(info.drawHeight)"
        )
        // A bare identifier (`x`) has essentially no ink below the baseline; a large descent is
        // exactly the bug where inline math rendered like a subscript.
        #expect(
            info.descent <= 3,
            "identifier descent \(info.descent) should be near zero"
        )
    }

    @Test @MainActor func inlineFractionDeclaresFullDrawHeight() throws {
        let rendered = try #require(MathMLImageRenderer.render(
            latex: "\\frac{a}{b}",
            fontSize: 24,
            textColor: .black,
            displayMode: .inline,
            targetWidth: 320
        ))
        let imageHeight = CGFloat(rendered.image.cgImage?.height ?? 0)
        let descent = rendered.descentFraction * imageHeight
        let ascent = imageHeight - descent

        #expect(ascent > 0)
        #expect(descent > 0)
        #expect(abs((ascent + descent) - imageHeight) <= 1)
    }

    @Test @MainActor func formulaRasterUsesDecoratedParagraphWidthExactlyOnce() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(
            entries: EPUBTestFixtures.mathMLTypography().entries
        )
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let result = try await EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 220, height: 640)
        ).buildChapter(
            at: 0,
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let runs = EPUBTestFixtures.imageRunInfos(in: result.attributedString)
            .filter { $0.info.source == "mathml:" }
        #expect(!runs.isEmpty)
        for run in runs {
            let info = run.info
            #expect(info.drawWidth <= 172.5)
            #expect(abs(info.ascent + info.descent - info.drawHeight) <= 1)
            #expect(abs((info.image?.size.width ?? 0) - info.drawWidth) <= 0.5)
            #expect(abs((info.image?.size.height ?? 0) - info.drawHeight) <= 0.5)
        }
    }

    private static func inkBounds(in image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                guard alpha > 8 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
