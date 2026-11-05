import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Editable TXT chapter rules (FB-139): legado compatibility, rule selection, and books
/// re-split when the rules change without losing their reading position or bookmarks.
@MainActor
@Suite(.serialized)
struct TXTChapterRuleTests {
    static let defaults = TXTTocRuleSet(rules: TXTTocRuleDefaults.rules)
    static let body = String(repeating: "　這是一段普通的正文內容，用來把標題隔開超過一千個字元。\n", count: 40)

    private func titles(_ text: String, _ rules: TXTTocRuleSet) -> [String] {
        TXTChapterParser.parseMappedChapterIndexes(TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8),
                                                   bookTitle: "Test", rules: rules).map(\.title)
    }

    // MARK: - legado JSON

    @Test func decodesEveryLegadoForkShape() throws {
        let json = """
        [
          {"id": -2, "name": "目录", "rule": "^第.+章", "example": "第一章", "serialNumber": 1, "enable": true},
          {"id": "1700000000000", "name": "MD3", "chapterRule": "^Chapter \\\\d+", "volumeRule": "^Book \\\\d+",
           "serialNumber": 0, "enable": false},
          {"id": 5, "name": "legado-E", "rule": "^\\\\d+、", "replacement": "x", "enable": true},
          {"id": 6, "name": "空的", "rule": ""}
        ]
        """
        let rules = try TXTTocRuleStore.decodeLegado(Data(json.utf8))
        #expect(rules.map(\.name) == ["legado-E", "MD3", "目录"])
        let md3 = try #require(rules.first { $0.name == "MD3" })
        #expect(md3.id == 1_700_000_000_000)
        #expect(md3.chapterRule == "^Chapter \\d+")
        #expect(md3.volumeRule == "^Book \\d+")
        #expect(!md3.enable)
        #expect(rules.first { $0.name == "目录" }?.chapterRule == "^第.+章")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(md3)) as? [String: Any])
        #expect(encoded["rule"] as? String == md3.chapterRule)
        #expect(encoded["chapterRule"] as? String == md3.chapterRule)
    }

    @Test func singleRuleObjectImports() throws {
        let rules = try TXTTocRuleStore.decodeLegado(Data(#"{"id": 1, "name": "一條", "rule": "^卷"}"#.utf8))
        #expect(rules.count == 1)
        #expect(rules[0].enable)
    }

    @Test func invalidRegexIsRejectedWithItsField() {
        func field(_ rule: TXTTocRule) -> TXTTocRuleError.Field? {
            do {
                _ = try rule.compiled()
            } catch TXTTocRuleError.invalidRegex(let field, _) {
                return field
            } catch {}
            return nil
        }
        let rule = TXTTocRule(id: 1, name: "壞", chapterRule: "^第(", volumeRule: "")
        #expect(field(rule) == .chapter)
        #expect(field(TXTTocRule(id: 2, name: "壞", chapterRule: "^第", volumeRule: "[")) == .volume)
        #expect(throws: TXTTocRuleError.emptyChapterRule) { try TXTTocRule(id: 3, name: "", chapterRule: " ").compiled() }
        // A broken rule never reaches the parser, and its fingerprint differs from none.
        #expect(TXTTocRuleSet(rules: [rule]).rules.isEmpty)
    }

    // MARK: - Selection

    @Test func mostWellSpacedHeadingsWin() {
        let text = (1...3).map { chapter in
            "第\(chapter)章 大章\n" + (1...4).map { "第\($0)節 小節\n" + Self.body }.joined()
        }.joined()
        // 12 spaced 節 beat 3 章: legado's choice (maintainer, 2026-11-05). The first 章 line
        // is front matter before the first 節; the rest stay in the text.
        let found = titles(text, Self.defaults)
        #expect(found.filter { $0.contains("節") }.count == 12)
        #expect(found.first == "Preface")
        #expect(!found.contains { $0.contains("章") })
    }

    @Test func headingsCloserThanTheSpacingCountOnce() {
        // A table of contents lists 10 節 back to back; the book itself has 3 spaced 章.
        let contents = (1...10).map { "第\($0)節 目錄項\n" }.joined()
        let text = contents + (1...3).map { "第\($0)章 正文\n" + Self.body }.joined()
        #expect(titles(text, Self.defaults).filter { $0.hasPrefix("第") && $0.contains("章") }.count == 3)
    }

    @Test func equalCountsGoToTheRuleHigherInTheList() {
        // Text between 第二篇 and 第2章, or 第二篇 would open 第2章 as its volume.
        let text = "第1章 開始\n正文。\n第一篇：人仙篇！\n第二篇：地仙篇。\n接著修煉。\n第2章 繼續\n正文。"
        #expect(titles(text, Self.defaults) == ["第1章 開始", "第2章 繼續"])
        var reordered = TXTTocRuleDefaults.rules
        reordered.swapAt(0, 4)
        #expect(titles(text, TXTTocRuleSet(rules: reordered)) == ["Preface", "第一篇：人仙篇！", "第二篇：地仙篇。"])
    }

    @Test func disabledRulesAreIgnored() {
        let text = (1...3).map { "第\($0)章 開始\n" + Self.body }.joined()
        let rules = TXTTocRuleDefaults.rules.map { rule -> TXTTocRule in
            var copy = rule
            copy.enable = false
            return copy
        }
        // No rule: the size fallback names sections after the book.
        #expect(titles(text, TXTTocRuleSet(rules: rules)).first == "Test")
    }

    @Test func lookbehindRulesSeeTheLineBreakBeforeAHeading() {
        // legado's 数字 rules start with `(?<=[　\s])`; a heading at column 0 still matches.
        let numbered = TXTTocRule(id: 10, name: "數字", chapterRule: "(?<=[　\\s])\\d{1,4}、.{1,30}$")
        let text = (1...4).map { "\($0)、標題\($0)\n" + Self.body }.joined()
        let found = titles(text, TXTTocRuleSet(rules: TXTTocRuleDefaults.rules + [numbered]))
        #expect(found == (1...4).map { "\($0)、標題\($0)" })
        // The prefilter cannot know a user rule's first characters; it must not drop these lines.
        let utf16 = TXTMappedTextFile(data: Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
                                      encoding: .utf16LittleEndian)
        #expect(TXTChapterParser.parseMappedChapterIndexes(utf16, bookTitle: "Test",
                                                           rules: TXTTocRuleSet(rules: [numbered])).map(\.title) == found)
    }

    @Test func previewListsOnlyTheRulesOwnHeadings() {
        let file = TXTMappedTextFile(data: Data(("序章\n" + Self.body + "第1章 開始\n正文\n第2章 續\n正文").utf8),
                                     encoding: .utf8)
        #expect(TXTChapterParser.previewTitles(in: file, rules: TXTTocRuleSet(rules: [TXTTocRuleDefaults.rules[0]]))
            == ["第1章 開始", "第2章 續"])
    }

    @Test func fingerprintFollowsEnabledRulesAndOrder() {
        var rules = TXTTocRuleDefaults.rules
        let original = TXTTocRuleSet(rules: rules).fingerprint
        #expect(TXTTocRuleSet(rules: rules).fingerprint == original)
        rules[1].enable = false
        #expect(TXTTocRuleSet(rules: rules).fingerprint != original)
        rules = TXTTocRuleDefaults.rules
        rules.swapAt(0, 1)
        #expect(TXTTocRuleSet(rules: rules).fingerprint != original)
        // Renaming changes nothing a book is split by.
        rules = TXTTocRuleDefaults.rules
        rules[0].name = "改名"
        #expect(TXTTocRuleSet(rules: rules).fingerprint == original)
    }

    // MARK: - Re-splitting a book

    private final class Positions: ReadingPositionStore, @unchecked Sendable {
        let lock = NSLock()
        var value: CoreTextReadingPosition?
        init(_ position: CoreTextReadingPosition?) { value = position }
        func save(_ position: CoreTextReadingPosition, for bookId: String) async { lock.withLock { value = position } }
        func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
        func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { value } }
        func flush(for bookId: String) async {}
    }

    private func render(_ indexes: [TXTMappedChapterIndex], _ file: TXTMappedTextFile, at index: Int) async throws -> NSString {
        try await TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: indexes)
            .buildChapter(at: index, settings: EPUBTestFixtures.renderSettings(),
                          themeTextColor: .label, themeBackgroundColor: .systemBackground)
            .attributedString.string as NSString
    }

    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian])
    func positionAndBookmarksLandOnTheSameTextAfterAReSplit(encoding: String.Encoding) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two 章, each with numbered sections the default rules leave in the body.
        func section(_ chapter: Int, _ number: Int) -> String {
            "\(number)、第\(chapter)章第\(number)節\n" + Self.body + "　標記\(chapter)-\(number)在這裡。\n" + Self.body
        }
        let text = (1...2).map { chapter in
            "第\(chapter)章 大章\n" + (1...3).map { section(chapter, $0) }.joined()
        }.joined()
        let data = try #require(text.data(using: encoding))
        let url = directory.appendingPathComponent("book.txt")
        try data.write(to: url)
        let file = try TXTFileReader.readMappedTextFile(url: url)
        #expect(file.encoding == encoding)
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.txt")
        defer {
            TXTChapterParser.deleteCachedIndexes(bookId: book.id)
            try? FileManager.default.removeItem(at: StorageLocations.readingPosition
                .appendingPathComponent("\(book.id.uuidString).txt-reindex.json"))
        }

        // Read through the built-in rules: 2 chapters, cached under their fingerprint.
        let old = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: book.title, rules: Self.defaults)
        #expect(old.map(\.title) == ["第1章 大章", "第2章 大章"])
        try TXTChapterParser.writeCachedIndexes(old, bookId: book.id, fileSize: file.byteCount,
                                               fingerprint: TXTFileReader.fileFingerprint(data: file.data),
                                               encoding: file.encoding, rulesFingerprint: Self.defaults.fingerprint)
        let oldChapter = try await render(old, file, at: 1)
        let target = oldChapter.range(of: "標記2-2")
        let highlight = oldChapter.range(of: "標記2-3在這裡")
        // A highlight running across the new 3、 heading, which becomes a chapter boundary.
        let crossing = oldChapter.range(of: "標記2-2在這裡。")
        let crossingEnd = oldChapter.range(of: "3、第2章第3節")
        #expect(target.location != NSNotFound && highlight.location != NSNotFound)
        let bookmarks = [
            Bookmark(chapterIndex: 1, chapterTitle: old[1].title, position: .init(spineIndex: 1, charOffset: highlight.location),
                     length: highlight.length, kind: .highlight, note: "保留", excerpt: "標記2-3在這裡"),
            Bookmark(chapterIndex: 1, chapterTitle: old[1].title, position: .init(spineIndex: 1, charOffset: crossing.location),
                     length: NSMaxRange(crossingEnd) - crossing.location, kind: .highlight, excerpt: "標記2-2"),
            Bookmark(chapterIndex: 1, chapterTitle: old[1].title, position: .chapterStart(1)),
        ]
        book.bookmarks = bookmarks
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        store.replaceBooksFromSync([book])
        let positions = Positions(.init(spineIndex: 1, charOffset: target.location))

        // Numbered sections added above the built-ins: they now outnumber 章.
        let numbered = TXTTocRule(id: 99, name: "數字", chapterRule: "^\\d{1,4}、.{1,30}$")
        let newRules = TXTTocRuleSet(rules: [numbered] + TXTTocRuleDefaults.rules)
        let preparation = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title,
                                                                  ruleSet: newRules)
        #expect(preparation.cachedChapterIndexes == nil)
        #expect(preparation.previousChapterIndexes == old)
        let result = try await TXTReaderIndexMigrationService.complete(
            preparation, store: store, positions: positions, settings: EPUBTestFixtures.renderSettings())
        // The first 章 line is front matter now; the second ends section 1-3's text.
        #expect(result.indexes.map(\.title)
            == ["Preface"] + (1...2).flatMap { chapter in (1...3).map { "\($0)、第\(chapter)章第\($0)節" } })

        let restored = try #require(result.restoredPosition)
        #expect(restored.spineIndex == 5)
        let restoredText = try await render(result.indexes, file, at: restored.spineIndex)
        #expect(restoredText.substring(from: restored.charOffset).hasPrefix("標記2-2"))
        #expect(positions.value == restored)

        let migrated = try #require(store.readingBook(id: book.id)?.bookmarks)
        #expect(migrated.map(\.id) == bookmarks.map(\.id))
        let kept = migrated[0]
        #expect(kept.position.spineIndex == 6)
        #expect(kept.note == "保留")
        let keptText = try await render(result.indexes, file, at: 6)
        #expect(keptText.substring(with: NSRange(location: kept.position.charOffset, length: kept.length)) == "標記2-3在這裡")
        // The crossing highlight keeps its start and ends with its new chapter.
        let cut = migrated[1]
        #expect(cut.position.spineIndex == 5)
        #expect(restoredText.substring(from: cut.position.charOffset).hasPrefix("標記2-2在這裡。"))
        #expect(cut.position.charOffset + cut.length == restoredText.length)
        // The old chapter's start was its 第2章 heading, now the last line of section 1-3.
        let headingMark = migrated[2].position
        #expect(headingMark.spineIndex == 3)
        let sectionText = try await render(result.indexes, file, at: 3)
        #expect(sectionText.substring(from: headingMark.charOffset).hasPrefix("第2章 大章"))

        let reopened = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title,
                                                               ruleSet: newRules)
        #expect(reopened.cachedChapterIndexes == result.indexes)
    }

    @Test func indexesFromTheHardCodedPatternsRepublishWhenNothingMoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.txt")
        try Data(((1...3).map { "第\($0)章 開始\n" + Self.body }.joined()).utf8).write(to: url)
        let file = try TXTFileReader.readMappedTextFile(url: url)
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.txt")
        defer { TXTChapterParser.deleteCachedIndexes(bookId: book.id) }
        let indexes = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: book.title, rules: Self.defaults)
        // Written before rules were editable: v7 with no rule fingerprint.
        try TXTChapterParser.writeCachedIndexes(indexes, bookId: book.id, fileSize: file.byteCount,
                                               fingerprint: TXTFileReader.fileFingerprint(data: file.data),
                                               encoding: file.encoding)
        book.bookmarks = [Bookmark(chapterIndex: 2, chapterTitle: indexes[2].title, position: .init(spineIndex: 2, charOffset: 9))]
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        store.replaceBooksFromSync([book])
        let position = CoreTextReadingPosition(spineIndex: 1, charOffset: 7)
        let positions = Positions(position)
        let preparation = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title,
                                                                  ruleSet: Self.defaults)
        #expect(preparation.previousChapterIndexes == indexes)
        // 作品詳情's 目錄 no longer waits on the reader for such a book.
        let listed = try await TXTReaderIndexMigrationService.indexForListing(preparation, store: store, positions: positions)
        #expect(listed == indexes)
        #expect(positions.value == position)
        #expect(store.readingBook(id: book.id)?.bookmarks == book.bookmarks)
        let reopened = try TXTReaderPreparationService.prepare(url: url, bookId: book.id, bookTitle: book.title,
                                                               ruleSet: Self.defaults)
        #expect(reopened.cachedChapterIndexes == indexes)
    }
}
