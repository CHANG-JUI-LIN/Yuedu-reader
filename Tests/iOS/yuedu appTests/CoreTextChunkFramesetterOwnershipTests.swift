import CoreText
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// Core Text layout objects (CTFramesetter, CTTypesetter, CTFrame, CTLine, CTRun)
/// are used by one operation, queue or thread at a time. A chapter's chunks share
/// one framesetter, owned by the main thread after slicing.
@Suite(.serialized)
@MainActor
struct CoreTextChunkFramesetterOwnershipTests {
    /// The two ways to stop sharing, measured before choosing (ABBA order):
    /// A. serialize every use of the chapter's framesetter — the main thread would
    ///    wait as long as one background frame build holds it;
    /// B. give the off-main warm its own framesetter from the slicer's factory —
    ///    it pays the framesetter creation and a cold first frame, off the main thread.
    @Test func measureFramesetterOwnershipOptions() {
        var samples: [String: [Double]] = [:]
        for (name, text) in [("txt", Self.txtChapter()), ("styled", Self.styledChapter())] {
            for order in [[true, false], [false, true], [true, false], [false, true]] {
                for shared in order {
                    let chunks = CoreTextChunkSlicer.slice(attributedString: text, chapterIndex: 0,
                                                           contentWidth: 360).chunks
                    if shared {
                        for chunk in chunks {
                            let start = SourcePerfTrace.now
                            _ = chunk.makeFrame(using: chunk.framesetter)
                            samples["\(name).A.sharedFrameHold", default: []].append((SourcePerfTrace.now - start) * 1000)
                        }
                    } else {
                        let start = SourcePerfTrace.now
                        let own = CoreTextFramesetterFactory.make(for: text)
                        samples["\(name).B.framesetterCreate", default: []].append((SourcePerfTrace.now - start) * 1000)
                        for (index, chunk) in chunks.enumerated() {
                            let frameStart = SourcePerfTrace.now
                            _ = chunk.makeFrame(using: own)
                            samples["\(name).B.\(index == 0 ? "firstFrame" : "laterFrame")", default: []]
                                .append((SourcePerfTrace.now - frameStart) * 1000)
                        }
                    }
                }
            }
            let chars = text.length
            SourcePerfTrace.record("test.scroll.framesetterOwnership", "fixture=\(name) chars=\(chars)",
                                   since: SourcePerfTrace.now, thresholdMs: 0)
        }
        #expect(!samples.isEmpty)
        for key in samples.keys.sorted() {
            let values = samples[key]!.sorted()
            print("[FramesetterOwnership] \(key) n=\(values.count) medianMs=\(values[values.count / 2]) maxMs=\(values.last!)")
        }
    }

    /// The engine's off-main warm and main-thread materialization of the same
    /// chapter's chunks, at the same time: the warm lays out with a framesetter its
    /// executor owns, never the chapter's shared one.
    @Test func engineWarmNeverSharesTheChaptersFramesetter() async throws {
        let engine = CoreTextScrollEngine(builder: OwnershipTestBuilder(), renderSettings: Self.renderSettings)
        await engine.start(initialChapter: 0, contentWidth: 220)
        let chunks = engine.chunks.compactMap(\.legacyChunk).filter { $0.chapterIndex == 0 }
        #expect(chunks.count >= 6)
        let shared = ObjectIdentifier(try #require(chunks.first).framesetter)
        #expect(chunks.allSatisfy { ObjectIdentifier($0.framesetter) == shared })
        chunks.forEach { $0.evictFrame() }
        let warm = try #require(engine.warmChunksAhead(around: 1, radius: 1))
        // Meanwhile the main thread lays out other chunks with the shared framesetter.
        for chunk in chunks.suffix(3) { chunk.materializeFrameIfNeeded() }
        await warm.value
        #expect(chunks.prefix(3).allSatisfy { $0.isMaterialized })
        let owned = try #require(await engine.frameWarmer.framesetterIdentity(for: chunks[0].attributedString))
        #expect(owned != shared, "the off-main warm must not lay out with the chapter's shared framesetter")
    }

    /// Frames from the warm executor's own framesetter and from the shared one are
    /// the slicer's frames: same line ranges, origins and pixels.
    @Test func warmedAndMaterializedFramesMatchTheSlicersLinesAndPixels() async throws {
        for text in [Self.txtChapter(), Self.styledChapter()] {
            let chunks = CoreTextChunkSlicer.slice(attributedString: text, chapterIndex: 0, contentWidth: 360).chunks
            #expect(chunks.count > 2)
            let warmer = CoreTextFrameWarmer()
            for chunk in chunks {
                let sliced = try Self.lineGeometry(chunk)
                let slicedPixels = Self.render(chunk)
                chunk.evictFrame()
                let built = try #require(await warmer.buildFrameData(for: chunk))
                chunk.applyBuiltFrame(built)
                #expect(try Self.lineGeometry(chunk) == sliced, "off-main warm, offset \(chunk.charRange.location)")
                #expect(Self.render(chunk) == slicedPixels, "off-main warm, offset \(chunk.charRange.location)")
                chunk.evictFrame()
                chunk.materializeFrameIfNeeded()
                #expect(try Self.lineGeometry(chunk) == sliced, "main materialize, offset \(chunk.charRange.location)")
                #expect(Self.render(chunk) == slicedPixels, "main materialize, offset \(chunk.charRange.location)")
            }
            let owned = try #require(await warmer.framesetterIdentity(for: LayoutShared(text).wrappedValue))
            #expect(owned != ObjectIdentifier(try #require(chunks.first).framesetter))
        }
    }

    /// Every line's string range and origin, as comparable text.
    private static func lineGeometry(_ chunk: CoreTextChunk) throws -> [String] {
        let frame = try #require(chunk.frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        return zip(lines, origins).map { line, origin in
            let range = CTLineGetStringRange(line)
            return "\(range.location)+\(range.length)@\(origin.x),\(origin.y)"
        }
    }

    private static func render(_ chunk: CoreTextChunk) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let bounds = CGRect(x: 0, y: 0, width: chunk.width, height: chunk.height)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).pngData { _ in
            CoreTextChunkDrawView.draw(chunk, bounds: bounds)
        }
    }

    private static let renderSettings = ReaderRenderSettings(
        theme: "test", textColor: .black, backgroundColor: .white, fontSize: 18,
        lineHeightMultiple: 1.0, lineSpacing: 0, paragraphSpacing: 0, letterSpacing: 0,
        marginH: 0, marginV: 0, footerHeight: 0, contentInsets: .zero)

    private struct OwnershipTestBuilder: AttributedStringBuilding {
        var chapterCount: Int { 1 }
        func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
        func chapterSourceHref(at index: Int) -> String? { "chapter-\(index).xhtml" }
        func chapterDataSize(at index: Int) async -> Int { 0 }
        func chapterIndex(for href: String) -> Int? { nil }
        func cssResourceHrefs() -> [String] { [] }
        func buildChapter(at index: Int, settings: ReaderRenderSettings, themeTextColor: UIColor,
                          themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
            AttributedChapterBuildResult(attributedString: CoreTextChunkFramesetterOwnershipTests.txtChapter(),
                imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
        }
    }

    /// TXT-shaped: plain paragraphs of varied CJK text at a reading size.
    nonisolated static func txtChapter() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.lineSpacing = 8
        paragraph.paragraphSpacing = 10
        paragraph.firstLineHeadIndent = 40
        let text = (0..<60).map { row -> String in
            let body = String(String.UnicodeScalarView((0..<(30 + row % 40)).compactMap {
                UnicodeScalar(0x4E00 + (row * 97 + $0 * 13) % 0x5000)
            }))
            return body + "，「對話」。"
        }.joined(separator: "\n")
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black, .paragraphStyle: paragraph
        ])
    }

    /// Mixed scripts, emoji, inline box, italic, shadow and underline.
    nonisolated static func styledChapter() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 11
        let text = (0..<45).map { i in
            "段落\(i) " + String(repeating: "繁體中文 office affinity 👩🏽‍💻 é，細小滑動。", count: 3 + i % 5)
        }.joined(separator: "\n")
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 23), .foregroundColor: UIColor.black, .paragraphStyle: paragraph
        ])
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 2, height: 6)
        shadow.shadowBlurRadius = 3
        shadow.shadowColor = UIColor.gray
        string.addAttribute(HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
            value: HTMLAttributedStringBuilder.InlineBorderBoxStyle(borderColor: .blue,
                borderWidth: 5, cornerRadius: 4, fillColor: .yellow,
                paddingHorizontal: 3, paddingVertical: 40),
            range: NSRange(location: 35, length: 500))
        string.addAttributes([.font: UIFont.italicSystemFont(ofSize: 29), .shadow: shadow,
                              .underlineStyle: NSUnderlineStyle.single.rawValue],
                             range: NSRange(location: 35, length: 250))
        return string
    }
}
