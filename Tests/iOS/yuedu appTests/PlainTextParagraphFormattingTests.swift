import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

private final class PlainTextParagraphProvider: BookContentProvider {
    let payload: ChapterContentPayload

    init(payload: ChapterContentPayload) {
        self.payload = payload
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        payload.title
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == 0 else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}

@Suite("Plain-text paragraph formatting", .serialized)
@MainActor
struct PlainTextParagraphFormattingTests {
    @Test("local TXT uses geometric first-line indent and preserves paragraph spacing")
    func localTXTUsesParagraphStyleIndent() async throws {
        let body = "第一段。\n第二段。"
        let builder = TXTLazyAttributedStringBuilder(
            text: body,
            chapterIndexes: [
                TXTChapterIndex(
                    index: 0,
                    title: "第一章",
                    contentRange: NSRange(location: 0, length: (body as NSString).length)
                )
            ]
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.settings,
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        )

        try Self.requireGeometricParagraphFormatting(in: result.attributedString)
    }

    @Test("online plain text uses the same geometric paragraph formatting")
    func onlinePlainTextUsesParagraphStyleIndent() async throws {
        let body = "第一段。\n第二段。"
        let payload = ChapterContentPayload(
            index: 0,
            title: "第一章",
            plainText: body,
            body: .plainText(body),
            sourceHref: "https://example.com/chapter/1"
        )
        let builder = OnlineProviderAttributedStringBuilder(
            provider: PlainTextParagraphProvider(payload: payload),
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.settings,
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        )

        try Self.requireGeometricParagraphFormatting(in: result.attributedString)
    }

    private static func requireGeometricParagraphFormatting(
        in attributed: NSAttributedString
    ) throws {
        let nsText = attributed.string as NSString
        let firstRange = nsText.range(of: "第一段。")
        let secondRange = nsText.range(of: "第二段。")
        try #require(firstRange.location != NSNotFound)
        try #require(secondRange.location != NSNotFound)

        #expect(!attributed.string.contains("\u{3000}\u{3000}"))

        for start in [firstRange.location, secondRange.location] {
            let paragraph = try #require(
                attributed.attribute(.paragraphStyle, at: start, effectiveRange: nil)
                    as? NSParagraphStyle
            )
            #expect(abs(paragraph.firstLineHeadIndent - settings.fontSize * 2) < 0.5)
            #expect(abs(paragraph.paragraphSpacing - settings.paragraphSpacing) < 0.5)
            #expect(paragraph.alignment == .justified)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            CGPath(rect: CGRect(x: 0, y: 0, width: 320, height: 640), transform: nil),
            nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)

        let firstLineIndex = try #require(
            lines.firstIndex { Self.contains(firstRange.location, in: CTLineGetStringRange($0)) }
        )
        let secondLineIndex = try #require(
            lines.firstIndex { Self.contains(secondRange.location, in: CTLineGetStringRange($0)) }
        )
        #expect(abs(origins[firstLineIndex].x - settings.fontSize * 2) < 0.5)
        #expect(abs(origins[secondLineIndex].x - settings.fontSize * 2) < 0.5)

        let baselineGap = origins[firstLineIndex].y - origins[secondLineIndex].y
        #expect(baselineGap > settings.fontSize * settings.lineHeightMultiple)
    }

    private static func contains(_ index: Int, in range: CFRange) -> Bool {
        index >= range.location && index < range.location + range.length
    }

    private static let settings = ReaderRenderSettings(
        theme: "test",
        textColor: .label,
        backgroundColor: .systemBackground,
        fontSize: 18,
        lineHeightMultiple: 1.4,
        lineSpacing: 0,
        paragraphSpacing: 12.6,
        letterSpacing: 0.8,
        marginH: 0,
        marginV: 0,
        footerHeight: 0,
        contentInsets: .zero,
        writingMode: .horizontal
    )
}
