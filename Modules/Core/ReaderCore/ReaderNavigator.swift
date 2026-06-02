import Combine
import CoreGraphics
import Foundation

@MainActor
final class ReaderNavigator: ObservableObject {
    @Published private(set) var sessionStore: ReaderSessionStore

    private let positionStore: (any ReadingPositionStore)?
    private let bookId: String
    private var saveTask: Task<Void, Never>?
    private let debounceInterval: UInt64 = 300_000_000

    init(
        initialState: ReaderPresentationState,
        positionStore: (any ReadingPositionStore)? = nil,
        bookId: String
    ) {
        self.sessionStore = ReaderSessionStore(initialState: initialState)
        self.positionStore = positionStore
        self.bookId = bookId
    }

    var state: ReaderPresentationState {
        sessionStore.state
    }

    @discardableResult
    func restore() async -> ReaderLocation {
        guard let positionStore,
              let saved = await positionStore.load(for: bookId) else {
            return state.location
        }
        let location = ReaderLocation(saved, source: .restored)
        sessionStore.move(to: location)
        return location
    }

    @discardableResult
    func restoreSync() -> ReaderLocation {
        guard let positionStore,
              let saved = positionStore.loadSync(for: bookId) else {
            return state.location
        }
        let location = ReaderLocation(saved, source: .restored)
        sessionStore.move(to: location)
        return location
    }

    func settle(
        at position: CoreTextReadingPosition,
        pageIndex: Int?,
        totalPages: Int?,
        persist: Bool = true
    ) {
        move(
            to: location(
                for: position,
                source: .settledPage,
                pageIndex: pageIndex,
                totalPages: totalPages
            ),
            persist: persist
        )
    }

    func jump(
        to position: CoreTextReadingPosition,
        pageIndex: Int? = nil,
        totalPages: Int? = nil,
        isEstimated: Bool = false
    ) {
        move(
            to: location(
                for: position,
                source: .jump,
                pageIndex: pageIndex,
                totalPages: totalPages,
                isEstimated: isEstimated
            )
        )
    }

    func switchMode(to position: CoreTextReadingPosition) {
        move(to: ReaderLocation(position, source: .modeSwitch))
    }

    func scrollCommit(to position: CoreTextReadingPosition) {
        move(to: ReaderLocation(position, source: .scrollCommit))
    }

    func internalLink(to position: CoreTextReadingPosition, pageIndex: Int?, totalPages: Int?) {
        move(
            to: location(
                for: position,
                source: .internalLink,
                pageIndex: pageIndex,
                totalPages: totalPages
            )
        )
    }

    func restore(to position: CoreTextReadingPosition, pageIndex: Int? = nil, totalPages: Int? = nil, isEstimated: Bool = false) {
        move(
            to: location(
                for: position,
                source: .restored,
                pageIndex: pageIndex,
                totalPages: totalPages,
                isEstimated: isEstimated
            ),
            persist: false
        )
    }

    func updateAppearance(_ appearance: ReaderAppearance) {
        sessionStore.updateAppearance(appearance)
    }

    func updateViewport(_ size: CGSize) {
        sessionStore.updateViewport(size)
    }

    func updateDirection(_ direction: ReaderReadingDirection) {
        sessionStore.updateDirection(direction)
    }

    func switchPagingStyle(_ style: ReaderPagingStyle) {
        sessionStore.switchPagingStyle(style)
    }

    func updateSpreadMode(_ spreadMode: ReaderSpreadMode) {
        sessionStore.updateSpreadMode(spreadMode)
    }

    func flush() async {
        saveTask?.cancel()
        guard let positionStore else { return }
        await positionStore.save(state.location.coreTextPosition, for: bookId)
        await positionStore.flush(for: bookId)
    }

    private func move(to location: ReaderLocation, persist: Bool = true) {
        sessionStore.move(to: location)
        guard persist, let positionStore else { return }
        saveTask?.cancel()
        let bookId = bookId
        let position = location.coreTextPosition
        saveTask = Task {
            try? await Task.sleep(nanoseconds: debounceInterval)
            guard !Task.isCancelled else { return }
            await positionStore.save(position, for: bookId)
        }
    }

    private func location(
        for position: CoreTextReadingPosition,
        source: ReaderLocation.Source,
        pageIndex: Int?,
        totalPages: Int?,
        isEstimated: Bool = false
    ) -> ReaderLocation {
        let fraction: Double?
        if let pageIndex, let totalPages, totalPages > 1 {
            fraction = Double(pageIndex) / Double(totalPages - 1)
        } else {
            fraction = nil
        }
        return ReaderLocation(
            position,
            source: source,
            isEstimated: isEstimated,
            progression: ReaderLocation.Progression(
                pageIndex: pageIndex,
                totalPages: totalPages,
                fraction: fraction
            )
        )
    }
}
