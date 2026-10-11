import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3b: one section per group, 最新's sources in turn, and 範圍 as a filter
/// over the same home (Phase 5 plan, decision 19).
@MainActor
@Suite("Home section groups")
struct HomeSectionGroupTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)

    private func row(_ section: HomeSection, _ source: SourceInstanceKey, _ state: HomeModel.RowState) -> HomeModel.Row {
        HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                      sourceName: source.id, policy: .parallel, state: state)
    }

    private func gutenbergItem(_ number: Int) -> CollectionEntry {
        CollectionEntry.bundledGutenberg(GutenbergBook(id: number, title: "\(number)", author: "A"))
    }

    private func aozoraItem(_ id: String) -> CollectionEntry {
        let record = SourceRecord(key: SourceItemKey(instance: aozora, item: id), title: id, authors: [], language: "ja",
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [])
        return .item(record, WorkSummary(title: id, authors: [], cover: nil, blurb: nil, language: "ja", contentKind: .text),
                     .copy(UUID()))
    }

    /// A shelf copy whose current source is `source`, as `SourceRecord.derived(from:)` keys it.
    private func shelfCopy(of source: SourceInstanceKey?, title: String) -> CollectionEntry {
        let id = UUID()
        let key = source.map { SourceItemKey(instance: $0, item: title) } ?? .copy(id)
        let record = SourceRecord(key: key, title: title, authors: [], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [.openCopy(id)])
        return .item(record, WorkSummary(title: title, authors: [], cover: nil, blurb: nil, language: nil, contentKind: .text),
                     .copy(id))
    }

    private func titles(_ state: HomeModel.RowState) -> [String] {
        guard case .loaded(let entries) = state else { return [] }
        return entries.compactMap { entry in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
    }

    @Test("最新's rows are one section, their books taking turns in provider order")
    func latestIsOneSection() {
        let latest = HomeSection(layout: .row, binding: .latest(excluded: []))
        let reading = HomeSection(layout: .readingCard, binding: .continueReading)
        let rows = [
            row(reading, .localLibrary, .loaded([])),
            row(latest, gutenberg, .loaded([gutenbergItem(1), gutenbergItem(2), gutenbergItem(3)])),
            row(latest, aozora, .loaded([aozoraItem("a"), aozoraItem("b")])),
        ]
        let groups = HomeScopeFilter.groups(rows, in: nil)
        #expect(groups.map(\.section.id) == [reading.id, latest.id])
        #expect(groups[1].rows.count == 2)
        #expect(titles(groups[1].state) == ["1", "a", "2", "b", "3"])
        #expect(groups[1].title == localized("最新"))
    }

    @Test("a section shows books as soon as one source has some; else it loads, fails, or takes no room")
    func mergedState() {
        let latest = HomeSection(layout: .row, binding: .latest(excluded: []))
        func state(_ states: [HomeModel.RowState]) -> HomeModel.RowState {
            let sources = [gutenberg, aozora, SourceInstanceKey(type: .opds, id: "c")]
            return HomeScopeFilter.groups(zip(sources, states).map { row(latest, $0, $1) }, in: nil)[0].state
        }
        #expect(titles(state([.loading, .loaded([gutenbergItem(7)]), .failed("x")])) == ["7"])
        #expect(state([.loading, .loaded([]), .failed("x")]) == .loading)
        #expect(state([.idle, .failed("x")]) == .loading)
        #expect(state([.loaded([]), .failed("first"), .failed("second")]) == .failed("first"))
        #expect(state([.loaded([]), .loaded([])]) == .loaded([]))
        #expect(HomeScopeFilter.groups([row(latest, gutenberg, .loaded([]))], in: nil)[0].isSettledEmpty)
    }

    @Test("範圍 keeps the chosen source's rows and its copies in the shelf's rows; the rest goes")
    func scopeFilters() {
        let reading = HomeSection(layout: .readingCard, binding: .continueReading)
        let featured = HomeSection(layout: .row, binding: .gutenbergCollection(id: "chinese"))
        let latest = HomeSection(layout: .row, binding: .latest(excluded: []))
        let rows = [
            row(reading, .localLibrary, .loaded([
                shelfCopy(of: gutenberg, title: "紅樓夢"), shelfCopy(of: aozora, title: "こころ"),
                shelfCopy(of: nil, title: "本機檔案"), .location(CollectionLocation(id: "group/x", title: "分組")),
            ])),
            row(featured, gutenberg, .loaded([gutenbergItem(24264)])),
            row(latest, gutenberg, .loaded([gutenbergItem(1)])),
            row(latest, aozora, .loaded([aozoraItem("a")])),
        ]

        let all = HomeScopeFilter.groups(rows, in: nil)
        #expect(all.count == 3)
        #expect(titles(all[0].state) == ["紅樓夢", "こころ", "本機檔案"])

        let onlyAozora = HomeScopeFilter.groups(rows, in: aozora)
        #expect(onlyAozora.map(\.section.id) == [reading.id, latest.id])
        #expect(titles(onlyAozora[0].state) == ["こころ"])
        #expect(titles(onlyAozora[1].state) == ["a"])
        #expect(onlyAozora[1].rows.map(\.source) == [aozora])

        let onlyGutenberg = HomeScopeFilter.groups(rows, in: gutenberg)
        #expect(onlyGutenberg.map(\.section.id) == [reading.id, featured.id, latest.id])
        #expect(titles(onlyGutenberg[0].state) == ["紅樓夢"])

        // A source no section draws from: the shelf's rows stay, with nothing of it in them.
        let other = HomeScopeFilter.groups(rows, in: SourceInstanceKey(type: .opds, id: "nas"))
        #expect(other.map(\.section.id) == [reading.id])
        #expect(other[0].isSettledEmpty)
    }
}
