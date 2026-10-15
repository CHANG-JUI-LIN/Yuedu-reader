import SwiftUI

/// 設定 → 網路設定 → 資料來源 (Phase 6h): the places 自動補齊書籍資料 asks, as Emby's
/// 中繼資料下載器 (maintainer, 2026-10-15) — each checked or not, dragged into priority order.
/// Every change is saved at once, and the filler starts again with it (`MetadataFillCoordinator`).
struct MetadataFillSourcesView: View {
    @ObservedObject private var orderStore: MetadataFillOrderStore
    @ObservedObject private var modules: RuleModuleLibrary
    @State private var order: MetadataFillOrder

    init(orderStore: MetadataFillOrderStore = .shared, modules: RuleModuleLibrary = .shared) {
        self.orderStore = orderStore
        self.modules = modules
        _order = State(initialValue: orderStore.order(modules: modules.fillingModules.map(\.id)))
    }

    private var moduleIDs: [String] { modules.fillingModules.map(\.id) }

    var body: some View {
        List {
            Section {
                ForEach($order.entries) { $entry in
                    Toggle(name(of: entry.place), isOn: $entry.isEnabled)
                        .accessibilityIdentifier("metadataFill.place.\(entry.place.storageKey)")
                        // Reordering without dragging (VoiceOver, Switch Control).
                        .accessibilityAction(named: localized("上移")) { move(entry.place, by: -1) }
                        .accessibilityAction(named: localized("下移")) { move(entry.place, by: 1) }
                }
                .onMove { from, to in order.entries.move(fromOffsets: from, toOffset: to) }
            } footer: {
                Text(localized("排在前面的先補，只補還空著的欄位；取消勾選不會刪掉已經補上的資料。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        // Always arranging, as Emby's list is: the handles are the list's only control.
        .environment(\.editMode, .constant(.active))
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("資料來源"))
        .toolbarTitleDisplayMode(.inline)
        .task { await modules.loadIfNeeded() }
        .onChange(of: moduleIDs) { _, ids in order = orderStore.order(modules: ids) }
        .onChange(of: order) { _, order in
            guard order != orderStore.order(modules: moduleIDs) else { return }
            orderStore.save(order)
        }
    }

    private func name(of place: MetadataFillPlace) -> String {
        switch place {
        case .openLibrary: FilledMetadata.providerName(OpenLibrary.key)
        case .bookSources: localized("來源配置")
        case .module(let id): modules.module(id: id)?.module.title ?? id
        }
    }

    private func move(_ place: MetadataFillPlace, by offset: Int) {
        guard let index = order.entries.firstIndex(where: { $0.place == place }) else { return }
        let target = index + offset
        guard order.entries.indices.contains(target) else { return }
        order.entries.swapAt(index, target)
    }
}

#Preview("資料來源") {
    NavigationStack {
        MetadataFillSourcesView(orderStore: MetadataFillOrderStore(defaults: UserDefaults(suiteName: "preview.metadataFill")!),
                                modules: RuleModulePreviewData.library(["每週新書", "書評精選"]))
    }
}
