import Foundation
import Testing
@testable import yuedu_app

/// Deliberate local setup through the same services as the app's import UI.
/// No embedded sources, credentials or network fixtures.
@Suite(.serialized)
@MainActor
struct LocalReaderScenarioTests {
    struct Scenario: Decodable {
        let action: String
        var sourcePath: String?
        var themePath: String?
    }

    nonisolated private static let directoryPath = "/tmp/yuedu-reader-profiling"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directoryPath + "/scenario.json"), "Write a scenario to /tmp/yuedu-reader-profiling/scenario.json"))
    func applyLocalScenario() async throws {
        let directory = URL(fileURLWithPath: Self.directoryPath, isDirectory: true)
        let file = directory.appendingPathComponent("scenario.json")
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: file))
        switch scenario.action {
        case "source":
            let path = try #require(scenario.sourcePath)
            let count = try BookSourceStore.shared.importFromData(Data(contentsOf: URL(fileURLWithPath: path)), fileExtension: "json")
            #expect(count > 0)
            BookSourceStore.shared.waitForQueuedWrites()
            GlobalSettings.shared.pageTurnStyle = .curl
            try "sourceImported=\(count) pageTurnStyle=curl".write(to: directory.appendingPathComponent("scenario-result.txt"), atomically: true, encoding: .utf8)
        case "theme":
            let path = try #require(scenario.themePath)
            let parsed = try await QiThemeImportService.load(Data(contentsOf: URL(fileURLWithPath: path)))
            let result = try await QiThemeImportService.apply(parsed)
            GlobalSettings.shared.pageTurnStyle = .curl
            #expect(!result.appearance.isEmpty)
            let overview = CustomizationImportOverview(qiTheme: result)
            let summary = (overview.appearanceItems + overview.readingItems).map(\.title) + result.notes
            try summary.joined(separator: "\n").write(to: directory.appendingPathComponent("scenario-result.txt"), atomically: true, encoding: .utf8)
        default: Issue.record("Unknown local scenario")
        }
    }
}
