import Combine

@MainActor
final class ReaderTouchZoneEditorModel: ObservableObject {
    @Published private(set) var draft: TouchZoneConfig

    private let persist: (TouchZoneConfig) -> Void
    private let disableGlobalPaging: () -> Void

    init(
        initial: TouchZoneConfig,
        save: @escaping (TouchZoneConfig) -> Void,
        disableGlobalPaging: @escaping () -> Void
    ) {
        draft = initial.zones.count == 9 ? initial : .default
        persist = save
        self.disableGlobalPaging = disableGlobalPaging
    }

    convenience init() {
        self.init(
            initial: .load(),
            save: { $0.save() },
            disableGlobalPaging: { GlobalSettings.shared.readerTapBothSidesNextPage = false }
        )
    }

    func set(_ action: TouchAction, at index: Int) {
        guard draft.zones.indices.contains(index) else { return }
        draft.zones[index] = action
    }

    func restoreDefault() {
        draft = .default
    }

    @discardableResult
    func save(isProActive: Bool) -> Bool {
        guard isProActive, draft.zones.count == 9 else { return false }
        persist(draft)
        disableGlobalPaging()
        return true
    }
}
