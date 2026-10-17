import SwiftUI

// Search 9d: 聚合設定's 數據來源, as Emby's 聚合資料 lists its data sources — one row per purpose
// with how many of its places are checked, each opening the checklist of those places.

/// The places a purpose can use, and how many it does: 「3/5」.
struct DataSourceCount: Equatable {
    var checked: Int
    var total: Int

    var text: String { "\(checked)/\(total)" }

    /// VoiceOver hears it as words, not a fraction.
    var spoken: String { String(format: localized("已勾選 %1$d 個，共 %2$d 個"), checked, total) }
}

/// 搜尋來源's places: the saved OPDS and Calibre libraries, Gutenberg and 青空文庫 where offered
/// (WebDAV has no search), in 書庫順序, then the installed modules that search (Open Library
/// among them since OL3). 來源配置 are not listed: they keep their own switch and the search's
/// 來源配置 chip.
@MainActor
enum SearchSourcePlaces {
    static func places(connections: [RemoteLibraryConnection], librariesAvailable: Bool, order: [SourceInstanceKey]?,
                       modules: [ModuleProvider]) -> [LibraryListing] {
        let libraries = LibraryListing.ordered(connections: connections, librariesAvailable: librariesAvailable, order: order)
            .filter { $0.key.type != .webDAV }
        let searching = modules.filter { $0.module.search != nil }.map {
            LibraryListing(key: $0.instance, name: $0.module.title, systemImage: "puzzlepiece.extension")
        }
        return libraries + searching
    }

    /// Checked of the places.
    static func count(_ places: [LibraryListing], shown: (SourceInstanceKey) -> Bool) -> DataSourceCount {
        DataSourceCount(checked: places.filter { shown($0.key) }.count, total: places.count)
    }
}

/// The 數據來源 section of 聚合設定.
struct AggregationDataSourcesSection: View {
    @ObservedObject private var store = AggregationSettingsStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var modules = RuleModuleLibrary.shared
    @ObservedObject private var fillOrder = MetadataFillOrderStore.shared

    private var searchCount: DataSourceCount {
        let places = SearchSourcePlaces.places(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                                               order: store.settings.libraryOrder,
                                               modules: SourceProviderRegistry.moduleProviders(in: modules))
        return SearchSourcePlaces.count(places, shown: store.isShownInSearch)
    }

    private var latestCount: DataSourceCount {
        let libraries = LibraryListing.ordered(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                                               order: store.settings.libraryOrder)
        return DataSourceCount(checked: libraries.filter { store.isShownInLatest($0.key) }.count, total: libraries.count)
    }

    private var fillCount: DataSourceCount {
        let entries = fillOrder.order(modules: modules.fillingModules.map(\.id)).entries
        return DataSourceCount(checked: entries.filter(\.isEnabled).count, total: entries.count)
    }

    var body: some View {
        Section {
            row(localized("搜尋來源"), count: searchCount, id: "aggregation.dataSources.search") { SearchSourcesView() }
            row(localized("最新來源"), count: latestCount, id: "aggregation.dataSources.latest") { LatestSourcesView() }
            row(localized("資料來源"), count: fillCount, id: "aggregation.dataSources.metadata") { MetadataFillSourcesView() }
        } header: {
            Text(localized("數據來源"))
        }
        .interfaceSectionSurface()
        .task { await modules.loadIfNeeded() }
    }

    private func row<Destination: View>(_ title: String, count: DataSourceCount, id: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            LabeledContent(title, value: count.text)
                .foregroundStyle(DSColor.textPrimary)
        }
        .accessibilityValue(count.spoken)
        .accessibilityIdentifier(id)
    }
}

/// 搜尋來源: the places a sent search asks, each checked or not.
struct SearchSourcesView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var modules = RuleModuleLibrary.shared

    var body: some View {
        let places = SearchSourcePlaces.places(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                                               order: store.settings.libraryOrder,
                                               modules: SourceProviderRegistry.moduleProviders(in: modules))
        List {
            Section {
                ForEach(places) { place in
                    Toggle(isOn: Binding(get: { store.isShownInSearch(place.key) },
                                         set: { store.setShownInSearch($0, for: place.key) })) {
                        SettingsRowLabel(place.name, systemImage: place.systemImage)
                    }
                    .accessibilityIdentifier("aggregation.search.\(place.key.type.rawValue).\(place.key.id)")
                }
            } footer: {
                Text(localized("按下搜尋時，關鍵字會送到勾選的地方；Open Library 找到的書只有資料。來源配置在搜索頁的「來源配置」選。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("搜尋來源"))
        .toolbarTitleDisplayMode(.inline)
        .task { await modules.loadIfNeeded() }
    }
}

/// 最新來源: 顯示在最新 for every library, the same switches 最新's own options show.
struct LatestSourcesView: View {
    @ObservedObject private var store = AggregationSettingsStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared

    var body: some View {
        let libraries = LibraryListing.ordered(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                                               order: store.settings.libraryOrder)
        List {
            if libraries.isEmpty {
                ContentUnavailableView(localized("沒有書庫"), systemImage: "building.columns")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(libraries) { library in
                        Toggle(isOn: Binding(get: { store.isShownInLatest(library.key) },
                                             set: { store.setShownInLatest($0, for: library.key) })) {
                            SettingsRowLabel(library.name, systemImage: library.systemImage)
                        }
                        .accessibilityIdentifier("aggregation.latest.\(library.key.type.rawValue).\(library.key.id)")
                    }
                } footer: {
                    Text(localized("每個首頁配置的最新都用這份設定。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("最新來源"))
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview("數據來源") {
    NavigationStack {
        List { AggregationDataSourcesSection() }
    }
}

#Preview("搜尋來源") {
    NavigationStack { SearchSourcesView() }
}

#Preview("最新來源") {
    NavigationStack { LatestSourcesView() }
}
