import Combine
import Foundation

/// Loads one custom explore page's blocks a category at a time, as a source's page loads
/// its sections, so a page of many blocks never fires every request at once. Each block
/// asks for its categories as it scrolls on; the waterfall at the end goes on to further
/// pages as the reader reaches its bottom.
@MainActor
final class CustomExplorePageModel: ObservableObject {
    /// One block as the page draws it: its component, its source, and a section for each
    /// of its categories.
    struct Block: Identifiable {
        let component: CustomExploreComponent
        /// Nil once the source has been deleted.
        let source: BookSource?
        var sections: [DiscoverShowcaseSection]
        var id: UUID { component.id }
    }

    /// The waterfall's pages after its first, which loads as any section does.
    struct WaterfallPaging {
        /// The section these pages belong to; another waterfall starts over.
        var sectionID: UUID?
        var paging = SectionPaging(firstPageLoaded: true)

        var nextPage: Int { paging.nextPage }
        var hasMore: Bool { paging.hasMore }
        var isLoading: Bool { paging.isLoading }
        var errorReason: String? { paging.errorReason }
    }

    private let pageLoader: SectionPageLoader

    init(pageLoader: SectionPageLoader = .live) {
        self.pageLoader = pageLoader
    }

    @Published private(set) var blocks: [Block] = []
    @Published private(set) var waterfallPaging = WaterfallPaging()

    private var queueTail: Task<Void, Never>?
    /// Sections already asked for, by id; a block rebuilt for an edit has new ones.
    private var requested: Set<UUID> = []

    /// Builds the blocks for the page as it now stands. A block whose component and
    /// source are unchanged keeps what it has loaded.
    func sync(with page: CustomExplorePage) {
        let existing = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let sources = BookSourceStore.shared.sources
        blocks = page.components.map { component in
            let source = component.sourceURL.flatMap { url in sources.first { $0.bookSourceUrl == url } }
            if let kept = existing[component.id],
               kept.component == component,
               kept.source?.lastUpdateTime == source?.lastUpdateTime {
                return kept
            }
            let sections = source.map { source in
                component.categories.compactMap { reference in
                    reference.cardItem.map {
                        DiscoverShowcaseSection(
                            item: $0,
                            coverBaseURL: source.bookSourceUrl,
                            coverHeaders: source.parsedHeaders
                        )
                    }
                }
            } ?? []
            return Block(component: component, source: source, sections: sections)
        }
        requested.formIntersection(blocks.flatMap { $0.sections.map(\.id) })
        let waterfallSectionID = blocks.first { $0.component.kind == .waterfall }?.sections.first?.id
        if waterfallSectionID != waterfallPaging.sectionID {
            waterfallPaging = WaterfallPaging(sectionID: waterfallSectionID)
        }
    }

    /// Asks for a section's first page, once.
    func load(_ sectionID: UUID) {
        guard !requested.contains(sectionID) else { return }
        requested.insert(sectionID)
        enqueue(sectionID)
    }

    func retry(_ sectionID: UUID) {
        enqueue(sectionID)
    }

    /// Pull to refresh: everything already loaded loads again from its first page.
    func reload() {
        let previouslyRequested = requested
        requested.removeAll()
        for blockIndex in blocks.indices {
            for sectionIndex in blocks[blockIndex].sections.indices {
                blocks[blockIndex].sections[sectionIndex].books = []
                blocks[blockIndex].sections[sectionIndex].phase = .idle
                blocks[blockIndex].sections[sectionIndex].errorReason = nil
            }
        }
        waterfallPaging = WaterfallPaging(sectionID: waterfallPaging.sectionID)
        for block in blocks {
            for section in block.sections where previouslyRequested.contains(section.id) {
                load(section.id)
            }
        }
    }

    /// The waterfall's next page, appended below what it shows.
    func loadMoreWaterfall() {
        guard let blockIndex = blocks.firstIndex(where: { $0.component.kind == .waterfall }),
              let source = blocks[blockIndex].source,
              let section = blocks[blockIndex].sections.first,
              section.phase == .loaded,
              section.id == waterfallPaging.sectionID,
              let page = waterfallPaging.paging.start() else { return }
        let existing = section.books.map(\.book)
        let loader = pageLoader
        Task { [weak self] in
            do {
                let displays = try await loader.books(page: page, of: section, in: source, after: existing)
                self?.applyWaterfallPage(displays, page: page, sectionID: section.id)
            } catch {
                self?.applyWaterfallError(error.localizedDescription, sectionID: section.id)
            }
        }
    }

    // MARK: - Loading

    private func enqueue(_ sectionID: UUID) {
        let previous = queueTail
        queueTail = Task { [weak self] in
            await previous?.value
            await self?.fetch(sectionID)
        }
    }

    private func location(of sectionID: UUID) -> (block: Int, section: Int)? {
        for blockIndex in blocks.indices {
            if let sectionIndex = blocks[blockIndex].sections.firstIndex(where: { $0.id == sectionID }) {
                return (blockIndex, sectionIndex)
            }
        }
        return nil
    }

    private func fetch(_ sectionID: UUID) async {
        guard let found = location(of: sectionID),
              let source = blocks[found.block].source else { return }
        let section = blocks[found.block].sections[found.section]
        blocks[found.block].sections[found.section].phase = .loading
        blocks[found.block].sections[found.section].errorReason = nil
        do {
            let books = try await pageLoader.fetchPage(section.item.raw, 1, source)
            let displays = await DiscoverViewModel.makeDisplays(books, source: source)
            // The block may have been edited or removed while this loaded.
            guard let current = location(of: sectionID) else { return }
            blocks[current.block].sections[current.section].books = displays
            blocks[current.block].sections[current.section].phase = .loaded
        } catch {
            AppLogger.network("⟐ custom explore block failed", error: error, context: [
                "category": section.title, "source": source.bookSourceName
            ])
            guard let current = location(of: sectionID) else { return }
            blocks[current.block].sections[current.section].phase = .failed
            blocks[current.block].sections[current.section].errorReason = error.localizedDescription
        }
    }

    private func applyWaterfallPage(_ displays: [DiscoverBookDisplay], page: Int, sectionID: UUID) {
        guard sectionID == waterfallPaging.sectionID, let found = location(of: sectionID) else { return }
        blocks[found.block].sections[found.section].books.append(contentsOf: displays)
        waterfallPaging.paging.receive(newBooks: displays.count, page: page)
    }

    private func applyWaterfallError(_ reason: String, sectionID: UUID) {
        guard sectionID == waterfallPaging.sectionID else { return }
        waterfallPaging.paging.fail(reason)
    }
}
