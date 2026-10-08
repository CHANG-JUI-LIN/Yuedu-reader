import Combine
import SwiftUI
import TipKit

struct ExploreModeTip: Tip {
    @Parameter static var sourcesImported: Bool = false
    static let exploreOpenedAfterImport = Tips.Event(id: "explore.openedAfterImport")
    var title: Text { Text(localized("可以切換探索內容")) }
    var message: Text? { Text(localized("來源配置已匯入，點這裡切換到來源配置探索。")) }
    var image: Image? { Image(systemName: "arrow.left.arrow.right") }
    var rules: [Rule] {
        #Rule(Self.$sourcesImported) { $0 }
        #Rule(Self.exploreOpenedAfterImport) { $0.donations.count >= 1 }
    }
    var options: [any TipOption] { MaxDisplayCount(1) }
    var actions: [Action] { Action(id: "switch", title: localized("切換到來源配置")) }
}

struct ExploreImportDetector {
    private(set) var hasEverImportedSources: Bool
    private(set) var guidePending: Bool
    init(hasImportedSources: Bool, hasEverImportedSources: Bool = false, guidePending: Bool = false) {
        self.hasEverImportedSources = hasImportedSources || hasEverImportedSources
        self.guidePending = guidePending
    }
    @discardableResult mutating func receive(hasImportedSources: Bool) -> Bool {
        guard hasImportedSources, !hasEverImportedSources else { return false }
        hasEverImportedSources = true
        guidePending = true
        return true
    }
}

/// The one import observer is alive from launch, including imports from Settings
/// before the reader visits Explore. The tab owns the model's UI subscription.
@MainActor
final class ExploreTabModel: ObservableObject {
    static let shared = ExploreTabModel()
    static let everImportedKey = "explore.hasEverImportedSources"
    static let pendingGuideKey = "explore.firstSourceGuidePending"
    @Published private(set) var hasSources: Bool
    @Published private(set) var guidePending: Bool
    private var detector: ExploreImportDetector
    private var subscription: AnyCancellable?

    init(sources: BookSourceStore = .shared, defaults: UserDefaults = .standard) {
        let initiallyHasSources = !sources.sources.isEmpty
        hasSources = initiallyHasSources
        detector = ExploreImportDetector(hasImportedSources: initiallyHasSources,
            hasEverImportedSources: defaults.bool(forKey: Self.everImportedKey),
            guidePending: defaults.bool(forKey: Self.pendingGuideKey))
        guidePending = detector.guidePending
        defaults.set(detector.hasEverImportedSources, forKey: Self.everImportedKey)
        ExploreModeTip.sourcesImported = guidePending
        subscription = sources.$sources
            .map { !$0.isEmpty }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] hasSources in
                guard let self else { return }
                self.hasSources = hasSources
                if self.detector.receive(hasImportedSources: hasSources) {
                    defaults.set(true, forKey: Self.everImportedKey)
                    defaults.set(true, forKey: Self.pendingGuideKey)
                    self.guidePending = true
                    ExploreModeTip.sourcesImported = true
                }
            }
    }

    func appeared(librariesAvailable: Bool) {
        guard librariesAvailable, hasSources, guidePending else { return }
        Task { await ExploreModeTip.exploreOpenedAfterImport.donate() }
    }
}
