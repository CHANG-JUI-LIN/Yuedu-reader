import Combine
import SwiftUI
import UIKit

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

    /// Whether a reader in a tab's stack is on screen: the tabs' sidebar is then out of
    /// reach as well as the tab bar (`RootTabSidebarGate`).
    @Published private(set) var isSidebarKeptAway = false
    private var sidebarRequests: Set<UUID> = []

    func setSidebarRequest(_ id: UUID, keepsSidebarAway: Bool) {
        if keepsSidebarAway {
            sidebarRequests.insert(id)
        } else {
            sidebarRequests.remove(id)
        }
        let keptAway = !sidebarRequests.isEmpty
        if keptAway != isSidebarKeptAway { isSidebarKeptAway = keptAway }
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
///
/// No `accessibilityHidden` on the clear colour, which is no accessibility element to begin
/// with: a view carrying that modifier in a background can make SwiftUI order the content's
/// accessibility elements by position (see `RootTabBarHidingModifier`).
struct RootTabBarHider: View {
    @ObservedObject var visibility: RootTabBarVisibility

    var body: some View {
        if visibility.isTabBarHidden {
            Color.clear
                .toolbar(.hidden, for: .tabBar)
        }
    }
}

private struct RootTabBarHidingModifier: ViewModifier {
    let hidesTabBar: Bool
    let hasBottomBar: Bool
    @Environment(\.rootTabBarVisibility) private var rootTabBar
    @State private var requestID = UUID()
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            // The hidden bar would otherwise still blur the bottom of this page's scroll
            // views. A page with a bar of its own there is left alone: the effect is that
            // bar's, and whatever the page set for its edges stands.
            .modifier(HiddenBottomScrollEdge(isHidden: hidesTabBar, appliesToPage: !hasBottomBar))
            // Hidden while it hides, and nothing otherwise: `.automatic` is not "no preference".
            // On a stack's root it overrode the `.hidden` of every page pushed over it, which
            // left the tab bar over 探索's readers on iOS 17 (FB-100, iOS 17.5 simulator), as it
            // kept the bar over 書架's 選取 mode from a tab's content (`RootTabBarHider`). In a
            // background, as there, so `content` keeps its identity.
            //
            // The clear colour carries no `accessibilityHidden`: a colour is no accessibility
            // element, and a view with that modifier in a background, whatever its value,
            // makes SwiftUI order the page's accessibility elements by position. On a page
            // that is a full-screen UIKit view under SwiftUI bars, the bottom bar then comes
            // after the view, and VoiceOver's touch, which takes the first element under the
            // finger, lands on the view (the shape of feedback #15). Seen 2026-11-14 in
            // `NavigationBackSwipeReservationTests`, with and without a `TabView`. The app's
            // own reader was not affected: with the modifier and without it, VoiceOver's hit
            // test found 目錄, 深色, 聽書, 主題, 更多 and the progress slider (iOS 27.2
            // simulator, opened from 書架 and from 探索).
            .background {
                if hidesTabBar {
                    Color.clear
                        .toolbar(.hidden, for: .tabBar)
                }
            }
            // On iOS 27 the bar is covered by this page as it slides in, and uncovered as it
            // slides away (`RootTabBarTransitionCover`).
            .modifier(RootTabBarTransitionCovering(hidesTabBar: hidesTabBar))
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
    /// own tab (see `RootTabBarVisibility`). `hasBottomBar` is for a page that puts a bar
    /// of its own where the tab bar was: its scroll views keep their bottom edge effect
    /// (`HiddenBottomScrollEdge`).
    func hidesRootTabBar(_ hides: Bool = true, hasBottomBar: Bool = false) -> some View {
        modifier(RootTabBarHidingModifier(hidesTabBar: hides, hasBottomBar: hasBottomBar))
    }
}

// MARK: - Sidebar

private struct RootTabSidebarKeptAwayModifier: ViewModifier {
    @Environment(\.rootTabBarVisibility) private var rootTabBar
    @State private var requestID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { rootTabBar?.setSidebarRequest(requestID, keepsSidebarAway: true) }
            .onDisappear { rootTabBar?.setSidebarRequest(requestID, keepsSidebarAway: false) }
    }
}

extension View {
    /// For a reader: while it is on screen, the root tabs' sidebar cannot be opened over it.
    ///
    /// Hiding the tab bar does not do that. On an iPad the root tabs are `.sidebarAdaptable`
    /// (iOS 18+), and on iOS 27 the sidebar still slid in over the page from a swipe at the
    /// leading edge, where a reader's swipe back is (FB-206: iOS 27.2 iPad simulator, a
    /// reader pushed from 作品詳情 or 探索; on iOS 26.5 the same swipe already went back).
    /// With the sidebar away that swipe leaves the reader, and a sidebar that was open
    /// beside the page closes for the reader and opens again after it. Only readers ask; the
    /// other pages that hide the tab bar keep the sidebar (`IPadReaderSidebarUITests`).
    func keepsRootTabSidebarAway() -> some View {
        modifier(RootTabSidebarKeptAwayModifier())
    }
}

/// On the root `TabView`: takes the sidebar away from the tabs while a reader asks
/// (`keepsRootTabSidebarAway()`), and gives it back as it was.
///
/// UIKit, because SwiftUI has no say here: a `TabView`'s sidebar has no visibility of its
/// own to set (`.toolbar(_:for:)` has no sidebar placement; iOS 27's
/// `isTabViewSidebarAvailable` is read-only), and the style cannot be swapped for
/// `.tabBarOnly` under a condition without rebuilding the tabs and every stack in them.
/// `UITabBarController.mode` is the public switch for the same thing.
struct RootTabSidebarGate: View {
    @ObservedObject var visibility: RootTabBarVisibility

    var body: some View {
        if #available(iOS 18.0, *) {
            Representable(keepsSidebarAway: visibility.isSidebarKeptAway)
                .frame(width: 0, height: 0)
        }
    }

    @available(iOS 18.0, *)
    private struct Representable: UIViewRepresentable {
        let keepsSidebarAway: Bool

        func makeUIView(context: Context) -> GateView { GateView() }

        func updateUIView(_ view: GateView, context: Context) {
            view.keepsSidebarAway = keepsSidebarAway
        }
    }

    @available(iOS 18.0, *)
    final class GateView: UIView {
        var keepsSidebarAway = false {
            didSet { if keepsSidebarAway != oldValue { apply() } }
        }

        /// The mode SwiftUI gave the tabs, held while the sidebar is away.
        private var modeToRestore: UITabBarController.Mode?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let root = window?.rootViewController else { return }
            guard let tabs = UITabBarController.first(in: root) else {
                AppLogger.error("RootTabSidebarGate: no root tab bar controller under the window")
                return
            }
            if keepsSidebarAway {
                guard modeToRestore == nil, tabs.mode != .tabBar else { return }
                modeToRestore = tabs.mode
                tabs.mode = .tabBar
            } else if let mode = modeToRestore {
                modeToRestore = nil
                tabs.mode = mode
            }
        }
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
