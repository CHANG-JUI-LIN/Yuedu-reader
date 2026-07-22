import Combine

@MainActor
final class ReaderTouchZoneEditorModel: ObservableObject {
    @Published private(set) var draft: TouchZoneConfig

    private let defaultConfig: TouchZoneConfig
    private let persist: (TouchZoneConfig) -> Void
    private let disableGlobalPaging: () -> Void

    init(
        initial: TouchZoneConfig,
        defaultConfig: TouchZoneConfig = .default,
        save: @escaping (TouchZoneConfig) -> Void,
        disableGlobalPaging: @escaping () -> Void
    ) {
        draft = initial.zones.count == 9 ? initial : defaultConfig
        self.defaultConfig = defaultConfig
        persist = save
        self.disableGlobalPaging = disableGlobalPaging
    }

    convenience init(isRTL: Bool = false) {
        let defaultConfig = TouchZoneConfig.defaultForReadingDirection(isRTL: isRTL)
        self.init(
            initial: TouchZoneConfig.loadSaved() ?? defaultConfig,
            defaultConfig: defaultConfig,
            save: { $0.save() },
            disableGlobalPaging: { GlobalSettings.shared.readerTapBothSidesNextPage = false }
        )
    }

    func set(_ action: TouchAction, at index: Int) {
        guard draft.zones.indices.contains(index) else { return }
        draft.zones[index] = action
    }

    func restoreDefault() {
        draft = defaultConfig
    }

    @discardableResult
    func save(isProActive: Bool) -> Bool {
        guard isProActive, draft.zones.count == 9 else { return false }
        persist(draft)
        disableGlobalPaging()
        return true
    }
}
