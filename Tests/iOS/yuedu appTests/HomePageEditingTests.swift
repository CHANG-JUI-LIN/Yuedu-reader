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
    private let latest = HomeSection(layout: .row, binding: .latest(excluded: []))
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

    @Test("排除的來源 changes 最新 alone")
    func excluded() {
        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        var page = HomePage(sections: [reading, latest])
        page.setExcluded([gutenberg], section: latest.id)
        page.setExcluded([gutenberg], section: reading.id)
        #expect(page.sections[1].binding == .latest(excluded: [gutenberg]))
        #expect(page.sections[0].binding == .continueReading)
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
}
