import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// OFF/ON comparisons share identical prose, paragraph geometry and link targets. No network.
/// These tests report elapsed work; semantic assertions, rather than machine-specific deadlines,
/// protect the result. The real theme supplements the always-available deterministic fixture.
@Suite("Comment bubble performance", .serialized)
@MainActor
struct CommentBubblePerformanceTests {
    private static let paragraphCount = 120
    private static let prose = String(repeating: "風穿過山林，江水映著月光，行人仍沿著古道前進。", count: 5)

    @Test("OFF versus source, builtin, and artwork bubbles preserve prose and review links")
    func offOnMatrix() async throws {
        try await runMatrix(customSVG: Self.rasterSVG(), label: "synthetic")
    }

    @Test("real Jianghu artwork supplements the self-contained OFF/ON comparison")
    func realJianghuMatrix() async throws {
        let url = URL(fileURLWithPath: "/Users/zhangruilin/Downloads/自制- 江湖侠客.qitheme")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("BUBBLE_PERF realJianghu unavailable; synthetic matrix remains authoritative")
            return
        }
        let result = try await QiThemeImporter.parse(Data(contentsOf: url))
        let bubble = try #require(result.bubble)
        try await runMatrix(customSVG: bubble.style.svg, label: "realJianghu")
    }

    @Test("native count markers retain distinct counts")
    func commentMarkerCountsRemainDistinct() throws {
        let global = GlobalSettings.shared
        let savedMode = global.commentBubblePresetMode
        let savedFollow = global.commentBubbleFollowsSourceSVG
        defer {
            global.commentBubblePresetMode = savedMode
            global.commentBubbleFollowsSourceSVG = savedFollow
        }
        global.commentBubblePresetMode = .builtin
        global.commentBubbleFollowsSourceSVG = false
        let first = try #require(CommentBubbleSVGRecognizer.commentBadgeImage(
            count: "12", pointSize: 22, themeTextColor: .black
        ))
        let second = try #require(CommentBubbleSVGRecognizer.commentBadgeImage(
            count: "99", pointSize: 22, themeTextColor: .black
        ))
        #expect(first.pngData() != second.pngData())
    }

    @Test("custom color tokens preserve day, night, and emphasis palettes")
    func customColorTokensPreservePalettes() throws {
        let global = GlobalSettings.shared
        let saved = (global.commentBubbleFollowsSourceSVG, global.commentBubblePresetMode,
                     global.commentBubbleCustomStyles, global.commentBubbleSelectedCustomStyleID)
        defer {
            global.applyCommentBubbleSync(styles: saved.2)
            global.applyCommentBubbleSync(selection: saved.3)
            global.commentBubblePresetMode = saved.1
            global.commentBubbleFollowsSourceSVG = saved.0
        }
        global.commentBubbleFollowsSourceSVG = false
        for token in ["${color}", "${Color}"] {
            let style = ReaderCommentBubbleCustomStyle(
                name: "Color fixture",
                svg: "<svg width='96' height='72' viewBox='0 0 96 72'><rect x='0' y='0' width='96' height='72' fill='\(token)'/></svg>",
                dayEmphasisColor: "#0000FF", dayNormalColor: "#FF0000",
                nightEmphasisColor: "#FFFF00", nightNormalColor: "#00FF00"
            )
            global.applyCommentBubbleSync(styles: saved.2 + [style])
            global.applyCommentBubbleSync(selection: style.id)
            let cases: [(String, UIColor, [UInt8])] = [
                ("12", .black, [255, 0, 0, 255]),
                ("120", .black, [0, 0, 255, 255]),
                ("12", .white, [0, 255, 0, 255]),
                ("120", .white, [255, 255, 0, 255])
            ]
            for (count, textColor, expected) in cases {
                let image = try #require(CommentBubbleSVGRecognizer.commentBadgeImage(
                    count: count, pointSize: 22, themeTextColor: textColor
                ))
                let cgImage = try #require(image.cgImage)
                var pixel = [UInt8](repeating: 0, count: 4)
                try pixel.withUnsafeMutableBytes { bytes in
                    let context = try #require(CGContext(
                        data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                    ))
                    context.interpolationQuality = .none
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                #expect(pixel == expected)
            }
        }
    }

    @Test("unrecognized text-sized SVG image trims preserve links and pixels")
    func diagnosticTrimComparison() async throws {
        let image = try Self.rasterImage()
        let renderer = NodeAttributedStringRenderer(config: .init(
            from: Self.renderSettings, textColor: .black, renderWidth: 360,
            imageLoader: { _ in image }
        ))
        var style = RenderStyle.none
        style.isTextSizedImage = true
        let nodes = (0..<Self.paragraphCount).map { index in
            RenderableNode.paragraph([
                .text(Self.prose),
                .anchor(href: Self.href(index), children: [
                    .image(src: "fixture-svg-\(index)", alt: "review", style: style)
                ])
            ], style: .body)
        }
        let metrics = RenderLeafMetrics()
        let start = SourcePerfTrace.now
        let output = await ReaderDocumentTrace.$renderLeaves.withValue(metrics) {
            await renderer.render(nodes)
        }
        print("BUBBLE_PERF diagnosticTrim totalMs=\((SourcePerfTrace.now - start) * 1000) \(metrics.logDetail)")
        let expected = try #require(image.trimmingTransparentPixels()?.pngData())
        try Self.verify(output, hasBubbles: true, expectedImageData: expected)
    }

    private func runMatrix(customSVG: String, label: String) async throws {
        let global = GlobalSettings.shared
        let saved = (
            global.commentBubbleFollowsSourceSVG, global.commentBubblePresetMode,
            global.commentBubbleCustomStyles, global.commentBubbleSelectedCustomStyleID,
            global.commentBubbleScale, global.commentBubbleTextScale
        )
        defer {
            global.applyCommentBubbleSync(styles: saved.2)
            global.applyCommentBubbleSync(selection: saved.3)
            global.commentBubblePresetMode = saved.1
            global.commentBubbleFollowsSourceSVG = saved.0
            global.commentBubbleScale = saved.4
            global.commentBubbleTextScale = saved.5
        }
        let custom = ReaderCommentBubbleCustomStyle(name: "Performance fixture", svg: customSVG)
        global.applyCommentBubbleSync(styles: saved.2 + [custom])
        global.commentBubbleScale = 1.7
        global.commentBubbleTextScale = 0.3
        for mode in ["off", "source", "builtinClean", "builtinRetainedCustom", "custom"] {
            global.commentBubbleFollowsSourceSVG = mode == "source"
            // Clearing a synced custom selection is intentionally accepted only while
            // custom mode is active. Pin that precondition so the clean case is truly clean.
            global.commentBubblePresetMode = .custom
            global.applyCommentBubbleSync(selection: mode == "builtinClean" ? nil : custom.id)
            global.commentBubblePresetMode = mode == "custom" ? .custom : .builtin
            #expect((global.commentBubbleSelectedCustomStyleID == nil) == (mode == "builtinClean"))
            let nodes = Self.nodes(mode: mode)
            // First encounter and subsequent encounters are reported separately. Reopening a
            // chapter legitimately uses existing caches, so neither result substitutes for the other.
            for pass in 0..<3 {
                let renderer = NodeAttributedStringRenderer(config: .init(
                    from: Self.renderSettings, textColor: .black, renderWidth: 360
                ))
                let metrics = RenderLeafMetrics()
                let start = SourcePerfTrace.now
                let output = await ReaderDocumentTrace.$renderLeaves.withValue(metrics) {
                    await renderer.render(nodes)
                }
                let elapsed = (SourcePerfTrace.now - start) * 1000
                print("BUBBLE_PERF \(label) mode=\(mode) pass=\(pass) paragraphs=\(Self.paragraphCount) totalMs=\(elapsed) \(metrics.logDetail)")
                SourcePerfTrace.record("test.commentBubble.matrix", "fixture=\(label) mode=\(mode) pass=\(pass)", since: start, thresholdMs: 0)
                try Self.verify(output, hasBubbles: mode != "off")
            }
        }
    }

    private static func nodes(mode: String) -> [RenderableNode] {
        (0..<paragraphCount).map { index in
            var children: [RenderableNode] = [.text(prose)]
            if mode != "off" {
                // All counts differ, exercising the cold path as well as later cache hits.
                let count = String(index + 1)
                let svg = CommentBubbleSVGRecognizer.builtinBubbleSVG
                    .replacingOccurrences(of: ">0</text>", with: ">\(count)</text>")
                let source = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
                var style = RenderStyle.none
                style.isTextSizedImage = true
                children.append(.anchor(href: href(index), children: [
                    .image(src: source, alt: count, style: style)
                ]))
            }
            return .paragraph(children, style: .body)
        }
    }

    private static func href(_ index: Int) -> String { "ydreview://fixture/\(index)" }

    private static func verify(
        _ output: NSAttributedString,
        hasBubbles: Bool,
        expectedImageData: Data? = nil
    ) throws {
        #expect(output.string.components(separatedBy: prose).count - 1 == paragraphCount)
        var links: [String] = []
        var attachments = 0
        let range = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(HTMLAttributedStringBuilder.internalLinkAttribute, in: range) { value, _, _ in
            if let href = value as? String { links.append(href) }
        }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        output.enumerateAttribute(delegateKey, in: range) { value, _, _ in
            guard let value else { return }
            let info = Unmanaged<ImageRunInfo>.fromOpaque(
                CTRunDelegateGetRefCon(value as! CTRunDelegate)
            ).takeUnretainedValue()
            #expect(info.image != nil)
            if let expectedImageData {
                #expect(info.image?.pngData() == expectedImageData)
            }
            attachments += 1
        }
        #expect(links == (hasBubbles ? (0..<paragraphCount).map(href) : []))
        #expect(attachments == (hasBubbles ? paragraphCount : 0))
    }

    private static func rasterImage() throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 270, height: 360), format: format)
        return renderer.image { context in
            // Fixed arithmetic noise keeps PNG decode work reproducible across runs.
            for x in stride(from: 8, to: 262, by: 2) {
                for y in stride(from: 8, to: 352, by: 2) {
                    UIColor(red: CGFloat((x * 73 + y * 19) % 256) / 255,
                            green: CGFloat((x * 29 + y * 67) % 256) / 255,
                            blue: CGFloat((x * 11 + y * 43) % 256) / 255,
                            alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
    }

    private static func rasterSVG() throws -> String {
        let data = try #require(rasterImage().pngData())
        return "<svg xmlns='http://www.w3.org/2000/svg' width='90' height='120' viewBox='0 0 90 120'><image href='data:image/png;base64,"
            + data.base64EncodedString() + "' width='90' height='120'/></svg>"
    }

    private static var renderSettings: ReaderRenderSettings {
        ReaderRenderSettings(theme: "test", textColor: .black, backgroundColor: .white,
                             fontSize: 22, lineHeightMultiple: 1.4, lineSpacing: 0,
                             paragraphSpacing: 6, letterSpacing: 0, marginH: 0, marginV: 0,
                             footerHeight: 0, contentInsets: .zero, writingMode: .horizontal)
    }
}
