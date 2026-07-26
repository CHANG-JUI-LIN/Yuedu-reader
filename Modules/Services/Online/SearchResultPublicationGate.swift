import Foundation

enum SearchResultPublicationDecision: Equatable {
    case publishNow
    case schedule(after: TimeInterval)
    case suppress
}

struct SearchResultPublicationGate {
    let minimumInterval: TimeInterval
    private(set) var isActive: Bool
    private(set) var hasPendingChanges = false
    private var lastPublicationUptime: TimeInterval?

    init(minimumInterval: TimeInterval = 0.5, isActive: Bool = true) {
        precondition(minimumInterval > 0)
        self.minimumInterval = minimumInterval
        self.isActive = isActive
    }

    mutating func request(
        now: TimeInterval,
        force: Bool = false
    ) -> SearchResultPublicationDecision {
        hasPendingChanges = true
        guard isActive else { return .suppress }
        guard !force, let lastPublicationUptime else { return .publishNow }

        let remaining = minimumInterval - (now - lastPublicationUptime)
        return remaining <= 0 ? .publishNow : .schedule(after: remaining)
    }

    mutating func didPublish(at uptime: TimeInterval) {
        lastPublicationUptime = uptime
        hasPendingChanges = false
    }

    mutating func setActive(_ active: Bool) -> SearchResultPublicationDecision {
        let wasActive = isActive
        isActive = active
        guard active, !wasActive, hasPendingChanges else { return .suppress }
        return .publishNow
    }
}
