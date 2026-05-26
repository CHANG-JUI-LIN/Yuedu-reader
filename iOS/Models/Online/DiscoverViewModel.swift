import Combine
import Foundation
import SwiftUI

// MARK: - Discover Card Item

/// A single tappable entry on the 書源發現 (book-source discover) screen, derived
/// from a `ModernParserBridge.DiscoverItem`. Items are either *actions* (login /
/// open-in-browser) or *categories* (load a book list via `discoverBooks`).
struct DiscoverCardItem: Identifiable {
    let id = UUID()
    let title: String
    let raw: ModernParserBridge.DiscoverItem
    let isAction: Bool
    let actionURL: String?
    let isFetchable: Bool
}

// MARK: - Discover View Model

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var exploreSources: [BookSource] = []
    @Published var selectedSourceId: UUID?

    @Published var items: [DiscoverCardItem] = []
    @Published var books: [OnlineBook] = []
    @Published var booksSectionTitle: String = ""

    @Published var isLoadingItems = false
    @Published var isLoadingBooks = false

    @Published var selectedType = "小说"
    @Published var selectedChannel = "男频"
    @Published var selectedPlatform = "全部"

    let typeOptions = ["小说", "听书", "漫画", "短剧"]
    let channelOptions = ["男频", "女频"]

    private let sourceStore = BookSourceStore.shared
    private let runtimeStore = BookSourceRuntimeStateStore.shared
    private let selectedSourceKey = "discover.selectedSourceId"
    private var loadItemsTask: Task<Void, Never>?
    private var loadBooksTask: Task<Void, Never>?

    var selectedSource: BookSource? {
        exploreSources.first { $0.id == selectedSourceId }
    }

    var hasExploreSource: Bool { selectedSource != nil }

    /// 來源 (platform) chips, derived from the source's group list minus the aggregator name.
    var platformOptions: [String] {
        guard let group = selectedSource?.bookSourceGroup else { return ["全部"] }
        let parts = group
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "聚合" }
        return ["全部"] + parts
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: selectedSourceKey) {
            selectedSourceId = UUID(uuidString: stored)
        }
    }

    // MARK: - Source lifecycle

    func refreshSources() {
        exploreSources = sourceStore.enabledSources.filter {
            $0.enabledExplore
                && !$0.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if selectedSourceId == nil || !exploreSources.contains(where: { $0.id == selectedSourceId }) {
            selectedSourceId = exploreSources.first?.id
            persistSelectedSource()
        }
        if !platformOptions.contains(selectedPlatform) { selectedPlatform = "全部" }
        loadVariablesFromSource()
        if items.isEmpty, hasExploreSource { reload() }
    }

    func selectSource(_ id: UUID) {
        guard id != selectedSourceId else { return }
        selectedSourceId = id
        persistSelectedSource()
        if !platformOptions.contains(selectedPlatform) { selectedPlatform = "全部" }
        loadVariablesFromSource()
        reload()
    }

    // MARK: - Filters

    func setType(_ value: String) {
        guard value != selectedType else { return }
        selectedType = value
        applyFilters()
        reload()
    }

    func setChannel(_ value: String) {
        guard value != selectedChannel else { return }
        selectedChannel = value
        applyFilters()
        reload()
    }

    func setPlatform(_ value: String) {
        guard value != selectedPlatform else { return }
        selectedPlatform = value
        applyFilters()
        reload()
    }

    // MARK: - Loading

    func reload() {
        guard let source = selectedSource else {
            items = []
            books = []
            booksSectionTitle = ""
            return
        }
        loadItemsTask?.cancel()
        isLoadingItems = true
        loadItemsTask = Task { [weak self] in
            let raw = await BookSourceFetcher.shared.discoverItems(page: 1, in: source)
            guard let self, !Task.isCancelled else { return }
            let mapped = raw.compactMap(Self.mapItem)
            self.items = mapped
            self.isLoadingItems = false
            if let first = mapped.first(where: { $0.isFetchable }) {
                self.loadBooks(for: first)
            } else {
                self.loadBooksTask?.cancel()
                self.books = []
                self.booksSectionTitle = ""
            }
        }
    }

    func handleTap(_ item: DiscoverCardItem, onNavigate: (String) -> Void) {
        if item.isAction, let url = item.actionURL {
            onNavigate(url)
        } else if item.isFetchable {
            loadBooks(for: item)
        }
    }

    func loadBooks(for item: DiscoverCardItem) {
        guard let source = selectedSource, item.isFetchable else { return }
        loadBooksTask?.cancel()
        isLoadingBooks = true
        booksSectionTitle = item.title
        loadBooksTask = Task { [weak self] in
            let result =
                (try? await BookSourceFetcher.shared.discoverBooks(from: item.raw, page: 1, in: source)) ?? []
            guard let self, !Task.isCancelled else { return }
            self.books = result
            self.isLoadingBooks = false
        }
    }

    // MARK: - Item mapping

    static func mapItem(_ raw: ModernParserBridge.DiscoverItem) -> DiscoverCardItem? {
        let title = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "--" else { return nil }

        let url = (raw.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isAction = url.hasPrefix("{{") || url.contains("java.startBrowser")
        let actionURL = isAction ? extractHTTPURL(from: url) : nil
        let isFetchable = !isAction && !url.isEmpty

        // Skip pure labels (no url, no action) — e.g. a "username's 番茄" header.
        guard isAction || isFetchable else { return nil }

        return DiscoverCardItem(
            title: title,
            raw: raw,
            isAction: isAction,
            actionURL: actionURL,
            isFetchable: isFetchable
        )
    }

    static func extractHTTPURL(from string: String) -> String? {
        guard let range = string.range(of: "https?://[^\"')\\s]+", options: .regularExpression) else {
            return nil
        }
        return String(string[range])
    }

    // MARK: - Source runtime variables

    /// Filter selections persist as the source's Legado runtime variables, which the
    /// JS `exploreUrl` reads on its next run (`getVariable('频道')`, etc.).
    private func loadVariablesFromSource() {
        guard let source = selectedSource else { return }
        let dict = currentVariableDict(for: source)
        if let value = dict["频道"] as? String, channelOptions.contains(value) {
            selectedChannel = value
        }
        if let value = dict["发现页来源"] as? String {
            selectedPlatform = platformOptions.contains(value) ? value : "全部"
        }
        if let more = dict["更多设置"] as? [String: Any],
           let mode = more["搜索模式"] as? String, typeOptions.contains(mode) {
            selectedType = mode
        } else if let value = dict["发现页类型"] as? String, typeOptions.contains(value) {
            selectedType = value
        }
    }

    private func applyFilters() {
        guard let source = selectedSource else { return }
        var dict = currentVariableDict(for: source)
        dict["频道"] = selectedChannel
        dict["发现页来源"] = selectedPlatform
        dict["发现页类型"] = selectedType
        var more = (dict["更多设置"] as? [String: Any]) ?? [:]
        more["搜索模式"] = selectedType
        dict["更多设置"] = more
        writeVariableDict(dict, for: source)
    }

    private func currentVariableDict(for source: BookSource) -> [String: Any] {
        guard let json = runtimeStore.sourceVariableJSON(for: source.bookSourceUrl),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func writeVariableDict(_ dict: [String: Any], for source: BookSource) {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        runtimeStore.setSourceVariableJSON(json, for: source.bookSourceUrl)
    }

    private func persistSelectedSource() {
        guard let id = selectedSourceId else { return }
        UserDefaults.standard.set(id.uuidString, forKey: selectedSourceKey)
    }
}
