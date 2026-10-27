import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3: the layouts (精簡閱讀卡片 since 5d-3c), what a stored layout draws, and 呈現方式's edit.
@Suite("Home layout style")
@MainActor
struct HomeLayoutStyleTests {
    @Test("each layout is written as its own value and read back as itself")
    func roundTrip() throws {
        for style in HomeLayoutStyle.allCases {
            for ranked in [false, true] {
                let layout = HomeSectionLayout(style: style, ranked: ranked)
                let section = HomeSection(layout: layout, binding: .related)
                let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
                #expect(decoded.layout == layout)
                #expect(decoded.layout.isKnown)
                #expect(decoded.layout.style == style)
                #expect(decoded.layout.showsRanks == (style.canShowRanks && ranked))
            }
        }
        #expect(HomeSectionLayout(style: .row) == .row)
        #expect(HomeSectionLayout(style: .row, ranked: true) == .rankedRow)
        #expect(HomeSectionLayout(style: .largeRow, ranked: true) == .largeRow, "ranks are kept only where they are drawn")
    }

    @Test("a custom page's seven kinds draw as decision 14 maps them")
    func customPageKinds() {
        let expected: [CustomExploreComponent.Kind: (HomeLayoutStyle, Bool)] = [
            .featuredCards: (.row, false), .carousel: (.row, false), .grid: (.multiRow, false),
            .ranking: (.list, true), .pagedRanking: (.list, true), .multiCategoryRanking: (.list, true),
            .waterfall: (.coverGrid, false),
        ]
        #expect(Set(expected.keys) == Set(CustomExploreComponent.Kind.allCases))
        for (kind, (style, ranked)) in expected {
            let layout = HomeSectionLayout(kind)
            #expect(layout.style == style, "\(kind)")
            #expect(layout.showsRanks == ranked, "\(kind)")
        }
    }

    @Test("磚塊 and a later build's layout draw as a row")
    func othersDrawAsARow() {
        #expect(HomeSectionLayout.tiles.style == .row)
        let later = HomeSectionLayout(rawValue: "spotlight")
        #expect(later.style == .row)
        #expect(!later.isKnown)
    }

    @Test("at accessibility text sizes 多行橫向輪播 draws one row; the others draw as chosen")
    func accessibilitySizes() {
        #expect(HomeSectionLayout.multiRow.drawnStyle(accessibilityTextSize: true) == .row)
        #expect(HomeSectionLayout.multiRow.drawnStyle(accessibilityTextSize: false) == .multiRow)
        for style in HomeLayoutStyle.allCases where style != .multiRow {
            #expect(HomeSectionLayout(style: style).drawnStyle(accessibilityTextSize: true) == style)
        }
    }

    @Test("呈現方式 changes that one section's layout and nothing else")
    func setLayout() {
        let reading = HomeSection(layout: .readingCard, binding: .continueReading)
        let related = HomeSection(layout: .row, binding: .related)
        var page = HomePage(sections: [reading, related])
        page.setLayout(.rankedList, section: related.id)
        #expect(page.sections[1].layout == .rankedList)
        #expect(page.sections[0] == reading)
        #expect(page.sections[1].binding == .related)
    }

    @Test("a section of books is offered every layout, its list a card in a layout of lists; lists alone the layouts of lists")
    func choices() {
        for binding in [HomeSectionBinding.continueReading, .latest, .aiRecommendations] {
            #expect(HomeLayoutStyle.choices(for: binding) == HomeLayoutStyle.allCases)
        }
        for binding in [HomeSectionBinding.gutenbergLists, .lists([])] {
            #expect(HomeLayoutStyle.choices(for: binding) == [.collection, .categoryCards, .collageCards, .bannerCards])
        }
    }

    @Test("色帶書架 is the 頂部輪播圖, no layout to choose: a band saved anywhere else draws as 大型封面書架")
    func bandIsTheCarousel() {
        #expect(HomeSectionLayout.band.isKnown)
        #expect(HomeSectionLayout.band.style == .largeRow)
        for binding in [HomeSectionBinding.latest, .gutenbergLists, .sourceCategories([])] {
            #expect(!HomeLayoutStyle.choices(for: binding).contains { HomeSectionLayout(style: $0) == .band })
        }
        #expect(HomeSectionLayout(style: .bannerCards) == .bannerCards)
    }

    @Test("繼續閱讀 starts as 精簡閱讀卡片, 古騰堡熱門 ranked, 精選書單 as 分類卡片; the other defaults as a row")
    func defaults() {
        for mode in ExploreMode.allCases {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: true, languages: [])
            for section in page.sections {
                let expected: HomeSectionLayout = switch section.binding {
                case .continueReading: .compactReadingCard
                case .gutenbergShelf(id: "popular"): .rankedRow
                case .gutenbergLists: .categoryCards
                default: .row
                }
                #expect(section.layout == expected)
            }
        }
    }

    @Test("ranks show on 圖文資訊清單 and 橫向單排書架 alone")
    func ranks() {
        #expect(HomeLayoutStyle.allCases.filter(\.canShowRanks) == [.row, .list])
        #expect(HomeSectionLayout.rankedRow.style == .row)
        #expect(HomeSectionLayout.rankedRow.showsRanks)
        #expect(!HomeSectionLayout.row.showsRanks)
    }
}
