import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Guards the real xTitleEditor export end to end: the fixture is the shipped
/// 星环 template with its artwork swapped for a 1×1 pixel, so every layer
/// number in it is the authored one.
@Suite("Lottie ring template", .serialized)
struct LottieRingTemplateTests {
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/xtitleeditor-ring.json")
    }

    @Test("renders both title slots as ink, not just the image")
    func paintsBothTitleSlots() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)

        let result = try await LottieTitleTemplateImporter.import(
            try Data(contentsOf: Self.fixtureURL),
            assetStore: store
        )
        let design = try #require(result.style.design)
        #expect(design.layers.map(\.kind) == [.image, .chapterName, .chapterNumber])

        let plan = try await ChapterTitleDesignRenderer.compile(
            title: "第1章 八百年后",
            design: design,
            appearance: .light,
            writingMode: .horizontal,
            renderWidth: 340,
            assetStore: store
        )
        let texts = plan.layers.compactMap(\.attributedText?.string)
        #expect(texts == ["八百年后", "第1章"])

        // Both lines must survive rasterization: a line box forced smaller than
        // the resolved font clips full-height CJK away while leaving a Latin
        // digit standing, which is exactly how "第1章 八百年后" degraded to "1".
        let canvas = try rasterize(plan)
        for layer in plan.layers where layer.attributedText != nil {
            #expect(canvas.ink(in: layer.frame) > 50)
        }
    }

    /// A chapter with no `第X章` prefix leaves the number slot empty. The layer
    /// still exists, with a zero-length attributed string — which the render
    /// diagnostics used to read at index 0, crashing the reader one chapter in.
    @Test("survives a title that fills only one slot")
    func survivesTitleWithoutNumber() async throws {
        let root = try readerStyleTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderStyleAssetStore(rootURL: root)
        let imported = try await LottieTitleTemplateImporter.import(
            try Data(contentsOf: Self.fixtureURL),
            assetStore: store
        )

        let attr = NSMutableAttributedString()
        await ChapterTitleAttributedBuilder.append(
            title: "小小灵娥",
            style: imported.style,
            settings: ReaderRenderSettings(
                theme: "t",
                textColor: .black,
                backgroundColor: .white,
                fontSize: 17,
                lineHeightMultiple: 1.2,
                lineSpacing: 0,
                paragraphSpacing: 8,
                letterSpacing: 0,
                marginH: 0,
                marginV: 0,
                footerHeight: 0,
                contentInsets: .zero,
                chapterTitleStyle: imported.style
            ),
            renderWidth: 392,
            themeTextColor: .black,
            themeBackgroundColor: .white,
            letterSpacing: 0,
            to: attr
        )

        #expect(attr.length > 0)
        // 上方間距 prepends a spacer line, so the plan is not at index 0.
        var found: ChapterTitleRenderPlan?
        attr.enumerateAttribute(
            ChapterTitleAttributedBuilder.designRenderPlanAttribute,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, _, _ in
            if let plan = value as? ChapterTitleRenderPlan { found = plan }
        }
        let texts = try #require(found).layers.compactMap(\.attributedText?.string)
        #expect(texts.contains("小小灵娥"))
        #expect(texts.contains(""))
    }

    private func rasterize(_ plan: ChapterTitleRenderPlan) throws -> Canvas {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: plan.canvasSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: plan.canvasSize))
            ChapterTitleCanvasPainter.draw(
                plan,
                in: CGRect(origin: .zero, size: plan.canvasSize),
                writingMode: ReaderWritingMode.horizontal,
                context: context.cgContext
            )
        }
        return try Canvas(image: image)
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

        func ink(in rect: CGRect) -> Int {
            var total = 0
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX))
                where pixels[y * bytesPerRow + x * 4] < 200 {
                    total += 1
                }
            }
            return total
        }
    }
}
