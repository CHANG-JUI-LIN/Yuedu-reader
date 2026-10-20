import Foundation
import Testing
@testable import yuedu_app

/// MetricKit disk-write exception, build 129: a launch refresh over 173 books rewrote every
/// unchanged table of contents, 1.08 GB within a minute, because only eight lists are held
/// in memory to compare with.
@Suite("Chapter lists: an unchanged list is not written again")
struct BookChapterStoreRewriteTests {
    /// An atomic write replaces the file, so a rewritten list has a new file number.
    private func fileNumber(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? Int)
    }

    @Test("a shelf larger than the lists held in memory sets every list again unchanged, and none is rewritten")
    func unchangedListsKeepTheirFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterRewrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookChapterStore(directoryURL: folder)
        let ids = (0..<20).map { _ in UUID() }
        let lists = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, (0..<5).map { OnlineChapterRef(index: $0, title: "第\($0)章", url: "https://chapters.test/\(id)/\($0)") })
        })
        for id in ids { store.setChapters(lists[id]!, for: id) }
        store.flush()
        let files = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try fileNumber(store.fileURL(for: $0))) })

        for id in ids { store.setChapters(lists[id]!, for: id) }
        store.flush()

        for id in ids {
            #expect(try fileNumber(store.fileURL(for: id)) == files[id], "book \(ids.firstIndex(of: id)!) was rewritten")
        }
        #expect(!store.hasUnwrittenChanges)

        // A changed list is still written.
        var changed = lists[ids[0]]!
        changed.append(OnlineChapterRef(index: 5, title: "第5章", url: "https://chapters.test/new/5"))
        store.setChapters(changed, for: ids[0])
        store.flush()
        #expect(BookChapterStore(directoryURL: folder).chapters(for: ids[0]) == changed)
    }
}
