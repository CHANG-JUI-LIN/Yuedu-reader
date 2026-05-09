import SwiftUI

struct RSSRootView: View {
    var body: some View {
        NavigationStack {
            RSSListView()
        }
    }
}

#Preview("RSS Root") {
    RSSRootView()
}
