import SwiftUI

/// The 公有書庫 section of a search (unified library 5d-1b): Gutenberg's search to submit,
/// then 青空文庫's matches, which update as the query changes. Gutenberg starts only from an
/// explicit submit (keyboard Search or this row), as its terms ask (`PublicLibraries.md`).
struct PublicLibrarySearchResults: View {
    let query: String
    let index: AozoraCatalogIndex?
    /// The first row measures the list's scroll for the 搜索 tab's title, when nothing is
    /// above it.
    var anchorsTitle = false
    let submitGutenberg: () -> Void
    var select: (PublicLibraryBookSelection) -> Void = { _ in }

    /// Rows listed before 顯示全部.
    static let visibleMatchCount = 50

    var body: some View {
        Section(localized("公有書庫")) {
            Button(action: submitGutenberg) {
                Label(String(format: localized("在 Project Gutenberg 搜尋「%@」"), query), systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("publicLibrary.searchGutenberg")
            .background {
                if anchorsTitle { Color.clear.rootTabTitleScrollAnchor() }
            }
            if let index {
                let matches = index.search(query)
                ForEach(Array(matches.prefix(Self.visibleMatchCount))) { work in
                    Button {
                        if let selection = PublicLibraryBookSelection(books: matches.map { .aozora($0, index) }, selectedID: "aozora:" + work.id) {
                            select(selection)
                        }
                    } label: {
                        AozoraWorkRow(work: work, index: index)
                    }
                }
                if matches.count > Self.visibleMatchCount {
                    NavigationLink(localized("顯示全部"),
                                   value: PublicLibraryRoute.aozoraWorks(title: query, works: matches, index: index))
                }
            }
        }
        .listRowBackground(Color.clear)
    }
}

#Preview {
    NavigationStack {
        List { PublicLibrarySearchResults(query: "猫", index: .preview, submitGutenberg: {}) }
            .listStyle(.plain)
    }.environmentObject(BookStore())
}
