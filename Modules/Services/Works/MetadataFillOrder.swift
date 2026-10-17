import Combine
import Foundation

// Phase 6h: which places fill a copy's empty fields, and in what order. Maintainer,
// 2026-10-15: as Emby's 中繼資料下載器 — one list under 自動補齊書籍資料, each place checked
// or not and dragged into priority order; a newly installed module joins checked.

/// A place the filler can ask.
enum MetadataFillPlace: Hashable, Sendable {
    case openLibrary
    /// Every enabled 來源配置 together (`BookSourceFillProvider`).
    case bookSources
    /// An installed module with a search (`ModuleFillProvider`).
    case module(String)

    /// What the order is stored as.
    var storageKey: String {
        switch self {
        case .openLibrary: "openLibrary"
        case .bookSources: "bookSources"
        case .module(let id): "module:\(id)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "openLibrary": self = .openLibrary
        case "bookSources": self = .bookSources
        default:
            guard storageKey.hasPrefix("module:") else { return nil }
            let id = String(storageKey.dropFirst("module:".count))
            guard !id.isEmpty else { return nil }
            self = .module(id)
        }
    }
}

/// The places in the order they are asked, first first. The runner fills only empty fields
/// and a field once, so the first place that has a value gives it.
struct MetadataFillOrder: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        var place: MetadataFillPlace
        var isEnabled: Bool
        var id: MetadataFillPlace { place }
    }

    var entries: [Entry]

    /// Phase 3's order, what a reader who never opened the list has.
    static let builtIn: [MetadataFillPlace] = [.openLibrary, .bookSources]

    /// The stored order as it applies now: the built-in places and every installed module
    /// with a search. A place the stored order lacks joins at the end, checked; a module no
    /// longer installed is left out (its stored entry is kept by `MetadataFillOrderStore`).
    ///
    /// - Parameter modules: the ids of the installed modules that have a search, in the
    ///   library's order.
    static func resolved(stored: [Entry], modules: [String]) -> MetadataFillOrder {
        let current = Set(builtIn + modules.map(MetadataFillPlace.module))
        var entries = stored.filter { current.contains($0.place) }
        var seen = Set<MetadataFillPlace>()
        entries = entries.filter { seen.insert($0.place).inserted }
        for place in builtIn + modules.map(MetadataFillPlace.module) where !seen.contains(place) {
            entries.append(Entry(place: place, isEnabled: true))
            seen.insert(place)
        }
        return MetadataFillOrder(entries: entries)
    }
}

/// Keeps the reader's order (UserDefaults `yd_metadata_fill_order`). Only what the reader set
/// is stored: with nothing stored the order is `MetadataFillOrder.builtIn`, then the modules.
@MainActor
final class MetadataFillOrderStore: ObservableObject {
    static let shared = MetadataFillOrderStore()
    nonisolated static let defaultsKey = "yd_metadata_fill_order"

    /// The order as last saved, modules no longer installed included.
    @Published private(set) var stored: [MetadataFillOrder.Entry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = Self.read(defaults)
    }

    func order(modules: [String]) -> MetadataFillOrder {
        MetadataFillOrder.resolved(stored: stored, modules: modules)
    }

    /// `order` as the reader left it. Entries it does not show (a removed module) are kept
    /// after it, so reinstalling a module keeps its place and check.
    func save(_ order: MetadataFillOrder) {
        let shown = Set(order.entries.map(\.place))
        stored = order.entries + stored.filter { !shown.contains($0.place) }
        let raw = stored.map { ["place": $0.place.storageKey, "enabled": $0.isEnabled ? "1" : "0"] }
        defaults.set(raw, forKey: Self.defaultsKey)
    }

    private static func read(_ defaults: UserDefaults) -> [MetadataFillOrder.Entry] {
        guard let raw = defaults.array(forKey: defaultsKey) else { return [] }
        return raw.compactMap { item in
            guard let item = item as? [String: String], let key = item["place"] else {
                AppLogger.error("Metadata fill order: an unreadable entry was skipped", context: ["entry": "\(item)"], level: .warning)
                return nil
            }
            guard let place = MetadataFillPlace(storageKey: key) else {
                AppLogger.error("Metadata fill order: an unknown place was skipped", context: ["place": key], level: .warning)
                return nil
            }
            return MetadataFillOrder.Entry(place: place, isEnabled: item["enabled"] != "0")
        }
    }
}

extension MetadataFillOrder {
    /// The checked places as providers, first first.
    ///
    /// - Parameter modules: the installed modules.
    @MainActor
    func providers(modules: [RuleModule]) -> [any MetadataFillProvider] {
        entries.filter(\.isEnabled).compactMap { entry -> (any MetadataFillProvider)? in
            switch entry.place {
            case .openLibrary: OpenLibraryFillProvider()
            case .bookSources: BookSourceFillProvider()
            case .module(let id):
                modules.first { $0.id == id && $0.canFill }
                    .map { ModuleFillProvider(provider: ModuleProvider(module: $0)) }
            }
        }
    }
}

extension RuleModuleLibrary {
    /// The installed modules that can fill: those with a search or a lookup.
    var fillingModules: [RuleModule] {
        modules.map(\.module).filter(\.canFill)
    }
}

extension RuleModule {
    var canFill: Bool { search != nil || lookup != nil }
}
