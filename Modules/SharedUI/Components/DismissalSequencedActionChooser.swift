import SwiftUI

struct DismissalSequencedAction<Route: Hashable>: Identifiable {
    let route: Route
    let title: String
    let systemImage: String
    let isEnabled: Bool

    init(
        route: Route,
        title: String,
        systemImage: String,
        isEnabled: Bool = true
    ) {
        self.route = route
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }

    var id: Route { route }
}

/// A direct sheet entry used before iOS 18 instead of launching another modal
/// from a still-dismissing toolbar menu.
struct DismissalSequencedActionChooser<Route: Hashable>: View {
    let title: String
    let actions: [DismissalSequencedAction<Route>]
    let onSelect: (Route) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(actions) { action in
                Button {
                    onSelect(action.route)
                    dismiss()
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .foregroundStyle(DSColor.textPrimary)
                }
                .disabled(!action.isEnabled)
            }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    DismissalSequencedActionChooser(
        title: localized("匯入"),
        actions: [
            DismissalSequencedAction(
                route: "local",
                title: localized("本地導入"),
                systemImage: "doc.badge.plus"
            ),
            DismissalSequencedAction(
                route: "network",
                title: localized("網路導入"),
                systemImage: "network"
            ),
        ],
        onSelect: { _ in }
    )
}
