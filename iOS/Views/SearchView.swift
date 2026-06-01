import SwiftUI

struct SearchView: View {
    var initialQuery: String = ""

    var body: some View {
        BookSearchView(initialQuery: initialQuery)
    }
}
