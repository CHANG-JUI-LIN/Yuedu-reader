import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// 段首縮排 and 對齊 as reading settings (2026-11-21): stored with the reading setup, worn
/// through the one writer, and baked into the paragraphs the reader sets itself.
@Suite("段首縮排與對齊", .serialized)
@MainActor
struct ReaderIndentAlignmentSettingsTests {
    // MARK: - The reading setup

    @Test func eachIsItsOwnScopeRow() {
        var indent = AppearanceThemeReadingSettings()
        indent.firstLineIndent = 1
        #expect(indent.items == [.firstLineIndent])

        var alignment = AppearanceThemeReadingSettings()
        alignment.textAlignment = ReaderBodyTextAlignment.start.rawValue
        #expect(alignment.items == [.textAlignment])

        #expect(indent.overlaid(with: alignment).items == [.firstLineIndent, .textAlignment])
        #expect(indent.restricted(to: [.textAlignment]).isEmpty)
    }

    @Test func theyTravelInAStoredSetup() throws {
        var reading = AppearanceThemeReadingSettings()
        reading.firstLineIndent = 0.5
        reading.textAlignment = ReaderBodyTextAlignment.start.rawValue
        let decoded = try JSONDecoder().decode(
            AppearanceThemeReadingSettings.self, from: JSONEncoder().encode(reading))
        #expect(decoded == reading)
    }

    /// A setup written before these settings says nothing about them, so wearing it
    /// leaves the reader's own values alone.
    @Test func anOlderSetupLeavesThemAlone() throws {
        let decoded = try JSONDecoder().decode(
            AppearanceThemeReadingSettings.self, from: Data(#"{"fontSize": 20}"#.utf8))
        #expect(decoded.firstLineIndent == nil)
        #expect(decoded.textAlignment == nil)
    }

    @Test func anEditIsRecordedAndASetupIsWorn() throws {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let indent = settings.readerFirstLineIndent
        let alignment = settings.readerTextAlignment
        defer {
            settings.readerFirstLineIndent = indent
            settings.readerTextAlignment = alignment
            stores.restore()
        }

        settings.readerFirstLineIndent = 1
        settings.readerTextAlignment = .start
        let snapshot = settings.currentReadingSettingsSnapshot()
        #expect(snapshot.firstLineIndent == 1)
        #expect(snapshot.textAlignment == "start")

        var worn = AppearanceThemeReadingSettings()
        // Out of the slider's range, as a hand-edited pack could carry it.
        worn.firstLineIndent = 40
        worn.textAlignment = ReaderBodyTextAlignment.justified.rawValue
        try settings.writeReadingSettings(worn, origin: .theme)
        #expect(settings.readerFirstLineIndent == ReaderFirstLineIndent.range.upperBound)
        #expect(settings.readerTextAlignment == .justified)

        // A value this build does not know is not worn.
        var unknown = AppearanceThemeReadingSettings()
        unknown.textAlignment = "sideways"
        try settings.writeReadingSettings(unknown, origin: .theme)
        #expect(settings.readerTextAlignment == .justified)
    }

    // MARK: - Layout

    @Test func aChangeOfEitherRelaysTheChapterOut() {
        let base = EPUBTestFixtures.renderSettings()
        var indented = base
        indented.firstLineIndentEm = 0
        var ragged = base
        ragged.bodyTextAlignment = .start
        #expect(indented != base)
        #expect(ragged != base)
    }

    @Test(arguments: [0.0, 1.0, 2.0])
    func aTXTParagraphIsIndentedByTheSetting(em: Double) async throws {
        var settings = EPUBTestFixtures.renderSettings(fontSize: 20)
        settings.firstLineIndentEm = em
        let style = try await Self.txtBodyParagraphStyle(settings)
        // Spelled out: inside `#expect`, `CGFloat == 20 * em` picked an overload that
        // compared unequal for equal values.
        let indent: CGFloat = style.firstLineHeadIndent
        let expected = CGFloat(20 * em)
        #expect(indent == expected)
        #expect(style.headIndent == 0)
        #expect(style.alignment == .justified)
    }

    @Test func aTXTParagraphIsRaggedWhenAskedTo() async throws {
        var settings = EPUBTestFixtures.renderSettings()
        settings.bodyTextAlignment = .start
        let style = try await Self.txtBodyParagraphStyle(settings)
        #expect(style.alignment == .natural)
    }

    /// The node renderer sets every other format's paragraphs; one with no `text-align`
    /// of its own takes the setting, one with its own keeps it.
    @Test func theNodeRendererFollowsTheSettingOnlyWhereTheContentSaysNothing() async throws {
        var settings = EPUBTestFixtures.renderSettings()
        settings.bodyTextAlignment = .start
        let chapter = UnifiedChapter(
            index: 0, title: "一", paragraphs: ["第一段的文字。", "第二段的文字。"], sourceHref: nil)
        let builder = NodeAttributedStringBuilder(chapters: [chapter])
        let result = try await builder.buildChapter(
            at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
        let text = result.attributedString
        let location = (text.string as NSString).range(of: "第二段").location
        let style = try #require(
            text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.alignment == .natural)
        #expect(style.firstLineHeadIndent == settings.fontSize * 2)
    }

    private static func txtBodyParagraphStyle(_ settings: ReaderRenderSettings) async throws -> NSParagraphStyle {
        let raw = "第一章\n這是第一段的文字。\n這是第二段的文字。\n"
        let file = TXTMappedTextFile(data: Data(raw.utf8), encoding: .utf8)
        let indexes = [TXTMappedChapterIndex(index: 0, title: "第一章", byteRange: 0..<file.byteCount)]
        let builder = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: indexes)
        let text = try await builder.buildChapter(
            at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white
        ).attributedString
        let location = (text.string as NSString).range(of: "這是第二段").location
        #expect(location != NSNotFound)
        return try #require(
            text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
    }
}
