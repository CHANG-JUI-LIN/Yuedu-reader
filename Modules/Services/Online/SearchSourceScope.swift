import Combine
import Foundation

struct SearchSourceScope: Equatable {
    enum Mode: String, Equatable {
        case all
        case custom
    }

    static let all = SearchSourceScope(mode: .all)

    var mode: Mode
    var selectedSourceURLs: Set<String>

    init(mode: Mode, selectedSourceURLs: Set<String> = []) {
        self.mode = mode
        self.selectedSourceURLs = selectedSourceURLs
    }

    func resolvedSources(from sources: [BookSource]) -> [BookSource] {
        let enabledSources = sources.filter(\.enabled)
        guard mode == .custom else { return enabledSources }

        return enabledSources.filter { source in
            let key = Self.sourceKey(for: source)
            return !key.isEmpty && selectedSourceURLs.contains(key)
        }
    }

    static func sourceKey(for source: BookSource) -> String {
        source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class SearchSourceScopeStore: ObservableObject {
    static let shared = SearchSourceScopeStore()

    @Published private(set) var scope: SearchSourceScope

    private enum Keys {
        static let mode = "yd_search_source_scope_mode"
        static let selectedURLs = "yd_search_source_scope_selected_urls"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = defaults.string(forKey: Keys.mode)
            .flatMap(SearchSourceScope.Mode.init(rawValue:)) ?? .all
        let selectedURLs = Set(defaults.stringArray(forKey: Keys.selectedURLs) ?? [])
        scope = SearchSourceScope(mode: mode, selectedSourceURLs: selectedURLs)
    }

    func save(_ newScope: SearchSourceScope) {
        scope = newScope
        defaults.set(newScope.mode.rawValue, forKey: Keys.mode)
        defaults.set(newScope.selectedSourceURLs.sorted(), forKey: Keys.selectedURLs)
    }
}
