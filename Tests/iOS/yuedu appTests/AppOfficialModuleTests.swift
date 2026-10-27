import Foundation
import Testing
@testable import yuedu_app

// The official modules that are the app's own code (maintainer, 2026-10-27: 模組 → 官方模組 left
// out 古騰堡, 青空文庫 and AI 推薦): one list for 資源庫's 模組 and for 官方模組.

@Suite("App official modules")
struct AppOfficialModuleTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)

    @Test("AI 推薦, then 古騰堡 and 青空文庫; where the storefront hides the libraries, AI 推薦 alone")
    func available() {
        #expect(AppOfficialModule.available(librariesAvailable: true) == [.aiRecommendations, .library(gutenberg), .library(aozora)])
        #expect(AppOfficialModule.available(librariesAvailable: false) == [.aiRecommendations])
    }

    @Test("each opens its own page and is named as 資源庫 names it")
    func pages() {
        #expect(AppOfficialModule.aiRecommendations.route == .aiRecommendations)
        #expect(AppOfficialModule.library(gutenberg).route == .library(gutenberg))
        #expect(AppOfficialModule.library(aozora).route == .library(aozora))
        #expect(AppOfficialModule.aiRecommendations.title == localized("AI 推薦"))
        #expect(AppOfficialModule.library(gutenberg).title == localized("Project Gutenberg"))
        #expect(AppOfficialModule.library(aozora).title == localized("青空文庫"))
        #expect(AppOfficialModule.library(gutenberg).summary == "gutenberg.org")
        #expect(AppOfficialModule.library(aozora).summary == "aozora.gr.jp")
        #expect(Set(AppOfficialModule.available(librariesAvailable: true).map(\.id)).count == 3)
    }
}
