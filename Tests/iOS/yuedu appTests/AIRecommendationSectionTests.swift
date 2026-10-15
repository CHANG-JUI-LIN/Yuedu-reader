import Foundation
import Testing
@testable import yuedu_app

/// AI 推薦 8c: the official module's home section serves the stored list, with no request.
@Suite("AI recommendation home section")
@MainActor
struct AIRecommendationSectionTests {
    private func store() throws -> AIRecommendationStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIRecommendationSectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AIRecommendationStore(directory: directory)
    }

    private static let matched = SourceRecord(
        key: SourceItemKey(instance: OpenLibrary.key, item: "/works/OL1W"), title: "Ball Lightning", authors: ["Liu Cixin"],
        language: "en", contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.viewOnly])

    private static let list = AIRecommendationList(
        entries: [
            .init(work: .init(title: "球狀閃電", author: "劉慈欣", reason: "同一位作者。"), openLibrary: matched,
                  cover: .remote(URL(string: "https://covers.openlibrary.org/b/id/1-M.jpg")!, headers: [:]), blurb: "簡介"),
            .init(work: .init(title: "十二國記", author: "小野不由美", reason: "奇幻。")),
        ],
        generatedAt: Date(timeIntervalSince1970: 1_900_000_000), service: "服務", model: "模型")

    @Test("serves the stored works as data-only items: Open Library's record when matched, its own otherwise")
    func servesTheStore() async throws {
        let store = try store()
        let provider = AIRecommendationProvider(store: store)
        let section = HomeSection(layout: .row, binding: .aiRecommendations)
        #expect(try await provider.load(section).isEmpty, "no list yet: nothing, and no request")
        store.save(Self.list)
        let entries = try await provider.load(section)
        #expect(entries == AIRecommendationProvider.entries(from: Self.list))
        guard case .item(let first, let firstSummary, .bibliographic) = entries.first,
              case .item(let second, let secondSummary, .bibliographic) = entries.last else {
            Issue.record("expected two data-only items, got \(entries)")
            return
        }
        #expect(first == Self.matched)
        #expect(firstSummary.title == "球狀閃電", "the title the AI gave, not Open Library's")
        #expect(firstSummary.blurb == "簡介")
        #expect(firstSummary.cover == Self.list.entries[0].cover)
        #expect(second.key.instance == AIRecommendationProvider.recordInstance)
        #expect(second.acquisitions == [.viewOnly])
        #expect(second.authors == ["小野不由美"])
        #expect(secondSummary.cover == .generated(seed: "十二國記"))
        #expect(FilledMetadata.providerName(second.key.instance) == localized("AI 推薦"))
    }

    @Test("serves only its own binding, from the device, and is not a library row")
    func policy() throws {
        let provider = AIRecommendationProvider(store: try store())
        #expect(provider.loadPolicy(for: HomeSection(layout: .row, binding: .aiRecommendations)) == .local)
        #expect(provider.loadPolicy(for: HomeSection(layout: .row, binding: .forYou)) == nil)
        #expect(provider.hosts.isEmpty)
        // `HomeModel.isLibrary` counts only libraries: 為你推薦 must not mix AI picks in.
        #expect(AIRecommendationProvider.instanceKey.type == .library)
    }

    @Test("the binding round-trips, belongs to 官方模組, hides read books, and takes every layout a row of books takes")
    func binding() throws {
        let section = HomeSection(layout: .coverGrid, binding: .aiRecommendations)
        let data = try JSONEncoder().encode(section)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["binding"] as? [String: Any])?["type"] as? String == "aiRecommendations")
        #expect(try JSONDecoder().decode(HomeSection.self, from: data) == section)
        #expect(HomeSectionBinding.aiRecommendations.contentOwner == .official)
        #expect(HomeSectionBinding.official == [.aiRecommendations])
        #expect(HomeReadFilter(hides: true, isRead: { _ in true }).hides(in: .aiRecommendations))
        #expect(HomeLayoutStyle.choices(for: .aiRecommendations) == HomeLayoutStyle.choices(for: .forYou))
        #expect(!HomeLayoutStyle.choices(for: .aiRecommendations).contains(.collection))
        #expect(section.displayTitle(sourceName: "") == localized("AI 推薦"))
    }

    @Test("with no list, the section still takes room: it offers 產生推薦")
    func neverSettledEmpty() {
        let ai = HomeSectionGroup(section: HomeSection(layout: .row, binding: .aiRecommendations), rows: [], entries: [:])
        #expect(ai.state == .loaded([]))
        #expect(!ai.isSettledEmpty)
        let other = HomeSectionGroup(section: HomeSection(layout: .row, binding: .forYou), rows: [], entries: [:])
        #expect(other.isSettledEmpty)
    }
}
