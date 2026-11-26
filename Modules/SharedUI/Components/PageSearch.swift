import SwiftUI

/// A pushed page's own search, as 資源庫's pages into a source or a module have it (maintainer,
/// 2026-11-26: 「右下角新增原生 search field」): on iOS 26 and later the system's search button
/// in the bottom trailing corner, which opens into the field above the keyboard. The root tab
/// bar is hidden while the page shows: the bottom toolbar sits under it, and the button was
/// drawn beneath the tab bar's 搜尋 tab (iOS 27.2 simulator); with the bar kept, the system
/// moves a minimized search to the top trailing corner instead (the maintainer chose the corner
/// and the hidden tab bar). Below iOS 26, which has no search in the bottom toolbar, the native
/// field sits under the navigation bar and the tab bar stays.
///
/// Submitting closes the field and hands the trimmed text to `onSubmit`, which pushes the
/// results. Nothing at all while `isEnabled` is false (the page has nothing to search, or no
/// stack to push the results onto) or outside 資源庫 (`offersPageSearch`): a page without the
/// search keeps its tab bar.
private struct PageSearchModifier: ViewModifier {
    @Binding var text: String
    let prompt: String
    let isEnabled: Bool
    let onSubmit: (String) -> Void
    @Environment(\.offersPageSearch) private var offersPageSearch
    @State private var isPresented = false

    func body(content: Content) -> some View {
        if isEnabled && offersPageSearch {
            searchable(content)
                .onSubmit(of: .search) {
                    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    isPresented = false
                    onSubmit(query)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func searchable(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: prompt)
                .searchToolbarBehavior(.minimize)
                .toolbar {
                    // The spacer takes the bar's leading side, so the button sits trailing.
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
                .hidesRootTabBar(hasBottomBar: true)
        } else {
            drawerSearchable(content)
        }
        #else
        drawerSearchable(content)
        #endif
    }

    private func drawerSearchable(_ content: Content) -> some View {
        content.searchable(text: $text, isPresented: $isPresented,
                           placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
    }
}

extension EnvironmentValues {
    /// Whether the stack's pages offer their own search (`pageSearch`). Only 資源庫's stack sets
    /// it: the maintainer asked for the pages opened from 資源庫 (2026-11-26), and the same
    /// pages opened from 探索 keep its tab bar and no search.
    @Entry var offersPageSearch = false
}

extension View {
    /// The page's own search (`PageSearchModifier`): `onSubmit` gets the trimmed text.
    func pageSearch(text: Binding<String>, prompt: String, isEnabled: Bool,
                    onSubmit: @escaping (String) -> Void) -> some View {
        modifier(PageSearchModifier(text: text, prompt: prompt, isEnabled: isEnabled, onSubmit: onSubmit))
    }
}

#Preview("A page's own search") {
    @Previewable @State var text = ""
    NavigationStack {
        List(1...30, id: \.self) { Text("\($0)") }
            .navigationTitle("Bangumi")
            .toolbarTitleDisplayMode(.inline)
            .pageSearch(text: $text, prompt: localized("輸入書名或作者"), isEnabled: true) { _ in }
    }
    .environment(\.offersPageSearch, true)
}
