import SwiftUI

/// 探索's root: the home (unified library 5c-3), once the source library is read.
struct ExploreTabRoot: View {
    let chrome: ExploreTabChrome
    @ObservedObject private var model = ExploreTabModel.shared

    var body: some View {
        if model.isLoaded {
            ExploreHome(chrome: chrome)
        } else {
            // The source library is still being read (about a second at 50 000 sources); the
            // home's default sections depend on whether it holds any, and are saved for good
            // the first time it draws.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    NavigationStack {
        ExploreTabRoot(chrome: ExploreTabChrome())
    }
    .environmentObject(BookStore())
}
