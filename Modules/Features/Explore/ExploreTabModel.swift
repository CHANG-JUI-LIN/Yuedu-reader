import Combine
import SwiftUI

/// Whether the source library has been read and holds any sources. Alive from launch, so a
/// source imported from 設定 before the reader visits 探索 is already counted.
@MainActor
final class ExploreTabModel: ObservableObject {
    static let shared = ExploreTabModel()
    /// False until the source library has been read; the tab shows a placeholder meanwhile
    /// rather than deciding the home's default sections on the store's "not read yet" empty list.
    @Published private(set) var isLoaded = false
    @Published private(set) var hasSources = false
    private var subscription: AnyCancellable?

    /// Built in `App.init`, before the library is read (it is read off the main thread now):
    /// everything that depends on whether sources exist waits for `whenLoaded`. Treating the
    /// placeholder as "no sources" would show 公有書庫 to a user with 50 000 sources.
    init(sources: BookSourceStore = .shared, defaults: UserDefaults = .standard) {
        sources.whenLoaded { [weak self] library in
            self?.start(library: library, sources: sources, defaults: defaults)
        }
    }

    private func start(library: [BookSource], sources: BookSourceStore, defaults: UserDefaults) {
        hasSources = !library.isEmpty
        ExploreSettings.migrateLegacyLanding(sourceURLs: Set(library.map(\.bookSourceUrl)), defaults: defaults)
        isLoaded = true
        subscription = sources.sourcesPublisher
            .map { !$0.isEmpty }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.hasSources = $0 }
    }
}
