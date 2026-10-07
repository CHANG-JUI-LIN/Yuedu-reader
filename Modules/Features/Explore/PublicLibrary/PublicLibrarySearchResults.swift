import SwiftUI

/// Local matches update as the query changes. Gutenberg starts only from an
/// explicit submit (keyboard Search or the catalog search button).
struct PublicLibrarySearchResults: View {
    let query: String
    let index: AozoraCatalogIndex?
    let submitGutenberg: () -> Void
    var select: (PublicLibraryBookSelection) -> Void = { _ in }

    var body: some View {
        Section(localized("Project Gutenberg")) {
            Button(action: submitGutenberg) {
                Label(String(format: localized("在 Project Gutenberg 搜尋「%@」"), query), systemImage: "magnifyingglass")
            }.accessibilityIdentifier("publicLibrary.searchGutenberg")
        }.interfaceSectionSurface()
        if let index {
            let matches = index.search(query)
            Section(localized("青空文庫")) {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(Array(matches.prefix(50))) { work in
                        Button {
                            if let selection = PublicLibraryBookSelection(books: matches.map { .aozora($0, index) }, selectedID: "aozora:" + work.id) {
                                select(selection)
                            }
                        } label: {
                            AozoraWorkRow(work: work, index: index)
                        }
                    }
                    if matches.count > 50 {
                        NavigationLink(localized("顯示全部")) {
                            AozoraWorksView(index: index, works: matches, title: query)
                        }
                    }
                }
            }.interfaceSectionSurface()
        }
    }
}

#Preview {
    NavigationStack {
        List { PublicLibrarySearchResults(query: "猫", index: .preview, submitGutenberg: {}) }
    }.environmentObject(BookStore())
}
