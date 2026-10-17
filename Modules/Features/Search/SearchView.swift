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

#Preview("搜索 tab") {
    NavigationStack {
        SearchView(isTabRoot: true)
    }
    .environmentObject(BookStore())
}
