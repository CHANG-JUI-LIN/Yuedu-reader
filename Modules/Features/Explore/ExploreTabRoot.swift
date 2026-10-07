import SwiftUI

/// Each mode owns its navigation stack. Choosing another mode discards that stack.
struct ExploreTabRoot: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject private var sources = BookSourceStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @AppStorage(ExploreSettings.modeKey) private var storedMode = ExploreMode.publicLibraries.rawValue

    private var mode: ExploreMode {
        ExploreMode.effective(
            stored: .storedValue(storedMode, hasImportedSources: !sources.sources.isEmpty),
            hasImportedSources: !sources.sources.isEmpty, librariesAvailable: availability.isAvailable)
    }

    static func showsModeMenu(hasImportedSources: Bool, librariesAvailable: Bool) -> Bool {
        hasImportedSources && librariesAvailable
    }

    private var menu: ExploreModeMenu? {
        guard Self.showsModeMenu(hasImportedSources: !sources.sources.isEmpty,
                                librariesAvailable: availability.isAvailable) else { return nil }
        return ExploreModeMenu(mode: Binding(get: { mode }, set: { storedMode = $0.rawValue }))
    }

    var body: some View {
        switch mode {
        case .bookSources: ExploreHomeView(browser: browser, modeMenu: menu)
        case .publicLibraries: PublicLibraryHomeView(modeMenu: menu)
        }
    }
}

struct ExploreModeMenu: View {
    @Binding var mode: ExploreMode

    var body: some View {
        Menu {
            Picker(localized("切換探索內容"), selection: $mode) {
                Label(localized("公有書庫"), systemImage: "books.vertical").tag(ExploreMode.publicLibraries)
                Label(localized("書源"), systemImage: "antenna.radiowaves.left.and.right").tag(ExploreMode.bookSources)
            }
        } label: {
            Label(localized("切換探索內容"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .accessibilityLabel(localized("切換探索內容"))
        .accessibilityValue(localized(mode == .publicLibraries ? "公有書庫" : "書源"))
        .accessibilityIdentifier("explore.modeMenu")
    }
}

#Preview("Public libraries") {
    PublicLibraryHomeView(modeMenu: ExploreModeMenu(mode: .constant(.publicLibraries)))
        .environmentObject(BookStore())
}

#Preview("Book sources") {
    ExploreHomeView(browser: BrowserState(), modeMenu: ExploreModeMenu(mode: .constant(.bookSources)))
        .environmentObject(BookStore())
}
