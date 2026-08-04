import Testing
import UIKit
@testable import yuedu_app

/// Golden snapshot tests: render a page's DisplayList into a UIImage and compare
/// against a stored PNG (tolerance = small pixel diff). Geometry assertions run
/// alongside — the snapshot proves *visible* output, geometry proves *layout*.
///
/// Regenerating goldens: delete the PNG files under
/// `Tests/iOS/yuedu appTests/Fixtures/BrowserLayout/` and re-run this suite
/// (missing goldens are recorded automatically). Keep the simulator OS pinned
/// (fonts render identically on the same OS).
struct BrowserLayoutSnapshotTests {

    private static func goldenURL(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BrowserLayout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test func nestedBoxesGoldenSnapshot() async throws {
        let css = """
        body { margin: 0; }
        .outer { width: 80%; margin: 20px auto; padding: 12px; border: 2px solid; background-color: #f0f0f0; }
        .inner { width: 50%; margin-left: auto; padding: 8px; border-left: 4px solid #cc0000; }
        .inner p { margin: 0; font-size: 14px; }
        """
        let html = """
        <html><head><style>\(css)</style></head><body>
        <div class="outer"><div class="inner"><p>The box model, computed naturally.</p></div></div>
        </body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 300, height: 200)
        #expect(pages.count == 1)

        // Geometry assertions alongside the snapshot.
        let line = try #require(BrowserLayoutTestSupport.allTextFragments(pages).first)
        #expect(line.rect.minY == 22)

        let list = DisplayListBuilder.build(for: pages[0], sourceText: doc.lastSourceText)
        let image = DisplayListRenderer.render(list, size: CGSize(width: 300, height: 200))
        try verifySnapshot(image, name: "golden-nested-boxes.png")
    }

    @Test func paragraphGoldenSnapshot() async throws {
        let html = """
        <html><body style="margin: 0"><p>The quick brown fox jumps over the lazy dog.</p></body></html>
        """
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 300, height: 120)
        #expect(pages.count == 1)
        let list = DisplayListBuilder.build(for: pages[0], sourceText: doc.lastSourceText)
        let image = DisplayListRenderer.render(list, size: CGSize(width: 300, height: 120))
        try verifySnapshot(image, name: "golden-paragraph.png")
    }

    // MARK: - Snapshot verification

    private func verifySnapshot(_ image: UIImage, name: String) throws {
        let url = Self.goldenURL(name)
        guard let png = image.pngData() else {
            Issue.record("pngData failed")
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // Missing goldens FAIL by default (CI must never auto-accept new
            // goldens). Only YUEDU_RECORD_GOLDENS=1 writes the golden — and it
            // still fails so the recorded file is consciously reviewed.
            let recording = ProcessInfo.processInfo.environment["YUEDU_RECORD_GOLDENS"] == "1"
            if recording {
                try png.write(to: url)
                Issue.record("recorded new golden \(name) — re-run without YUEDU_RECORD_GOLDENS to verify")
            } else {
                Issue.record("missing golden \(name) — set YUEDU_RECORD_GOLDENS=1 to record")
            }
            return
        }
        let goldenData = try Data(contentsOf: url)
        let golden = try #require(UIImage(data: goldenData))

        guard let current = image.cgImage, let expected = golden.cgImage,
              current.width == expected.width, current.height == expected.height else {
            Issue.record("snapshot \(name) size mismatch")
            return
        }
        let diff = Self.pixelDiffRatio(current, expected)
        #expect(diff <= 0.001, "snapshot \(name) differs: \(diff * 100)% pixels")
    }

    /// Fraction of pixels whose RGB differs beyond a small tolerance.
    private static func pixelDiffRatio(_ a: CGImage, _ b: CGImage) -> Double {
        let width = a.width
        let height = a.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bufA = [UInt8](repeating: 0, count: bytesPerRow * height)
        var bufB = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctxA = CGContext(data: &bufA, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow, space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let ctxB = CGContext(data: &bufB, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow, space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))

        var diffCount = 0
        var total = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * bytesPerPixel
                total += 1
                if abs(Int(bufA[i]) - Int(bufB[i])) > 8
                    || abs(Int(bufA[i + 1]) - Int(bufB[i + 1])) > 8
                    || abs(Int(bufA[i + 2]) - Int(bufB[i + 2])) > 8 {
                    diffCount += 1
                }
            }
        }
        return total > 0 ? Double(diffCount) / Double(total) : 0
    }
}
