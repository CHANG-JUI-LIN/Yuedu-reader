import SwiftUI

struct SearchView: View {
    var initialQuery: String = ""
    var sessionScope: SearchSourceScope?
    /// The 搜索 tab's own root, which carries a tab root's title.
    var isTabRoot = false

    var body: some View {
        BookSearchView(initialQuery: initialQuery, sessionScope: sessionScope, isTabRoot: isTabRoot)
    }
}

/// The 搜索 tab: its stack, with the store's pages and book carousel for the public
/// libraries it searches (unified library 5d-1b, Phase 5 plan decision 17).
struct SearchTabRoot: View {
    @State private var path = NavigationPath()
    @State private var selection: PublicLibraryBookSelection?
    @State private var coverFrames = PublicLibraryCoverFrames()

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(isTabRoot: true)
                .remoteLibraryDestinations()
                .publicLibraryDestinations()
        }
        .publicLibraryBookCarousel(path: $path, request: $selection, coverFrames: coverFrames)
    }
}

#Preview("搜索 tab") {
    SearchTabRoot()
        .environmentObject(BookStore())
}
