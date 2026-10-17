import Combine
import SwiftUI

// MARK: - Tab root title

/// What a tab root's navigation bar does as its page scrolls.
enum RootTabBarScrollBehavior {
    /// The title fades as the page leaves its top and the buttons stay — 書架. The fade
    /// follows the page's own scroll position, which `rootTabTitleScrollAnchor()` reports
    /// from inside its scroll content, so whatever brings the page back to its top, a drag,
    /// a fling or a tap on the status bar, brings the title back with it.
    case fadesTitle
    /// The whole bar, title and buttons together, slides away as the page scrolls down and
    /// comes back as it scrolls up — Apple Music's tabs — 探索, 資源庫, 設定, 搜索. This is
    /// iOS 27's own bar minimization (`toolbarMinimizationBehavior`). iOS 17–26 have no bar
    /// minimization: there the title fades as with `fadesTitle`, and the buttons stay — so
    /// these pages carry the scroll anchor too.
    case minimizesBar
}

extension View {
    /// The title of a tab's root page — 書架, 探索, 資源庫, 設定, 搜索: large and bold at
    /// the leading end of the navigation bar, on the row with the page's buttons, as
    /// Apple Music heads its tabs; `behavior` says what the bar does as the page scrolls.
    ///
    /// `.toolbarTitleDisplayMode(.inlineLarge)` draws this on iOS 18 and later only; on an
    /// iOS 17 iPhone it is the small centred `.inline` title (seen on the iOS 17.5
    /// simulator). So the title is a toolbar item of the app's own, the same on every
    /// version, and the bar's own title is hidden — but still set, because pushed pages'
    /// back buttons read it.
    ///
    /// The bar is the root stack's, around the tab bar, and what a tab's page declares never
    /// reaches it (iOS 26 and 27, `RootTabNavigationContractTests`). So `ContentView` puts this
    /// on the `TabView`, for the selected tab, with that tab's `fade`; the tab's page carries
    /// the same fade with `rootTabTitleFadeSource`. Every other page and sheet is `.inline`.
    func rootTabTitle(_ title: String, onScroll behavior: RootTabBarScrollBehavior,
                      fade: RootTabTitleFade) -> some View {
        modifier(RootTabTitleModifier(title: title, behavior: behavior, titleFade: fade))
    }

    /// A tab root's page, whose scroll anchors move `fade`: the fade its title wears in the
    /// bar while the tab is selected.
    func rootTabTitleFadeSource(_ fade: RootTabTitleFade, onScroll behavior: RootTabBarScrollBehavior) -> some View {
        environment(\.rootTabTitleFade, behavior.titleFade(fade))
    }

    /// Marks what a tab root scrolls, for its title's fade to follow: put it on a view
    /// inside the scroll content — the content stack, the grid, or a list's first row. A
    /// page with nothing to scroll puts it on its content too, and the title shows in full.
    func rootTabTitleScrollAnchor() -> some View {
        modifier(RootTabTitleScrollAnchor())
    }
}

/// Whether this system minimizes a tab root's bar as its page scrolls (iOS 27).
private var systemMinimizesBar: Bool {
    // The `#if compiler` guard keeps the iOS 27 API out of older toolchains, as the
    // iOS 26 ones are kept out with `compiler(>=6.2)`: Swift 6.4 is the iOS 27 SDK's.
    #if compiler(>=6.4)
    if #available(iOS 27.0, *) { return true }
    #endif
    return false
}

/// How far a tab root's title has faded. Only the title observes it, so the page does not
/// redraw as it scrolls.
@MainActor
final class RootTabTitleFade: ObservableObject {
    @Published private(set) var opacity: Double = 1

    /// `offset`: how far the page has scrolled from its top, in points.
    func update(offset: CGFloat) {
        let progress = (offset - DSLayout.rootTabTitleFadeStart) / DSLayout.rootTabTitleFadeDistance
        let opacity = Double(min(1, max(0, 1 - progress)))
        if opacity != self.opacity { self.opacity = opacity }
    }
}

/// One fade per tab root, kept as long as the tab bar: switching tabs shows each title as
/// its own page left it.
@MainActor
final class RootTabTitleFades {
    private var fades: [AnyHashable: RootTabTitleFade] = [:]

    func fade(for tab: AnyHashable) -> RootTabTitleFade {
        if let fade = fades[tab] { return fade }
        let fade = RootTabTitleFade()
        fades[tab] = fade
        return fade
    }
}

extension RootTabBarScrollBehavior {
    /// The fade the title follows, unless the system moves the whole bar: a title fading on
    /// its own would leave ahead of the buttons it slides away with.
    @MainActor
    func titleFade(_ fade: RootTabTitleFade) -> RootTabTitleFade? {
        switch self {
        case .fadesTitle: fade
        case .minimizesBar: systemMinimizesBar ? nil : fade
        }
    }
}

private struct RootTabTitleFadeKey: EnvironmentKey {
    static let defaultValue: RootTabTitleFade? = nil
}

private extension EnvironmentValues {
    var rootTabTitleFade: RootTabTitleFade? {
        get { self[RootTabTitleFadeKey.self] }
        set { self[RootTabTitleFadeKey.self] = newValue }
    }
}

private struct RootTabTitleScrollAnchor: ViewModifier {
    @Environment(\.rootTabTitleFade) private var fade

    func body(content: Content) -> some View {
        if let fade {
            content.reportsScrollOffset { fade.update(offset: $0) }
        } else {
            content
        }
    }
}

private struct RootTabTitleModifier: ViewModifier {
    let title: String
    let behavior: RootTabBarScrollBehavior
    /// Held, not observed: the title alone redraws as the fade changes.
    let titleFade: RootTabTitleFade

    private var fade: RootTabTitleFade? { behavior.titleFade(titleFade) }

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .modifier(BarTitleHidden())
            .toolbar {
                #if compiler(>=6.2)
                if #available(iOS 26.0, *) {
                    // Otherwise the title sits in a glass capsule, like a button.
                    ToolbarItem(placement: .topBarLeading) { RootTabTitleText(title: title, fade: fade) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { RootTabTitleText(title: title, fade: fade) }
                }
                #else
                ToolbarItem(placement: .topBarLeading) { RootTabTitleText(title: title, fade: fade) }
                #endif
            }
            .modifier(BarMinimization(minimizes: behavior == .minimizesBar))
    }
}

/// iOS 27's bar minimization: the bar slides away as the page scrolls down and comes back
/// as it scrolls up, its search field rising to the top meanwhile (iOS 27 simulator).
/// `.automatic` is the system's default, what a bar that stays had before.
private struct BarMinimization: ViewModifier {
    let minimizes: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content.toolbarMinimizationBehavior(minimizes ? .onScrollDown : .automatic, for: .navigationBar)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Hides the bar's own title and keeps it set.
private struct BarTitleHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.toolbar(removing: .title)
        } else {
            // iOS 17 has no `toolbar(removing: .title)`: an empty principal item takes
            // the title's place in the bar instead. Delete this branch when the
            // deployment target reaches iOS 18.
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

private struct RootTabTitleText: View {
    let title: String
    let fade: RootTabTitleFade?

    var body: some View {
        if let fade {
            FadingTitle(title: title, fade: fade)
        } else {
            TitleText(title: title)
        }
    }

    /// Observes the fade here, so the page around it does not redraw as it scrolls.
    private struct FadingTitle: View {
        let title: String
        @ObservedObject var fade: RootTabTitleFade

        var body: some View {
            TitleText(title: title).opacity(fade.opacity)
        }
    }

    private struct TitleText: View {
        let title: String

        var body: some View {
            Text(title)
                .font(DSFont.largeTitle.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
                .fixedSize()
                // The bar keeps its height at every text size, as the system's own large
                // title does in the bar; a long press shows the title enlarged instead.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .accessibilityShowsLargeContentViewer()
                .accessibilityAddTraits(.isHeader)
        }
    }
}

#Preview("Tab root title") {
    let fade = RootTabTitleFade()
    NavigationStack {
        List(0..<40, id: \.self) { Text("Row \($0)") }
            .rootTabTitleFadeSource(fade, onScroll: .minimizesBar)
            .rootTabTitle("探索", onScroll: .minimizesBar, fade: fade)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "ellipsis")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("More")
                }
            }
    }
}
