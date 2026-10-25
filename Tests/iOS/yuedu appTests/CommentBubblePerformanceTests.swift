@testable import YueduCoreText
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
    nonisolated private static let prose = String(repeating: "風穿過山林，江水映著月光，行人仍沿著古道前進。", count: 5)

    @Test("OFF versus source, builtin, and artwork bubbles preserve prose and review links")
    func offOnMatrix() async throws {
        try await runMatrix(customSVG: Self.rasterSVG(), label: "synthetic")
    }

    nonisolated private static let jianghuPackPath = "/Users/zhangruilin/Downloads/自制- 江湖侠客.qitheme"

    @Test(
        "real Jianghu artwork supplements the self-contained OFF/ON comparison",
        .enabled(if: FileManager.default.fileExists(atPath: jianghuPackPath), "Needs ~/Downloads/自制- 江湖侠客.qitheme; the synthetic matrix remains authoritative")
    )
    func realJianghuMatrix() async throws {
        let url = URL(fileURLWithPath: Self.jianghuPackPath)
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

    @Test("unrecognized text-sized SVG image keeps its links and its untrimmed pixels")
    func unrecognizedTextSizedImageKeepsPixels() async throws {
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
        print("BUBBLE_PERF unrecognizedTextSized totalMs=\((SourcePerfTrace.now - start) * 1000) \(metrics.logDetail)")
        let expected = try #require(image.pngData())
        try Self.verify(output, hasBubbles: true, expectedImageData: expected)
    }

    /// Crashlytics dde5251b: the main thread spent ≥6.4 s tokenizing a bubble's path, every
    /// character read through `-[NSBigMutableString characterAtIndex:]` under CFStorage's lock.
    /// This replays a 段評-heavy 起點 chapter — 150 paragraphs, every count different, so every
    /// bubble misses the image cache and draws — once with native strings and once with the SVG
    /// arriving as an `NSTextStorage`-backed string (the class in that stack), alone and with
    /// four more chapters drawing the same bubble on background threads.
    @Test("起點-shaped chapter: native and NSTextStorage-bridged SVG, alone and contended", .timeLimit(.minutes(5)))
    func qidianShapedChapter() async throws {
        let global = GlobalSettings.shared
        let savedFollow = global.commentBubbleFollowsSourceSVG
        defer { global.commentBubbleFollowsSourceSVG = savedFollow }
        // Follow the source, so each bubble draws 起點's own outline path.
        global.commentBubbleFollowsSourceSVG = true

        let probe = NSTextStorage(string: Self.qidianSVG(count: 1, run: 0)).string
        print("BUBBLE_PERF qidian bridgedInputClass=\(NSStringFromClass(type(of: probe as NSString))) contiguousUTF8=\(probe.isContiguousUTF8)")
        try #require(!probe.isContiguousUTF8, "The bridged fixture must reproduce a foreign string")

        for bridged in [false, true] {
            for contended in [false, true] {
                let run = Self.nextQidianRun()
                let label = "input=\(bridged ? "textStorage" : "native") contended=\(contended)"
                let template = CommentBubbleSVGRecognizer.recognize(
                    src: "svg:",
                    svgContent: Self.qidianInput(count: 1, run: run, bridged: bridged)
                )
                guard case .path(let d, _, _, _, _)? = template?.elements.first(where: {
                    if case .path = $0 { return true }; return false
                }) else {
                    Issue.record("起點 fixture was not recognized as a bubble (\(label))")
                    return
                }
                print("BUBBLE_PERF qidian \(label) pathClass=\(NSStringFromClass(type(of: d as NSString))) pathContiguousUTF8=\(d.isContiguousUTF8) pathBytes=\(d.utf8.count)")

                let background: [Task<Double, Never>] = contended ? (1...4).map { worker in
                    let nodes = Self.qidianNodes(run: run, countBase: worker * 1000, bridged: bridged)
                    return Task.detached {
                        let renderer = NodeAttributedStringRenderer(config: .init(
                            from: Self.renderSettings, textColor: .black, renderWidth: 360
                        ))
                        let start = SourcePerfTrace.now
                        _ = await renderer.render(nodes)
                        return (SourcePerfTrace.now - start) * 1000
                    }
                } : []

                let renderer = NodeAttributedStringRenderer(config: .init(
                    from: Self.renderSettings, textColor: .black, renderWidth: 360
                ))
                let metrics = RenderLeafMetrics()
                let start = SourcePerfTrace.now
                let output = await ReaderDocumentTrace.$renderLeaves.withValue(metrics) {
                    await renderer.render(Self.qidianNodes(run: run, countBase: 0, bridged: bridged))
                }
                let elapsed = (SourcePerfTrace.now - start) * 1000
                var backgroundMs: [Double] = []
                for task in background { backgroundMs.append(await task.value) }
                print("BUBBLE_PERF qidian \(label) paragraphs=\(Self.qidianParagraphCount) totalMs=\(String(format: "%.1f", elapsed)) backgroundMs=\(backgroundMs.map { String(format: "%.0f", $0) }) \(metrics.logDetail)")
                try Self.verify(output, hasBubbles: true, paragraphCount: Self.qidianParagraphCount)
            }
        }
    }

    nonisolated private static let qidianParagraphCount = 150
    private static var qidianRun = 0

    /// A distinct `data-run` per measurement, so no run reuses another's parsed template:
    /// the bridged runs must parse their own (bridged) input, not hit the native run's cache.
    private static func nextQidianRun() -> Int {
        qidianRun += 1
        return qidianRun
    }

    nonisolated private static func qidianNodes(run: Int, countBase: Int, bridged: Bool) -> [RenderableNode] {
        (0..<qidianParagraphCount).map { index in
            let count = countBase + index + 1
            var style = RenderStyle.none
            style.isTextSizedImage = true
            let image: RenderableNode = bridged
                ? .image(src: "svg:", alt: String(count), style: style,
                         svgContent: qidianInput(count: count, run: run, bridged: true))
                : .image(src: "data:image/svg+xml;base64,"
                            + Data(qidianSVG(count: count, run: run).utf8).base64EncodedString(),
                         alt: String(count), style: style)
            return .paragraph([
                .text(prose),
                .anchor(href: href(index), children: [image])
            ], style: .body)
        }
    }

    nonisolated private static func qidianInput(count: Int, run: Int, bridged: Bool) -> String {
        let svg = qidianSVG(count: count, run: run)
        return bridged ? NSTextStorage(string: svg).string : svg
    }

    /// 起點's bubble shape: a 200×150 canvas around a 1300×1280 viewBox, one iconfont outline
    /// inside a transformed group, the count in a `<text>`.
    nonisolated private static func qidianSVG(count: Int, run: Int) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" data-run=\"\(run)\" width=\"200\" height=\"150\" viewBox=\"0 0 1300 1280\">"
            + "<g transform=\"rotate(180 650 640) scale(-1 1) translate(-1300 0)\">"
            + "<path d=\"\(qidianPathData)\" fill=\"#B3B3B3\"/></g>"
            + "<text x=\"650\" y=\"760\" font-size=\"420\" text-anchor=\"middle\" fill=\"#FFFFFF\">\(count)</text></svg>"
    }

    /// An iconfont-style outline about as long and number-dense as 起點's (~1.8k characters):
    /// a speech bubble traced in one-decimal cubic segments, with relative commands for the tail.
    nonisolated private static let qidianPathData: String = {
        let cx = 650.0, cy = 640.0, rx = 560.0, ry = 430.0
        let segments = 48
        var d = String(format: "M%.1f %.1f", cx + rx, cy)
        for s in 0..<segments {
            let a0 = Double(s) / Double(segments) * 2 * .pi
            let a1 = Double(s + 1) / Double(segments) * 2 * .pi
            let k = 4.0 / 3.0 * tan((a1 - a0) / 4)
            d += String(
                format: "C%.1f %.1f %.1f %.1f %.1f %.1f",
                cx + rx * cos(a0) - k * rx * sin(a0), cy + ry * sin(a0) + k * ry * cos(a0),
                cx + rx * cos(a1) + k * rx * sin(a1), cy + ry * sin(a1) - k * ry * cos(a1),
                cx + rx * cos(a1), cy + ry * sin(a1)
            )
        }
        return d + "M760 1060l-110 160-110-160Z"
    }()

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

    nonisolated private static func href(_ index: Int) -> String { "ydreview://fixture/\(index)" }

    private static func verify(
        _ output: NSAttributedString,
        hasBubbles: Bool,
        expectedImageData: Data? = nil,
        paragraphCount: Int = paragraphCount
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

    nonisolated private static var renderSettings: ReaderRenderSettings {
        ReaderRenderSettings(theme: "test", textColor: .black, backgroundColor: .white,
                             fontSize: 22, lineHeightMultiple: 1.4, lineSpacing: 0,
                             paragraphSpacing: 6, letterSpacing: 0, marginH: 0, marginV: 0,
                             footerHeight: 0, contentInsets: .zero, writingMode: .horizontal)
    }
}
