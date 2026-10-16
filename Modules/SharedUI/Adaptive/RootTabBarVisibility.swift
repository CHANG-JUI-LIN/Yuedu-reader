import Combine
import SwiftUI

/// Which screens, anywhere in the app, are asking for the root tab bar to be hidden
/// right now — the one place every tab reads that answer from.
///
/// SwiftUI's TabView keeps a hosting controller for each tab that has been opened, and
/// each one pushes *its own* tab's tab-bar visibility onto the one shared tab bar whenever
/// its preferences change, selected or not (`BarAppearanceBridge.updateTabBarVisibility`,
/// traced on the iOS 26.5 simulator). A screen that hid the tab bar only for its own tab
/// therefore lost it to the next update of any other opened tab: with 探索 and 設定
/// opened earlier, the reader's 白天/深色 button changing `GlobalSettings` showed the tab
/// bar over the reader until the reader's own bars next changed. Every tab now hides it
/// while any screen asks (`ContentView` puts `RootTabBarHider` behind each tab), so the
/// order of those updates no longer matters.
@MainActor
final class RootTabBarVisibility: ObservableObject {
    @Published private(set) var isTabBarHidden = false
    private var hidingRequests: Set<UUID> = []

    func setRequest(_ id: UUID, hidesTabBar: Bool) {
        if hidesTabBar {
            hidingRequests.insert(id)
        } else {
            hidingRequests.remove(id)
        }
        let hidden = !hidingRequests.isEmpty
        if hidden != isTabBarHidden { isTabBarHidden = hidden }
    }
}

private struct RootTabBarVisibilityKey: EnvironmentKey {
    static let defaultValue: RootTabBarVisibility? = nil
}

extension EnvironmentValues {
    /// Nil outside the app's root (previews, tests): the screen then only hides its own
    /// tab's bar, as before.
    var rootTabBarVisibility: RootTabBarVisibility? {
        get { self[RootTabBarVisibilityKey.self] }
        set { self[RootTabBarVisibilityKey.self] = newValue }
    }
}

/// Behind every tab: hides the tab bar from that tab too while any screen asks.
///
/// A background, not a `.toolbar(_:for: .tabBar)` on the tab's content: one on the
/// content overrides the tab's own screens — `.automatic` there kept the tab bar over
/// 書架's 選取 mode, which hides it for its own bottom toolbar (iOS 26.5 simulator). And
/// the `if` lives in here so the tab's content keeps its identity; swapping that would
/// reset the tab's navigation stack.
struct RootTabBarHider: View {
    @ObservedObject var visibility: RootTabBarVisibility

    var body: some View {
        if visibility.isTabBarHidden {
            Color.clear
                .toolbar(.hidden, for: .tabBar)
                .accessibilityHidden(true)
        }
    }
}

private struct RootTabBarHidingModifier: ViewModifier {
    let hidesTabBar: Bool
    @Environment(\.rootTabBarVisibility) private var rootTabBar
    @State private var requestID = UUID()
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
            .onAppear {
                isOnScreen = true
                rootTabBar?.setRequest(requestID, hidesTabBar: hidesTabBar)
            }
            .onDisappear {
                isOnScreen = false
                rootTabBar?.setRequest(requestID, hidesTabBar: false)
            }
            .onChange(of: hidesTabBar) { _, hides in
                guard isOnScreen else { return }
                rootTabBar?.setRequest(requestID, hidesTabBar: hides)
            }
    }
}

extension View {
    /// Hides the root tab bar while this screen is on screen and `hides` holds — in
    /// place of `.toolbar(.hidden, for: .tabBar)`, which only answers for this screen's
    /// own tab (see `RootTabBarVisibility`).
    func hidesRootTabBar(_ hides: Bool = true) -> some View {
        modifier(RootTabBarHidingModifier(hidesTabBar: hides))
    }
}

#Preview("Root tab bar hidden from every tab") {
    @Previewable @StateObject var visibility = RootTabBarVisibility()
    @Previewable @State var showsDetail = false
    TabView {
        NavigationStack {
            List {
                Toggle("Detail hides the tab bar", isOn: $showsDetail)
            }
            .navigationDestination(isPresented: $showsDetail) {
                Text("Detail").hidesRootTabBar()
            }
        }
        .background { RootTabBarHider(visibility: visibility) }
        .tabItem { Label("One", systemImage: "1.circle") }

        Text("Two")
            .background { RootTabBarHider(visibility: visibility) }
            .tabItem { Label("Two", systemImage: "2.circle") }
    }
    .environment(\.rootTabBarVisibility, visibility)
}
