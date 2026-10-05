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
///
/// A tab bar at the bottom also shows on a tab's root page only: any page over the root —
/// pushed, or presented as a sheet, a full-screen cover or a popover — hides it; a menu
/// does not.
/// `TabRootCoverage` reports which roots are covered; the selected tab's root decides.
@MainActor
final class RootTabBarVisibility: ObservableObject {
    @Published private(set) var isTabBarHidden = false
    private var hidingRequests: Set<UUID> = []
    /// The tabs whose root page has another page over it, by `\.rootTabBarTab`.
    private var coveredRoots: Set<String> = []
    private var selectedTab: String?
    /// Whether a covered root hides the tab bar: where it sits at the bottom. Off where
    /// iPad's `.sidebarAdaptable` puts it at the top, which keeps the screens' own requests.
    private var hidesOverCoveredRoot = true

    func setRequest(_ id: UUID, hidesTabBar: Bool) {
        if hidesTabBar {
            hidingRequests.insert(id)
        } else {
            hidingRequests.remove(id)
        }
        update()
    }

    func setCoveredRoots(_ tabs: Set<String>) {
        guard tabs != coveredRoots else { return }
        coveredRoots = tabs
        update()
    }

    func isRootCovered(_ tab: String) -> Bool {
        coveredRoots.contains(tab)
    }

    func setSelectedTab(_ tab: String) {
        selectedTab = tab
        update()
    }

    func setHidesOverCoveredRoot(_ hides: Bool) {
        hidesOverCoveredRoot = hides
        update()
    }

    private func update() {
        let isSelectedRootCovered = selectedTab.map(coveredRoots.contains) ?? false
        let hidden = !hidingRequests.isEmpty || (hidesOverCoveredRoot && isSelectedRootCovered)
        guard hidden != isTabBarHidden else { return }
        isTabBarHidden = hidden
        AppLogger.info("⟐ tab bar: \(hidden ? "hidden" : "shown")", context: [
            "selectedTab": selectedTab ?? "-",
            "coveredRoots": coveredRoots.sorted().joined(separator: ","),
            "requests": hidingRequests.count,
            "hidesOverCoveredRoot": hidesOverCoveredRoot,
        ])
    }
}

private struct RootTabBarVisibilityKey: EnvironmentKey {
    static let defaultValue: RootTabBarVisibility? = nil
}

private struct RootTabBarTabKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Nil outside the app's root (previews, tests): the screen then only hides its own
    /// tab's bar, as before.
    var rootTabBarVisibility: RootTabBarVisibility? {
        get { self[RootTabBarVisibilityKey.self] }
        set { self[RootTabBarVisibilityKey.self] = newValue }
    }

    /// The root tab a screen sits in — `ContentView` names each tab's content — for its
    /// root page to report whether it is covered. Nil outside the app's tabs.
    var rootTabBarTab: String? {
        get { self[RootTabBarTabKey.self] }
        set { self[RootTabBarTabKey.self] = newValue }
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

#Preview("Root tab bar on the tab roots only") {
    @Previewable @StateObject var visibility = RootTabBarVisibility()
    @Previewable @State var selectedTab = "one"
    @Previewable @State var isSelecting = false
    @Previewable @State var showsSheet = false
    TabView(selection: $selectedTab) {
        NavigationStack {
            List {
                NavigationLink("Pushed page") { Text("Pushed") }
                Button("Sheet") { showsSheet = true }
                Toggle("Selecting hides the tab bar", isOn: $isSelecting)
            }
            .showsRootTabBarOnlyHere()
            .hidesRootTabBar(isSelecting)
            .sheet(isPresented: $showsSheet) { Text("Sheet") }
        }
        .environment(\.rootTabBarTab, "one")
        .background { RootTabBarHider(visibility: visibility) }
        .tag("one")
        .tabItem { Label("One", systemImage: "1.circle") }

        NavigationStack {
            Text("Two").showsRootTabBarOnlyHere()
        }
        .environment(\.rootTabBarTab, "two")
        .background { RootTabBarHider(visibility: visibility) }
        .tag("two")
        .tabItem { Label("Two", systemImage: "2.circle") }
    }
    .environment(\.rootTabBarVisibility, visibility)
    .onChange(of: selectedTab, initial: true) { _, tab in visibility.setSelectedTab(tab) }
}
