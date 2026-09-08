import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Characterizes the ambiguity in G2's scroll-settle evidence. This is not a
/// regression expectation that false-positive alerts should remain forever.
@MainActor
struct TXTScrollJumpDiagnosticTests {
    @Test("inspect the user-supplied TXT against the diagnostic chapter indexes",
          .enabled(if: FileManager.default.fileExists(atPath: "/Users/zhangruilin/Downloads/聚宝仙盆 (1).txt")))
    func inspectSuppliedCorpusChapterIdentity() throws {
        let file = try TXTFileReader.readMappedTextFile(
            url: URL(fileURLWithPath: "/Users/zhangruilin/Downloads/聚宝仙盆 (1).txt"))
        let indexes = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "聚宝仙盆")
        print("TXT_CORPUS_IDENTITY bytes=\(file.byteCount) encoding=\(file.encoding.rawValue) chapters=\(indexes.count)")
        let selected = Set([0, 1, indexes.count - 1, 1012, 1013, 1014, 1015, 1016, 1017])
        for index in indexes where selected.contains(index.index) {
            let body = TXTChapterParser.chapterText(file, byteRange: index.byteRange)
            print("TXT_CORPUS_CHAPTER index=\(index.index) title=\(index.title) range=\(index.byteRange) bytes=\(index.byteRange.count) chars=\((body as NSString).length) head=\(String(body.prefix(180)))")
        }
        #expect(!indexes.isEmpty)
        #expect(indexes.enumerated().allSatisfy { $0.offset == $0.element.index })
        #expect(!indexes.contains { $0.title == "第一篇：人仙篇！" || $0.title == "第二篇：地仙篇。" })
        let chapter = try #require(indexes.first { $0.title == "第1005章 美人面" })
        let chapterBody = TXTChapterParser.chapterText(file, byteRange: chapter.byteRange)
        #expect(chapterBody.contains("第一篇：人仙篇！"))
        #expect(chapterBody.contains("第二篇：地仙篇。"))
        #expect(indexes[chapter.index + 1].title == "第1006章 青玄仙人")
    }

    @Test("real logged TXT positions map into the complete original chapter",
          .enabled(if: FileManager.default.fileExists(atPath: "/Users/zhangruilin/Downloads/聚宝仙盆 (1).txt")))
    func loggedPositionsMigrateBySource() async throws {
        let file = try TXTFileReader.readMappedTextFile(url: URL(fileURLWithPath: "/Users/zhangruilin/Downloads/聚宝仙盆 (1).txt"))
        // Captured v5 source ranges from the diagnostic, indexed locally for this
        // three-entry projection. Production never identifies books by these values.
        let old: [TXTMappedChapterIndex] = [
            .init(index: 0, title: "第1005章 美人面", byteRange: 6992751..<6997979),
            .init(index: 1, title: "第一篇：人仙篇！", byteRange: 6998010..<6998010),
            .init(index: 2, title: "第二篇：地仙篇。", byteRange: 6998047..<6999783)
        ]
        let new = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Test")
        let target = try #require(new.first { $0.title == "第1005章 美人面" })
        let mapping = try TXTLocationMigration(file: file, oldIndexes: old, newIndexes: new)
        let oldBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: old)
        let newBuilder = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: new)
        let settings = EPUBTestFixtures.renderSettings()
        let newText = try await newBuilder.buildChapter(at: target.index, settings: settings, themeTextColor: .label, themeBackgroundColor: .systemBackground).attributedString.string
        var offsets: [Int] = []
        for position in [CoreTextReadingPosition(spineIndex: 0, charOffset: 1648), .chapterStart(1), .chapterStart(2)] {
            let oldText = try await oldBuilder.buildChapter(at: position.spineIndex, settings: settings, themeTextColor: .label, themeBackgroundColor: .systemBackground).attributedString.string
            let mapped = try mapping.map(position, oldRendered: oldText, newRendered: newText)
            #expect(mapped.spineIndex == target.index)
            offsets.append(mapped.charOffset)
            print("TXT_REAL_MIGRATION oldIndex=\(1014 + position.spineIndex) oldOffset=\(position.charOffset) newIndex=\(mapped.spineIndex) newOffset=\(mapped.charOffset)")
        }
        #expect(offsets == offsets.sorted())
        #expect((newText as NSString).substring(from: offsets[1]).hasPrefix("第一篇：人仙篇！"))
        #expect((newText as NSString).substring(from: offsets[2]).hasPrefix("第二篇：地仙篇。"))
    }

    @Test("a fully loaded title-only TXT chapter can be crossed between two G2 observations", arguments: [false, true])
    func titleOnlyChapterDoesNotRequireAMissingContentPlaceholder(mapped: Bool) async throws {
        let text = "第1章 开始\n" + String(repeating: "这是第一章的普通正文。\n", count: 100)
            + "第2章 空章\n第3章 继续\n"
            + String(repeating: "这是第三章的普通正文。\n", count: 100)
        let indexes = TXTChapterParser.parseChapterIndexes(text, bookTitle: "Diagnostic")
        #expect(indexes.count == 3)
        #expect(try #require(indexes.first { $0.index == 1 }).contentRange.length == 0)
        let builder: TXTLazyAttributedStringBuilder
        if mapped {
            let file = TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)
            let mappedIndexes = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Diagnostic")
            #expect(mappedIndexes.count == 3)
            #expect(try #require(mappedIndexes.first { $0.index == 1 }).byteRange.isEmpty)
            builder = TXTLazyAttributedStringBuilder(mappedTextFile: file, chapterIndexes: mappedIndexes)
        } else {
            builder = TXTLazyAttributedStringBuilder(text: text, chapterIndexes: indexes)
        }
        let settings = EPUBTestFixtures.renderSettings()
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        var requested: [Int] = []
        engine.onChapterContentRequired = { requested.append($0) }
        await engine.start(initialChapter: 1, contentWidth: 345)

        let middle = try #require(engine.chapterRanges[1])
        #expect(middle.count == 1)
        let middleChunk = engine.chunks[middle.lowerBound]
        #expect(middleChunk.attributedString.string.contains("第2章 空章"))
        #expect(middleChunk.height < 480)
        #expect(requested.isEmpty)
        #expect(engine.geometryChapterOrder == [0, 1, 2])
        for chapter in 0..<3 {
            #expect(engine.characterCount(forChapter: chapter) != nil)
        }

        // No navigation or offset write occurs here: these are the same two
        // observations a continuous drag across the short middle chapter emits.
        var reports: [ReaderPositionSentry.Report] = []
        let sentry = ReaderPositionSentry(emit: { reports.append($0) })
        sentry.observeCommit(.init(spineIndex: 0, charOffset: 100), source: .scrollSettle)
        sentry.observeCommit(.chapterStart(2), source: .scrollSettle)
        #expect(reports.contains { $0.detail.contains("guard=G2") })
        #expect(reports.contains { $0.detail.contains("placeholder=false") })
        print("TXT_SCROLL_DIAGNOSTIC mapped=\(mapped) middleBodyLength=\(indexes[1].contentRange.length) middleHeight=\(middleChunk.height) missingRequests=\(requested.count) order=\(engine.geometryChapterOrder)")
    }
}
