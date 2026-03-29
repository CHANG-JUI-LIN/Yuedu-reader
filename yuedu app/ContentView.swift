import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label(gs.t("書架"), systemImage: "books.vertical") }

            BrowserView()
                .tabItem { Label(gs.t("瀏覽"), systemImage: "globe") }

            SettingsView()
                .tabItem { Label(gs.t("設定"), systemImage: "gearshape") }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BookStore())
}
