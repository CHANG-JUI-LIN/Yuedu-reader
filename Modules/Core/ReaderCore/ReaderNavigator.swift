import Combine
import CoreGraphics
import Foundation

// MARK: - Page Direction

enum PageDirection {
    case prev
    case next
}

// MARK: - TransitionToken

@MainActor
final class TransitionToken: Identifiable {
    let id = UUID()
    let createdAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private(set) var isSettled = false

    private static let watchdogTimeout: CFAbsoluteTime = 2.5

    func settle() {
        isSettled = true
    }

    var hasTimedOut: Bool {
        !isSettled && (CFAbsoluteTimeGetCurrent() - createdAt) >= Self.watchdogTimeout
    }
}

// MARK: - ReaderNavigator

@MainActor
final class ReaderNavigator: ObservableObject {
    @Published private(set) var sessionStore: ReaderSessionStore

    private let positionStore: (any ReadingPositionStore)?
    private let bookId: String
    private var saveTask: Task<Void, Never>?
    private let debounceInterval: UInt64 = 300_000_000

    // In-flight transition tracking
    private(set) var externalTargetPosition: CoreTextReadingPosition?
    private(set) var inFlightToken: TransitionToken?
    private var pendingTarget: CoreTextReadingPosition?

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

    var currentLocation: CoreTextReadingPosition {
        state.location.coreTextPosition
    }

    // MARK: - Unified Navigation API

    /// The single entry point for all programmatic navigation.
    /// Sets the external target and triggers the caller to execute the transition.
    func go(to position: CoreTextReadingPosition) {
        issueToken()
        externalTargetPosition = position
    }

    /// Page turn intent. Stores the target; the UI layer executes the PVC transition.
    func turnPage(_ direction: PageDirection) {
        // Direction is resolved into a concrete page by the PVC layer.
        // Navigator tracks the in-flight token so the coordinator can match events.
        issueToken()
    }

    /// Called when the user begins an interactive gesture (drag/pan on PVC).
    func handleGestureWillBegin() {
        issueToken()
    }

    /// Called when an interactive gesture settles on a page.
    func handleGestureSettled(at position: CoreTextReadingPosition) {
        settleCurrentToken()
        externalTargetPosition = nil
        move(to: ReaderLocation(position, source: .settledPage))
    }

    /// Called when a programmatic transition completes.
    func notifyTransitionCompleted(at position: CoreTextReadingPosition) {
        settleCurrentToken()
        if externalTargetPosition != nil,
           position.spineIndex == externalTargetPosition?.spineIndex,
           position.charOffset == externalTargetPosition?.charOffset {
            externalTargetPosition = nil
        }
        move(to: ReaderLocation(position, source: .settledPage))
    }

    /// Check watchdog and force-settle if the current token has timed out.
    /// Returns true if a forced settle occurred.
    func checkWatchdog() -> Bool {
        guard let token = inFlightToken, token.hasTimedOut else { return false }
        AppLogger.render("⟐ pageTurn watchdog navigator token=\(token.id) timeout — forcing settle")
        settleCurrentToken()
        externalTargetPosition = nil
        return true
    }

    // MARK: - Existing APIs (delegated to sessionStore)

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

    func clearExternalTarget() {
        externalTargetPosition = nil
    }

    // MARK: - Private

    private func issueToken() {
        if let token = inFlightToken, !token.isSettled {
            // Previous transition still in-flight. Let the old token be;
            // the new token takes over. If the old one times out, watchdog
            // will ignore it since it's no longer current.
        }
        inFlightToken = TransitionToken()
        pendingTarget = nil
    }

    private func settleCurrentToken() {
        inFlightToken?.settle()
        inFlightToken = nil
        pendingTarget = nil
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
