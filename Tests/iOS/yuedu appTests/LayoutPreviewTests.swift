import Foundation
import Testing
@testable import yuedu_app

/// Decision 34: 呈現方式 shows each layout drawn with books whose covers the app carries, the
/// same everywhere and offline. The maintainer, 2026-10-13: each layout its own covers, no book
/// in two layouts.
@Suite("呈現方式's previews")
@MainActor
struct LayoutPreviewTests {
    private var bookLayouts: [HomeLayoutStyle] { HomeLayoutStyle.allCases.filter { !$0.drawsLists } }

    @Test("Every layout of books has its own sample, in order, each card drawn from its bundled cover")
    func cards() throws {
        let sample = HomeLayoutSample.standard
        for style in bookLayouts {
            let books = try #require(HomeLayoutSample.books[style], "\(style) has no sample")
            #expect(!books.isEmpty)
            let cards = sample.cards(for: style)
            #expect(cards.map(\.title) == books.map(\.title))
            for (card, book) in zip(cards, books) {
                #expect(card.kind == book.kind)
                guard case .reference(.copyFile(let path), _) = card.cover else {
                    Issue.record("\(book.title) has no bundled cover")
                    continue
                }
                #expect(path.hasSuffix("layout-sample-\(book.cover).jpg"))
                #expect(FileManager.default.fileExists(atPath: path))
            }
        }
    }

    @Test("No book is in two layouts or in a list, and no series or magazine appears twice")
    func noRepeats() {
        let all = HomeLayoutSample.books.values.flatMap { $0 } + HomeLayoutSample.lists.flatMap(\.books)
        #expect(Set(all.map(\.cover)).count == all.count)
        #expect(Set(all.map(\.title)).count == all.count)
        // Two issues of one magazine, or two books of one series, read as a repeat.
        let works = Dictionary(grouping: all, by: \.work).filter { $0.value.count > 1 }
        #expect(works.isEmpty, "\(works.mapValues { $0.map(\.title) })")
    }

    @Test("Each layout shows as many books as its preview has room for on a phone")
    func counts() {
        let expected: [HomeLayoutStyle: Int] = [.featured: 3, .readingCard: 3, .compactReadingCard: 3, .list: 3,
                                                .row: 6, .multiRow: 12, .coverGrid: 12, .largeRow: 4, .colorBand: 4,
                                                .heroGrid: 6]
        #expect(HomeLayoutSample.books.mapValues(\.count) == expected)
    }

    @Test("多行橫向輪播 is comics, as are the 漫畫 list's books")
    func comics() {
        #expect(HomeLayoutSample.books[.multiRow]?.allSatisfy { $0.kind == .comic } == true)
        #expect(HomeLayoutSample.lists.first { $0.id == "comics" }?.books.allSatisfy { $0.kind == .comic } == true)
    }

    @Test("Each layout of lists has its own two lists, every artwork cover bundled")
    func lists() {
        let sample = HomeLayoutSample.standard
        let expected: [HomeLayoutStyle: [String]] = [.collection: ["漫畫", "東方經典"], .categoryCards: ["詩歌", "博物誌"],
                                                     .collageCards: ["推理", "冒險"], .bannerCards: ["奇幻", "歷史"],
                                                     .chart: ["小說", "詩集"]]
        for style in HomeLayoutStyle.allCases where style.drawsLists {
            #expect(sample.collections(for: style).map(\.title) == expected[style]?.map { localized($0) }, "\(style)")
        }
        for (style, collections) in sample.collections {
            for collection in collections {
                // 拼貼卡片 draws five covers; 大圖卡片 none, its face drawn from the name; the others three.
                let drawn = switch style {
                case .collageCards: CollectionSummary.collageLimit
                case .bannerCards: 0
                default: CollectionSummary.artworkLimit
                }
                #expect(collection.books.count == drawn, "\(collection.title)")
            }
        }
        // 排行榜's columns draw each list's books as its places.
        for collection in sample.collections(for: .chart) {
            #expect(sample.listContents[collection.id]?.cards.map(\.title) == collection.books.map(\.title))
            #expect((sample.listContents[collection.id]?.cards.count ?? 0) == HomeChartColumns.places)
        }
        for collection in sample.collections.values.flatMap({ $0 }) {
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
