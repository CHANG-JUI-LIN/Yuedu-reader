import Foundation
import Testing
@testable import yuedu_app

/// Decision 34: 呈現方式 shows each layout drawn with a sample of classics whose covers the app
/// carries, the same everywhere and offline.
@Suite("呈現方式's previews")
@MainActor
struct LayoutPreviewTests {
    @Test("The cards are the sample classics, in order, each drawn from its bundled cover")
    func cards() throws {
        let sample = HomeLayoutSample.standard
        #expect(sample.cards.map(\.title) == HomeLayoutSample.books.map(\.title))
        for (card, book) in zip(sample.cards, HomeLayoutSample.books) {
            guard case .reference(.copyFile(let path), _) = card.cover else {
                Issue.record("\(book.title) has no bundled cover")
                continue
            }
            #expect(path.hasSuffix("layout-sample-\(ExternalIdentifier.gutenbergNumber(from: book.id) ?? "").jpg"))
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("專題集合's sample: 小說與文學 and 兒童與青少年, every artwork cover bundled")
    func lists() {
        let sample = HomeLayoutSample.standard
        #expect(sample.collections.map(\.id) == ["fiction", "children"])
        #expect(sample.collections.map(\.title) == [localized("小說與文學"), localized("兒童與青少年")])
        for collection in sample.collections {
            for book in collection.books {
                guard case .copyFile(let path)? = book.cover else {
                    Issue.record("\(book.title) has no bundled cover")
                    continue
                }
                #expect(FileManager.default.fileExists(atPath: path))
            }
        }
    }
}
