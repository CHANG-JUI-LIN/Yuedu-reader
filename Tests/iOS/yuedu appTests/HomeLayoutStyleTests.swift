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
            let layout = HomeSectionLayout(style: style)
            let section = HomeSection(layout: layout, binding: .related)
            let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
            #expect(decoded.layout == layout)
            #expect(decoded.layout.isKnown)
            #expect(decoded.layout.style == style)
        }
        #expect(HomeSectionLayout(style: .row) == .row)
        #expect(HomeSectionLayout(style: .list) == .list)
    }

    @Test("a custom page's seven kinds draw as decision 14 maps them, its rankings as 排行榜")
    func customPageKinds() {
        let expected: [CustomExploreComponent.Kind: HomeLayoutStyle] = [
            .featuredCards: .row, .carousel: .row, .grid: .multiRow,
            .ranking: .chart, .pagedRanking: .chart, .multiCategoryRanking: .chart,
            .waterfall: .coverGrid,
        ]
        #expect(Set(expected.keys) == Set(CustomExploreComponent.Kind.allCases))
        for (kind, style) in expected {
            #expect(HomeSectionLayout(kind).style == style, "\(kind)")
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
            #expect(HomeLayoutStyle.choices(for: binding) == [.collection, .categoryCards, .collageCards, .bannerCards, .chart, .groupedShelves, .genreList])
        }
    }

    @Test("the store's three layouts (2026-11-14) are stored under their own values, which a build before them keeps")
    func storeLayouts() throws {
        for (layout, style) in [(HomeSectionLayout.heroCards, HomeLayoutStyle.heroCards), (.groupedShelves, .groupedShelves),
                                (.genreList, .genreList)] {
            #expect(layout.isKnown)
            #expect(layout.style == style)
            #expect(HomeSectionLayout(style: style) == layout)
            #expect(layout.componentKind == nil)
            // Written and read back as the string it is.
            let section = HomeSection(layout: layout, binding: .gutenbergLists)
            let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
            #expect(decoded.layout == layout)
        }
        // 主打卡片 is a layout of books; the other two draw a list each, 分組書架 with the list's own books.
        #expect(!HomeLayoutStyle.heroCards.drawsLists)
        #expect(HomeLayoutStyle.groupedShelves.drawsLists && HomeLayoutStyle.genreList.drawsLists)
        #expect(HomeLayoutStyle.allCases.filter(\.drawsListBooks) == [.chart, .groupedShelves])
        // A build before them reads the value as one it does not know, drawn as a row.
        #expect(HomeSectionLayout(rawValue: "aLaterBuildsLayout").style == .row)
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

    @Test("色帶書架 is a layout of its own, never the 頂部輪播圖's band; a build before it draws a row")
    func colorBand() {
        #expect(HomeSectionLayout(style: .colorBand) == .colorBand)
        #expect(HomeSectionLayout(style: .colorBand) != .band)
        #expect(HomeSectionLayout.colorBand.style == .colorBand)
        #expect(!HomeLayoutStyle.colorBand.drawsLists)
        #expect(HomeLayoutStyle.choices(for: .latest).contains(.colorBand))
        #expect(!HomeLayoutStyle.choices(for: .gutenbergLists).contains(.colorBand))
    }

    @Test("the defaults' layouts are the store's: 繼續閱讀 精簡閱讀卡片, 熱門精選 collages, 今日熱門 主打卡片, 熱門排行榜 ranked, 精選書單 大圖卡片")
    func defaults() {
        for mode in ExploreMode.allCases {
            let page = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: true, languages: ["zh"])
            for section in page.sections {
                let expected: HomeSectionLayout = switch section.binding {
                case .continueReading: .compactReadingCard
                case .lists(HomePageDefaults.pickCards): .collageCards
                case .lists: .rankedRow
                case .module(HomePageDefaults.trendsID, "today"): .heroCards
                case .module(HomePageDefaults.trendsID, "month"): .multiRow
                case .module(HomePageDefaults.trendsID, "completed"): .largeRow
                case .module(HomePageDefaults.trendsID, "year"): .heroGrid
                case .module(HomePageDefaults.trendsID, "classics"): .colorBand
                case .gutenbergLists: .bannerCards
                default: .row
                }
                #expect(section.layout == expected)
            }
        }
    }

    @Test("排行榜 replaced 顯示排名: both ranked values read as it, and it is written as the ranked row a build before it draws")
    func chart() {
        #expect(HomeSectionLayout.rankedRow.style == .chart)
        #expect(HomeSectionLayout.rankedList.style == .chart)
        #expect(HomeSectionLayout(style: .chart) == .rankedRow)
        #expect(HomeLayoutStyle.chart.drawsLists, "one ranking is one card, as one list is")
        #expect(HomeSectionLayout.row.style == .row)
        #expect(HomeSectionLayout.list.style == .list)
    }
}
