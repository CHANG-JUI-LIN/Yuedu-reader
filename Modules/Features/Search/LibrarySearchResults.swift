import SwiftUI

/// One book a saved library (unified search 4b-2), a module (Phase 6g) or Open Library (4b-3)
/// found for 搜索, as the home draws one of its items, with the 作品詳情 route frozen when it
/// was found.
struct LibrarySearchMatch: Identifiable {
    /// Made once, when the answer arrives, so the iOS 17 table can diff its rows.
    let id = UUID()
    let card: HomeCardContent
    let route: WorkDetailRoute
    let connectionID: String
    /// The row's detail line: the library's or module's name.
    let detail: String

    var rowContent: SearchBookListRowContent {
        SearchBookListRowContent(title: card.title, titleTag: nil, author: card.author, detail: detail)
    }
}

/// A library that could not answer, with why: its status line (design §16 item 4).
struct LibrarySearchFailure: Identifiable, Equatable {
    let id: String
    let name: String
    let reason: String

    /// 「Calibre：無法搜尋（原因）」.
    var line: String {
        String(format: localized("%@：無法搜尋（%@）"), name, reason)
    }
}

/// A section of 搜索 asked on submit, each place answering on its own: 我的書庫 (the saved OPDS
/// and Calibre libraries, unified search 4b-2, and the installed modules, Phase 6g) and 書目資料庫
/// (Open Library, 4b-3). Owned by the search page and read only by the views that draw it.
@Observable
@MainActor
final class LibrarySearchModel {
    private(set) var matches: [LibrarySearchMatch] = []
    private(set) var failures: [LibrarySearchFailure] = []
    private(set) var isSearching = false
    /// Its parts, asked together; the section searches until the last has answered.
    @ObservationIgnored private let searches: [any SearchAnswering]
    @ObservationIgnored private var running: Task<Void, Never>?

    /// The saved libraries and the modules, each row naming its place.
    init(searches: [any SearchAnswering]? = nil) {
        self.searches = searches ?? [LibrarySearch(), ModuleSearch()]
    }

    convenience init(search: any SearchAnswering) {
        self.init(searches: [search])
    }

    var isAvailable: Bool { searches.contains { $0.isAvailable } }

    func start(_ query: String, store: BookStore) {
        clear()
        let available = searches.indices.filter { searches[$0].isAvailable }
        guard !available.isEmpty else { return }
        isSearching = true
        running = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for index in available {
                    group.addTask { @MainActor in
                        await self.searches[index].search(query) { answer in
                            guard !Task.isCancelled else { return }
                            self.add(answer, store: store)
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    func clear() {
        running?.cancel()
        running = nil
        isSearching = false
        if !matches.isEmpty { matches = [] }
        if !failures.isEmpty { failures = [] }
    }

    #if DEBUG
    func waitForTesting() async { await running?.value }

    /// An answer as if a library had sent it, for previews.
    func receiveForPreview(_ answer: LibrarySearchAnswer, store: BookStore) { add(answer, store: store) }
    #endif

    private func add(_ answer: LibrarySearchAnswer, store: BookStore) {
        switch answer.outcome {
        case .results:
            let lookup = store.copyLookup()
            matches += answer.entries.compactMap { entry in
                guard let card = HomeCardContent(entry, status: lookup.status(for:), shelfBooks: [:]),
                      let route = card.route else { return nil }
                return LibrarySearchMatch(card: card, route: route, connectionID: answer.connectionID,
                                          detail: answer.name)
            }
        case .failed(let reason):
            failures.append(LibrarySearchFailure(id: answer.connectionID, name: answer.name, reason: reason))
        case .empty, .noSearch:
            break
        }
    }
}
