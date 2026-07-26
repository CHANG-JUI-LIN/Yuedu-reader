import Foundation
import Testing
@testable import yuedu_app

@Suite("Search result publication gate")
struct SearchResultPublicationGateTests {
    @Test("first active request publishes immediately")
    func firstRequest() {
        var gate = SearchResultPublicationGate(minimumInterval: 0.5)

        #expect(gate.request(now: 10) == .publishNow)
    }

    @Test("burst inside interval schedules only the remaining delay")
    func burst() {
        var gate = SearchResultPublicationGate(minimumInterval: 0.5)
        #expect(gate.request(now: 10) == .publishNow)
        gate.didPublish(at: 10)

        assertScheduledDelay(gate.request(now: 10.2), equals: 0.3)
        assertScheduledDelay(gate.request(now: 10.4), equals: 0.1)
    }

    @Test("request after interval publishes immediately")
    func requestAfterInterval() {
        var gate = SearchResultPublicationGate(minimumInterval: 0.5)
        #expect(gate.request(now: 10) == .publishNow)
        gate.didPublish(at: 10)

        #expect(gate.request(now: 10.5) == .publishNow)
    }

    @Test("forced active request publishes immediately")
    func forcedActiveRequest() {
        var gate = SearchResultPublicationGate(minimumInterval: 0.5)
        #expect(gate.request(now: 10) == .publishNow)
        gate.didPublish(at: 10)

        #expect(gate.request(now: 10.1, force: true) == .publishNow)
    }

    @Test("inactive requests are suppressed and reactivation publishes once")
    func inactive() {
        var gate = SearchResultPublicationGate(minimumInterval: 0.5)
        #expect(gate.setActive(false) == .suppress)
        #expect(gate.request(now: 10, force: true) == .suppress)
        #expect(gate.hasPendingChanges)

        #expect(gate.setActive(true) == .publishNow)
        gate.didPublish(at: 10)
        #expect(!gate.hasPendingChanges)
        #expect(gate.setActive(true) == .suppress)
    }

    private func assertScheduledDelay(
        _ decision: SearchResultPublicationDecision,
        equals expectedDelay: TimeInterval
    ) {
        guard case let .schedule(delay) = decision else {
            Issue.record("Expected a trailing publication")
            return
        }

        #expect(abs(delay - expectedDelay) < 0.000_001)
    }
}
