import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-2: 編輯首頁's edits keep what the editor does not list where it was.
@Suite("Home page editing")
@MainActor
struct HomePageEditingTests {
    private let later = HomeSection(layout: HomeSectionLayout(rawValue: "spotlight"),
                                    binding: .unknown(.object(["type": .string("moduleFeed")])))
    private let library = HomeSection(layout: .tiles, binding: .myLibrary)
    private let reading = HomeSection(layout: .row, binding: .continueReading)
    private let latest = HomeSection(layout: .row, binding: .latest)
    private let related = HomeSection(layout: .row, binding: .related)

    @Test("the editor lists the sections a home draws, in order")
    func listed() {
        let page = HomePage(sections: [library, reading, later, latest, related])
        #expect(page.editableSections.map(\.id) == [reading.id, latest.id, related.id])
    }

    @Test("reordering moves only listed sections, among the places they held")
    func moveKeepsOthersInPlace() {
        var page = HomePage(sections: [library, reading, later, latest, related])
        // 相關 to the top of the list.
        page.moveEditable(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(page.sections.map(\.id) == [library.id, related.id, later.id, reading.id, latest.id])
        // 相關 back to the end, as List reports a move down (the offset past the last row).
        page.moveEditable(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(page.sections.map(\.id) == [library.id, reading.id, later.id, latest.id, related.id])
        // Two at once.
        page.moveEditable(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        #expect(page.sections.map(\.id) == [library.id, related.id, later.id, reading.id, latest.id])
    }

    @Test("hiding keeps the section and its place; removing drops it")
    func hideAndRemove() {
        var page = HomePage(sections: [reading, latest, related])
        page.setEnabled(false, section: latest.id)
        #expect(page.sections.map(\.id) == [reading.id, latest.id, related.id])
        #expect(page.sections[1].isEnabled == false)
        page.setEnabled(true, section: latest.id)
        #expect(page.sections[1].isEnabled)
        page.removeSection(latest.id)
        #expect(page.sections.map(\.id) == [reading.id, related.id])
    }

    @Test("an edit saves the page, and does nothing before there is one")
    func storeEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("home-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("explore_home.json")
        let store = HomePageStore(fileURL: url)
        store.edit { $0.removeSection(reading.id) }
        #expect(store.page == nil)

        store.save(HomePage(sections: [reading, latest]))
        store.edit { $0.setEnabled(false, section: reading.id) }
        store.waitForPendingWritesForTesting()
        let reread = HomePageStore(fileURL: url)
        #expect(reread.page?.sections.first?.isEnabled == false)
    }

    // The maintainer, 2026-10-27: 色帶書架 is the 頂部輪播圖, set from 編輯首頁's header.

    @Test("the page's first band is the 輪播圖, hidden or not, and the editor's list leaves it out")
    func carouselIsTheFirstBand() {
        let band = HomeSection(layout: .band, binding: .latest)
        let laterBand = HomeSection(layout: .band, binding: .related)
        var page = HomePage(sections: [reading, band, laterBand])
        #expect(page.carouselSection?.id == band.id)
        #expect(page.editableSections.map(\.id) == [reading.id, laterBand.id])
        page.setEnabled(false, section: band.id)
        #expect(page.carouselSection?.id == band.id, "a hidden 輪播圖 is still the 輪播圖")
        #expect(HomePage(sections: [reading, latest]).carouselSection == nil)
    }

    @Test("reordering the listed sections leaves the 輪播圖 where it stands")
    func moveSkipsTheCarousel() {
        let band = HomeSection(layout: .band, binding: .latest)
        var page = HomePage(sections: [reading, band, related])
        page.moveEditable(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(page.sections.map(\.id) == [related.id, band.id, reading.id])
    }

    @Test("選擇輪播數據 changes what the 輪播圖 shows, and shows it; a page without one gets one first")
    func chooseCarousel() throws {
        var band = HomeSection(layout: .band, title: "舊名", subtitle: "舊副標", binding: .latest)
        band.isEnabled = false
        var page = HomePage(sections: [reading, band])
        page.setCarousel(.gutenbergCollection(id: "poetry"), parameters: ["sort": "new"])
        let carousel = try #require(page.carouselSection)
        #expect(carousel.id == band.id)
        #expect(carousel.binding == .gutenbergCollection(id: "poetry"))
        #expect(carousel.parameters == ["sort": "new"])
        #expect(carousel.title.isEmpty && carousel.subtitle.isEmpty, "the 輪播圖 takes the list's own name")
        #expect(carousel.isEnabled)
        #expect(page.sections.count == 2)

        var plain = HomePage(sections: [reading, latest])
        plain.setCarousel(.related, title: "猜你喜歡")
        #expect(plain.sections.count == 3)
        #expect(plain.sections.first?.layout == .band)
        #expect(plain.sections.first?.binding == .related)
        #expect(plain.sections.first?.title == "猜你喜歡")
        #expect(plain.carouselSection?.id == plain.sections.first?.id)
    }

    @Test("關閉輪播圖 hides it and keeps what it shows; 開啟輪播圖 shows it again")
    func toggleCarousel() {
        let band = HomeSection(layout: .band, binding: .latest)
        var page = HomePage(sections: [reading, band])
        page.setCarouselShown(false)
        #expect(page.carouselSection?.isEnabled == false)
        #expect(page.carouselSection?.binding == .latest)
        page.setCarouselShown(true)
        #expect(page.carouselSection?.isEnabled == true)
        var plain = HomePage(sections: [reading])
        plain.setCarouselShown(false)
        #expect(plain.sections == [reading], "a page without a 輪播圖 is left alone")
    }

    @Test("選擇輪播數據 offers only what shows books: no list of lists, articles or author index")
    func carouselOffersBooks() {
        #expect(HomeSectionBinding.latest.showsBooks)
        #expect(HomeSectionBinding.gutenbergCollection(id: "poetry").showsBooks)
        #expect(!HomeSectionBinding.gutenbergLists.showsBooks)
        #expect(!HomeSectionBinding.subscriptionArticles.showsBooks)
        #expect(!HomeSectionBinding.aozoraIndex(kind: AozoraBrowseMode.authors.rawValue).showsBooks)
    }
}
