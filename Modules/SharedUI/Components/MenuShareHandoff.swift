import CoreTransferable
import SwiftUI

/// One share payload retained until a first-level presenter can show it.
///
/// See `MenuShareLinkPresentationPolicy` for why a `Menu` cannot own the share
/// sheet itself before iOS 18.
struct PendingShareExport<Item: Transferable>: Identifiable {
    let id = UUID()
    /// Navigation title of the handoff sheet — reuse the menu row's own label
    /// ("匯出書源檔案", "匯出紀錄", …) so the user lands where they tapped.
    let title: String
    /// Share-sheet preview title; normally the filename.
    let name: String
    let item: Item
}

/// The sheet that owns the real `ShareLink`.
///
/// A `ShareLink` is presentation-safe as a direct page or sheet control, which is
/// exactly what this is: the menu is already gone by the time this sheet appears,
/// so nothing is competing for the presenter.
struct ShareExportSheet<Item: Transferable>: View {
    let export: PendingShareExport<Item>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ShareLink(item: export.item, preview: SharePreview(export.name)) {
                        Label(localized("分享"), systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(export.name)
                }
                .interfaceSectionSurface()
            }
            .navigationTitle(export.title)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// A share row for `Menu` content.
///
/// Before iOS 18 this is a plain `Button` that hands the payload to the screen's
/// first-level presenter; iOS 18 keeps the native in-menu `ShareLink`, which draws
/// the system share affordance and needs no extra tap.
struct MenuShareRow<Item: Transferable>: View {
    let label: String
    var systemImage: String = "square.and.arrow.up"
    /// Built on demand. `Menu` content is constructed eagerly with its parent row,
    /// so anything expensive here is paid on every layout pass — before iOS 18 the
    /// payload is only built when the row is actually tapped.
    let makeExport: () -> PendingShareExport<Item>
    /// Where the payload goes before iOS 18: the owning screen stores it and shows
    /// `ShareExportSheet` from its own first-level presenter.
    let onHandoff: (PendingShareExport<Item>) -> Void

    var body: some View {
        if MenuShareLinkPresentationPolicy.requiresFirstLevelShareSheet {
            Button {
                onHandoff(makeExport())
            } label: {
                Label(label, systemImage: systemImage)
            }
        } else {
            let export = makeExport()
            ShareLink(item: export.item, preview: SharePreview(export.name)) {
                Label(label, systemImage: systemImage)
            }
        }
    }
}

#Preview {
    ShareExportSheet(
        export: PendingShareExport(
            title: localized("匯出書源檔案"),
            name: "book-sources.json",
            item: URL(fileURLWithPath: "/tmp/book-sources.json")
        )
    )
}
