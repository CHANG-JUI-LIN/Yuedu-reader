import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// End-to-end coverage for 章節標題樣式 → 字體. Every one of these paths silently
/// ignored the picked title font before: the online HTML branch only typeset the
/// title when 高級 CSS was on, the EPUB `<h1>` branch never read the font at all,
/// and `titleFont` handed a Regular-only imported font to descriptor matching,
/// which returned a *system* face for the title's default bold weight.
@Suite("Chapter title font", .serialized)
@MainActor
struct ChapterTitleFontTests {

    // MARK: - Fixtures

    private static var ahemURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
    }

    /// Manual mode (高級 CSS off) — the only mode whose UI exposes the font
    /// pickers — with an explicit title font and no number/name split, so the
    /// title is a single locatable run.
    private static func titleStyle(postScriptName: String) -> ChapterTitleStyle {
        var style = ChapterTitleStyle.default
        style.advancedCSSEnabled = false
        style.followsBodyFont = false
        style.splitEnabled = false
        style.nameFontPostScript = postScriptName
        style.numberFontPostScript = postScriptName
        return style
    }

    private static func renderSettings(style: ChapterTitleStyle) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.6,
            lineSpacing: 10,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero,
            chapterTitleStyle: style
        )
    }

    private static func font(
        for text: String,
        in attributed: NSAttributedString
    ) throws -> UIFont {
        let range = try #require(attributed.string.range(of: text))
        let location = NSRange(range, in: attributed.string).location
        return try #require(attributed.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
    }

    // MARK: - Resolver

    @Test("bold title keeps a regular-only custom font instead of falling back to system")
    func boldTitleKeepsRegularOnlyCustomFont() throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        defer { UserFontStorageManager.shared.delete(imported) }

        // .bold is ChapterTitleStyle.default.weight, i.e. the case every user hits.
        let resolved = UserReaderFontResolver.titleFont(
            size: 28,
            weight: .bold,
            postScriptName: imported.postScriptName
        )

        #expect(resolved.familyName == imported.familyName)
        // Regular-only faces cannot supply the weight, so it must be synthesised
        // rather than swapped for another family.
        let synthetic = UserReaderFontResolver.syntheticBoldAttributes(
            for: resolved,
            isBoldRequested: true
        )
        let strokeWidth = try #require(synthetic[.strokeWidth] as? NSNumber)
        #expect(strokeWidth.doubleValue < 0)
    }

    @Test("a lighter title weight does not drag in the system face either")
    func lightTitleKeepsRegularOnlyCustomFont() throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        defer { UserFontStorageManager.shared.delete(imported) }

        let resolved = UserReaderFontResolver.titleFont(
            size: 28,
            weight: .light,
            postScriptName: imported.postScriptName
        )

        #expect(resolved.familyName == imported.familyName)
    }

    // MARK: - TXT

    @Test("TXT chapter title uses the picked title font")
    func txtChapterTitleUsesPickedFont() async throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        // The body-vs-title assertion below only means something when the reader
        // font is not already the imported one.
        let previousReaderFont = GlobalSettings.shared.selectedReaderFontPostScript
        GlobalSettings.shared.selectedReaderFontPostScript = nil
        defer {
            GlobalSettings.shared.selectedReaderFontPostScript = previousReaderFont
            UserFontStorageManager.shared.delete(imported)
        }

        let body = "第一段。\n第二段。"
        let builder = TXTLazyAttributedStringBuilder(
            text: body,
            chapterIndexes: [
                TXTChapterIndex(
                    index: 0,
                    title: "第一章 初見",
                    contentRange: NSRange(location: 0, length: (body as NSString).length)
                )
            ]
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(
                style: Self.titleStyle(postScriptName: imported.postScriptName)
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let titleFont = try Self.font(for: "第一章 初見", in: result.attributedString)
        #expect(titleFont.familyName == imported.familyName)
        // The body must keep the reader font, not inherit the title override.
        let bodyFont = try Self.font(for: "第一段。", in: result.attributedString)
        #expect(bodyFont.familyName != imported.familyName)
    }

    // MARK: - Online

    @Test("online HTML chapter title uses the picked title font without duplicating the source heading")
    func onlineHTMLChapterTitleUsesPickedFont() async throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        defer { UserFontStorageManager.shared.delete(imported) }

        let title = "第一章 初見"
        let payload = ChapterContentPayload(
            index: 0,
            title: title,
            plainText: "",
            body: .html("<h1>\(title)</h1><p>正文段落。</p>"),
            sourceHref: "https://example.com/chapter/1"
        )
        let builder = OnlineProviderAttributedStringBuilder(
            provider: StubChapterProvider(payload: payload),
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(
                style: Self.titleStyle(postScriptName: imported.postScriptName)
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let titleFont = try Self.font(for: title, in: result.attributedString)
        #expect(titleFont.familyName == imported.familyName)

        // The source's own <h1> must have been stripped — otherwise the reader
        // shows the chapter title twice.
        let occurrences = result.attributedString.string.components(separatedBy: title).count - 1
        #expect(occurrences == 1)
    }

    @Test("online plain-text chapter title uses the picked title font")
    func onlinePlainTextChapterTitleUsesPickedFont() async throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        defer { UserFontStorageManager.shared.delete(imported) }

        let title = "第一章 初見"
        let payload = ChapterContentPayload(
            index: 0,
            title: title,
            plainText: "正文段落。",
            body: .plainText("正文段落。"),
            sourceHref: "https://example.com/chapter/1"
        )
        let builder = OnlineProviderAttributedStringBuilder(
            provider: StubChapterProvider(payload: payload),
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(
                style: Self.titleStyle(postScriptName: imported.postScriptName)
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )

        let titleFont = try Self.font(for: title, in: result.attributedString)
        #expect(titleFont.familyName == imported.familyName)
    }

    // MARK: - EPUB <h1>

    @Test("EPUB h1 adopts an explicitly picked title font")
    func epubHeadingAdoptsExplicitTitleFont() async throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        defer { UserFontStorageManager.shared.delete(imported) }

        let title = "第一章 初見"
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: Self.renderSettings(
                    style: Self.titleStyle(postScriptName: imported.postScriptName)
                ),
                renderWidth: 320
            )
        )
        let rendered = await renderer.render([.heading([.text(title)], level: 1)])

        let titleFont = try Self.font(for: title, in: rendered)
        #expect(titleFont.familyName == imported.familyName)
    }

    @Test("EPUB h1 keeps the publisher's face when 跟隨閱讀字體 is on")
    func epubHeadingKeepsPublisherFaceByDefault() async throws {
        let imported = try UserFontStorageManager.shared.importFont(fileURL: Self.ahemURL)
        let previousReaderFont = GlobalSettings.shared.selectedReaderFontPostScript
        GlobalSettings.shared.selectedReaderFontPostScript = nil
        defer {
            GlobalSettings.shared.selectedReaderFontPostScript = previousReaderFont
            UserFontStorageManager.shared.delete(imported)
        }

        let title = "第一章 初見"
        // Default style: 跟隨閱讀字體 on → no explicit override, EPUB typography wins.
        var style = ChapterTitleStyle.default
        style.nameFontPostScript = imported.postScriptName
        style.followsBodyFont = true

        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: Self.renderSettings(style: style),
                renderWidth: 320
            )
        )
        let rendered = await renderer.render([.heading([.text(title)], level: 1)])

        let titleFont = try Self.font(for: title, in: rendered)
        #expect(titleFont.familyName != imported.familyName)
    }
}

private struct StubChapterProvider: BookContentProvider {
    let payload: ChapterContentPayload

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        index == payload.index ? payload.title : ""
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == payload.index else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}
