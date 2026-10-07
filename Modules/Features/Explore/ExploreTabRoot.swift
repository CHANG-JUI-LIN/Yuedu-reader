import SwiftUI
import TipKit

/// Each mode owns its navigation stack. Choosing another mode discards that stack.
struct ExploreTabRoot: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject private var model = ExploreTabModel.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @AppStorage(ExploreSettings.modeKey) private var storedMode = ExploreMode.publicLibraries.rawValue

    private var mode: ExploreMode {
        ExploreMode.effective(
            stored: .storedValue(storedMode, hasImportedSources: model.hasSources),
            hasImportedSources: model.hasSources, librariesAvailable: availability.isAvailable)
    }

    static func showsModeMenu(hasImportedSources: Bool, librariesAvailable: Bool) -> Bool {
        hasImportedSources && librariesAvailable
    }

    private var menu: ExploreModeMenu? {
        guard Self.showsModeMenu(hasImportedSources: model.hasSources,
                                librariesAvailable: availability.isAvailable) else { return nil }
        return ExploreModeMenu(mode: Binding(get: { mode }, set: { storedMode = $0.rawValue }),
                               tipEnabled: model.guidePending)
    }

    var body: some View {
        Group {
            switch mode {
            case .bookSources: ExploreHomeView(browser: browser, modeMenu: menu)
            case .publicLibraries: PublicLibraryHomeView(modeMenu: menu)
            }
        }
        .onAppear { model.appeared(librariesAvailable: availability.isAvailable) }
    }
}

struct ExploreModeMenu: View {
    @Binding var mode: ExploreMode
    var tipEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0
    @State private var tipVisible = false
    private let tip = ExploreModeTip()

    var body: some View {
        Menu {
            Picker(localized("切換探索內容"), selection: Binding(get: { mode }, set: { mode = $0; tip.invalidate(reason: .actionPerformed) })) {
                Label(localized("公有書庫"), systemImage: "books.vertical").tag(ExploreMode.publicLibraries)
                Label(localized("書源"), systemImage: "antenna.radiowaves.left.and.right").tag(ExploreMode.bookSources)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .symbolEffect(.bounce, value: bounce)
                .symbolEffectsRemoved(reduceMotion || !tipVisible)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("切換探索內容"))
        .accessibilityValue(localized(mode == .publicLibraries ? "公有書庫" : "書源"))
        .accessibilityIdentifier("explore.modeMenu")
        .exploreModePopoverTip(tipEnabled ? tip : nil) { action in
            if action.id == "switch" { mode = .bookSources }
            tip.invalidate(reason: .actionPerformed)
        }
        .simultaneousGesture(TapGesture().onEnded { tip.invalidate(reason: .actionPerformed) })
        .task(id: tipEnabled) {
            guard tipEnabled else { return }
            for await _ in tip.statusUpdates {
                tipVisible = tip.shouldDisplay
                if tipVisible && !reduceMotion { bounce += 1 }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func exploreModePopoverTip(_ tip: ExploreModeTip?,
                               action: @escaping @MainActor @Sendable (Tips.Action) -> Void) -> some View {
        // TipKit changed this signature in iOS 18, 18.4 and 26. Explicit argument
        // lists keep each OS on its native API; remove old branches as deployment advances.
        if #available(iOS 26, *) {
            popoverTip(tip, isPresented: nil, arrowEdge: .top, action: action)
        } else if #available(iOS 18.4, *) {
            (popoverTip(_:arrowEdge:action:))(tip, Optional<Edge>.some(.top), action)
        } else if #available(iOS 18, *) {
            (popoverTip(_:arrowEdge:action:))(tip, Edge.top, action)
        } else if let tip {
            (popoverTip(_:arrowEdge:action:))(tip, Edge.top, action)
        } else { self }
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
