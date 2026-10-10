import SwiftUI

// MARK: - Editing a custom page's blocks

/// A custom page's blocks as a list: tap one to change it, swipe to delete, drag to
/// reorder; ＋ adds one. The waterfall stays last.
struct CustomExplorePageEditor: View {
    let pageID: UUID

    @ObservedObject private var store = CustomExplorePageStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @State private var sheet: SheetRoute?

    /// One sheet modifier for both: two on one view compete for one presenter.
    private enum SheetRoute: Identifiable {
        case add
        case edit(CustomExploreComponent)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let component): component.id.uuidString
            }
        }
    }

    private var components: [CustomExploreComponent] {
        store.page(id: pageID)?.components ?? []
    }

    var body: some View {
        List {
            Section {
                ForEach(components) { component in
                    Button { sheet = .edit(component) } label: { row(component) }
                        .moveDisabled(component.kind == .waterfall)
                }
                .onDelete { store.removeComponents(atOffsets: $0, inPage: pageID) }
                .onMove { store.moveComponents(fromOffsets: $0, toOffset: $1, inPage: pageID) }
            } footer: {
                if components.contains(where: { $0.kind == .waterfall }) {
                    Text(localized("錯位瀑布流會一直往下載入，固定在最後。"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()
        }
        .overlay {
            if components.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("還沒有元件"), systemImage: "rectangle.3.group")
                } actions: {
                    Button(localized("新增元件")) { sheet = .add }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(localized("編輯元件"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .toolbar {
            if !components.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .add } label: {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("新增元件"))
            }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .add:
                CustomExploreComponentSheet(pageID: pageID, editing: nil)
            case .edit(let component):
                CustomExploreComponentSheet(pageID: pageID, editing: component)
            }
        }
    }

    /// The layout, then what it shows: its title and source, or its categories.
    private func row(_ component: CustomExploreComponent) -> some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: component.kind.systemImage)
                .font(DSFont.body)
                .foregroundStyle(DSColor.accent)
                .frame(width: DSLayout.settingsRowIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(localized(component.kind.titleKey))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Text(summary(component))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if component.kind == .waterfall {
                Image(systemName: "lock.fill")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func summary(_ component: CustomExploreComponent) -> String {
        let sourceName = component.sourceURL.flatMap { url in
            sourceStore.sources.first { $0.bookSourceUrl == url }?.bookSourceName
        }
        let shown = component.kind.takesSeveralCategories
            ? component.categories.map(\.title).joined(separator: "、")
            : component.displayTitle
        return "\(shown) · \(sourceName ?? localized("來源配置已被刪除"))"
    }
}
