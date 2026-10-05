import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

@MainActor
@Suite(.serialized)
struct AozoraTXTTests {
    @Test("explicit and implicit ruby share the existing annotation path", arguments: [false, true])
    func rubyInBothTXTBuilders(mapped: Bool) async throws {
        let source = "前。｜漢字《かんじ》、東京《とうきょう》を読む。"
        let attributed = try await build(source, mapped: mapped)
        #expect(attributed.string.hasSuffix("前。漢字、東京を読む。\n"))
        try expectRuby("かんじ", base: "漢字", in: attributed)
        try expectRuby("とうきょう", base: "東京", in: attributed)
        let ns = attributed.string as NSString
        let before = ns.range(of: "前。")
        #expect(attributed.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                                     at: before.location, effectiveRange: nil) == nil)
    }

    @Test("the explicit marker permits kana and Latin base text")
    func explicitNonKanjiBase() async throws {
        let attributed = try await build("｜Alice《アリス》と｜ひと《人》。")
        #expect(attributed.string.hasSuffix("Aliceとひと。\n"))
        try expectRuby("アリス", base: "Alice", in: attributed)
        try expectRuby("人", base: "ひと", in: attributed)
    }

    @Test("implicit ruby stops at kana and includes supplementary Han and iteration marks")
    func implicitRangeAndUTF16() async throws {
        let attributed = try await build("の𠮷野《よしの》、日々《ひび》。")
        try expectRuby("よしの", base: "𠮷野", in: attributed)
        try expectRuby("ひび", base: "日々", in: attributed)
        let range = (attributed.string as NSString).range(of: "𠮷野")
        #expect(range.length == 3)
    }

    @Test("all Aozora editorial notes disappear, including multiline notes")
    func stripsAllEditorialNotes() async throws {
        let attributed = try await build("前。［＃大きな文字］中。［＃傍点\n続き］後。［＃改ページ］")
        #expect(attributed.string.hasSuffix("前。中。後。\n"))
        #expect(!attributed.string.contains("［＃"))
        #expect(!attributed.string.contains("傍点"))
    }

    @Test("ordinary brackets and incomplete ruby remain literal")
    func literalBracketsRemain() async throws {
        let source = "かな《かな》、漢字《途中、｜未完成、［普通の括弧］。"
        #expect(try await build(source).string.hasSuffix(source + "\n"))
    }

    @Test("ruby is preserved across the fixed encoding sample boundary")
    func rubyAcrossSampleBoundary() async throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        let line = try #require("私は本を読みます。\n".data(using: encoding))
        var data = Data()
        while data.count + line.count < 512 * 1024 - 3 { data.append(line) }
        data.append(Data(repeating: 0x61, count: 512 * 1024 - 3 - data.count))
        data.append(try #require("｜漢字《かんじ》を読む。\n".data(using: encoding)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try TXTFileReader.readMappedTextFile(url: url)
        #expect(file.encoding == encoding)
        let indexes = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Boundary")
        let index = try #require(indexes.firstIndex { $0.byteRange.contains(512 * 1024) })
        let builder = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: indexes)
        let result = try await builder.buildChapter(at: index, settings: EPUBTestFixtures.renderSettings(),
                                                    themeTextColor: .label, themeBackgroundColor: .systemBackground)
        try expectRuby("かんじ", base: "漢字", in: result.attributedString)
        #expect(!result.attributedString.string.contains("《かんじ》"))
    }

    @Test("removed markup remaps UTF-16 reading offsets within the same chapter")
    func markupLocationMigration() throws {
        let raw = "前。｜漢字《かんじ》、［＃改ページ］後文𠮷。\n"
        let displayed = "前。漢字、後文𠮷。\n"
        let file = TXTMappedTextFile(data: Data(raw.utf8), encoding: .utf8)
        let indexes = [TXTMappedChapterIndex(index: 0, title: "Title", byteRange: 0..<file.byteCount)]
        let mapping = try TXTLocationMigration(file: file, oldIndexes: indexes, newIndexes: indexes)
        let oldRendered = "Title\n" + raw
        let newRendered = "Title\n" + displayed
        let oldRange = (oldRendered as NSString).range(of: "後文𠮷")
        let newRange = (newRendered as NSString).range(of: "後文𠮷")
        for delta in [0, oldRange.length] {
            let result = try mapping.map(.init(spineIndex: 0, charOffset: oldRange.location + delta),
                                         oldRendered: oldRendered, newRendered: newRendered)
            #expect(result == .init(spineIndex: 0, charOffset: newRange.location + delta))
        }
    }

    @Test("ruby paragraphs reserve room for annotation in both writing modes", arguments: [
        ReaderWritingMode.horizontal, .verticalRTL,
    ])
    func annotationLineHeight(mode: ReaderWritingMode) async throws {
        let attributed = try await build("｜漢字《かんじ》を読む。", mode: mode)
        let range = (attributed.string as NSString).range(of: "漢字")
        try expectRuby("かんじ", base: "漢字", in: attributed)
        let style = try #require(attributed.attribute(.paragraphStyle, at: range.location,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.maximumLineHeight == 0)
    }

    @Test("Chinese book-title brackets are preserved", arguments: [
        "功法《九陽神功》", "功法《九陽・神功》",
    ])
    func chineseBookTitlesRemain(source: String) async throws {
        let attributed = try await build(source)
        #expect(attributed.string.hasSuffix(source + "\n"))
    }

    @Test("halfwidth Japanese kana also identifies implicit ruby")
    func halfwidthKanaReading() async throws {
        let attributed = try await build("漢字《ｶﾝｼﾞ》。")
        #expect(attributed.string.hasSuffix("漢字。\n"))
        try expectRuby("ｶﾝｼﾞ", base: "漢字", in: attributed)
    }

    @Test("v6 stored reading position and highlight migrate exactly once", arguments: [false, true])
    func storedV6LocationsMigrateOnce(interrupt: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "第1章 初め\n前。｜漢字《かんじ》、［＃大きな文字］後文𠮷。\n"
        let data = Data(text.utf8)
        let url = directory.appendingPathComponent("book.txt")
        try data.write(to: url)
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.txt")
        let file = TXTMappedTextFile(data: data, encoding: .utf8)
        let indexes = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: book.title)
        let settings = EPUBTestFixtures.renderSettings()
        let legacy = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: indexes, parsesAozoraMarkup: false)
        let old = try await legacy.buildChapter(at: 0, settings: settings, themeTextColor: .label,
                                                 themeBackgroundColor: .systemBackground).attributedString.string as NSString
        let oldRange = old.range(of: "後文𠮷")
        let position = CoreTextReadingPosition(spineIndex: 0, charOffset: oldRange.location)
        let bookmark = Bookmark(chapterIndex: 0, chapterTitle: indexes[0].title, position: position,
                                length: oldRange.length, kind: .highlight, note: "Keep note", excerpt: "後文𠮷")
        book.bookmarks = [bookmark]
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        store.replaceBooksFromSync([book])
        let positions = Positions(position)
        let cache = StorageLocations.txtChapterCache.appendingPathComponent("\(book.id.uuidString).json")
        let journal = StorageLocations.readingPosition.appendingPathComponent("\(book.id.uuidString).txt-reindex.json")
        defer {
            TXTChapterParser.deleteCachedIndexes(bookId: book.id)
            try? FileManager.default.removeItem(at: journal)
        }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = indexes.map { ["index": $0.index, "title": $0.title,
                                     "lower": $0.byteRange.lowerBound, "upper": $0.byteRange.upperBound] as [String: Any] }
        try JSONSerialization.data(withJSONObject: [
            "version": 6, "fileSize": data.count, "fingerprint": TXTFileReader.fileFingerprint(data: data),
            "encodingRawValue": String.Encoding.utf8.rawValue, "indexes": entries,
        ]).write(to: cache)
        let prepared = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title)
        #expect(prepared.previousChapterIndexes == indexes)
        if interrupt {
            let originalCache = try Data(contentsOf: cache)
            positions.failWrites = true
            do {
                _ = try await TXTReaderIndexMigrationService.complete(prepared, store: store,
                                                                      positions: positions, settings: settings)
                Issue.record("Expected failed position persistence")
            } catch TXTLocationMigration.Failure.invalidPosition {}
            let currentJournal = try Data(contentsOf: journal)
            var legacyJournal = try #require(JSONSerialization.jsonObject(with: currentJournal) as? [String: Any])
            legacyJournal["version"] = 1
            let ambiguousJournal = try JSONSerialization.data(withJSONObject: legacyJournal)
            try ambiguousJournal.write(to: journal)
            let beforeReplay = store.readingBook(id: book.id)?.bookmarks
            do {
                _ = try await TXTReaderIndexMigrationService.complete(prepared, store: store,
                                                                      positions: positions, settings: settings)
                Issue.record("Pre-ruby journal must not publish ambiguous markup offsets")
            } catch TXTLocationMigration.Failure.missingSourceIdentity {}
            #expect(positions.value == position)
            #expect(store.readingBook(id: book.id)?.bookmarks == beforeReplay)
            #expect(try Data(contentsOf: cache) == originalCache)
            #expect(try Data(contentsOf: journal) == ambiguousJournal)
            try currentJournal.write(to: journal)
            positions.failWrites = false
        }
        let migrated = try await TXTReaderIndexMigrationService.complete(prepared, store: store,
                                                                          positions: positions, settings: settings)
        let current = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: migrated.indexes)
        let rendered = try await current.buildChapter(at: 0, settings: settings, themeTextColor: .label,
                                                      themeBackgroundColor: .systemBackground).attributedString.string as NSString
        let expectedRange = rendered.range(of: "後文𠮷")
        let expected = CoreTextReadingPosition(spineIndex: 0, charOffset: expectedRange.location)
        #expect(positions.value == expected)
        #expect(migrated.restoredPosition == expected)
        let migratedBookmark = try #require(store.readingBook(id: book.id)?.bookmarks.first)
        #expect(migratedBookmark.position == expected)
        #expect(migratedBookmark.length == expectedRange.length)
        #expect(migratedBookmark.id == bookmark.id)
        #expect(migratedBookmark.note == bookmark.note)
        let reopened = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title)
        #expect(reopened.cachedChapterIndexes == migrated.indexes)
        let again = try await TXTReaderIndexMigrationService.complete(reopened, store: store,
                                                                      positions: positions, settings: settings)
        #expect(again.restoredPosition == expected)
        #expect(try Data(contentsOf: url) == data)
    }

    private final class Positions: ReadingPositionStore, @unchecked Sendable {
        private let lock = NSLock()
        var value: CoreTextReadingPosition?
        var failWrites = false
        init(_ position: CoreTextReadingPosition) { value = position }
        func save(_ position: CoreTextReadingPosition, for bookId: String) async {
            lock.withLock { if !failWrites { value = position } }
        }
        func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
        func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { value } }
        func flush(for bookId: String) async {}
    }

    private func build(_ source: String, mapped: Bool = true,
                       mode: ReaderWritingMode = .horizontal) async throws -> NSAttributedString {
        let builder: any AttributedStringBuilding
        if mapped {
            let file = TXTMappedTextFile(data: Data(source.utf8), encoding: .utf8)
            let indexes = [TXTMappedChapterIndex(index: 0, title: "Title", byteRange: 0..<file.byteCount)]
            builder = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: indexes)
        } else {
            builder = NodeAttributedStringBuilder(chapters: TXTChapterParser.parseUnifiedChapters(source, bookTitle: "Title"))
        }
        return try await builder.buildChapter(at: 0, settings: EPUBTestFixtures.renderSettings(writingMode: mode),
                                               themeTextColor: .label, themeBackgroundColor: .systemBackground).attributedString
    }

    private func expectRuby(_ reading: String, base: String, in attributed: NSAttributedString) throws {
        let range = (attributed.string as NSString).range(of: base)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return }
        var effective = NSRange()
        let annotation = try #require(attributed.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                                                            at: range.location, effectiveRange: &effective))
        #expect(CFGetTypeID(annotation as CFTypeRef) == CTRubyAnnotationGetTypeID())
        let ruby = unsafeBitCast(annotation as AnyObject, to: CTRubyAnnotation.self)
        #expect(CTRubyAnnotationGetTextForPosition(ruby, .before) as String? == reading)
        #expect(effective == range)
    }
}
