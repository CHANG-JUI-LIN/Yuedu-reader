import Foundation
import Testing
@testable import yuedu_app

/// `DiscoverViewModel` drains its section queue in a loop. It used to recurse once per
/// entry it dropped, each frame holding a copy of the page's source, so a long queue
/// overflowed the main thread's stack (Crashlytics 8f67787a: KERN_PROTECTION_FAILURE in
/// `selectedSource.getter`).
///
/// Every category here has an empty URL, which `discoverBooks` answers with no books and
/// no request, so the one fetch the queue starts finishes without the network.
@MainActor
@Suite("Discover section queue", .serialized)
struct DiscoverSectionQueueTests {
    /// Far past the depth the recursion survived on the simulator's main thread.
    private let queued = 10_000

    @Test("a source deleted from the store drops a long queue")
    func deletedSourceDropsQueue() async throws {
        let model = queueEverySection()
        model.exploreSources = []
        try await waitUntil { model.sections[0].phase == .loaded }
        #expect(model.sections.dropFirst().allSatisfy { $0.phase == .idle })
    }

    @Test("categories turned off are skipped to the next one still shown")
    func turnedOffCategoriesAreSkipped() async throws {
        let model = queueEverySection()
        // 發現頁設定 turns off every category but the first and the last.
        model.sections = [model.sections[0], model.sections[queued - 1]]
        try await waitUntil { model.sections[1].phase == .loaded }
        #expect(model.sections[0].phase == .loaded)
    }

    /// A page whose every category is queued: the first one's fetch started, the rest
    /// waiting behind it. The fetch cannot finish before this returns, since both run on
    /// the main actor.
    private func queueEverySection() -> DiscoverViewModel {
        var source = BookSource()
        source.bookSourceName = "Section queue"
        source.bookSourceUrl = "https://section-queue.test"
        let model = DiscoverViewModel(source: source)
        model.sections = (0..<queued).map { index in
            let item = DiscoverCardItem(
                title: "\(index)",
                stableKey: "\(index)",
                raw: .init(title: "\(index)", url: ""),
                isAction: false,
                actionURL: nil,
                isFetchable: true
            )
            return DiscoverShowcaseSection(item: item, coverBaseURL: nil, coverHeaders: [:])
        }
        for section in model.sections { model.loadSection(section.id) }
        return model
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for the queue")
    }
}
