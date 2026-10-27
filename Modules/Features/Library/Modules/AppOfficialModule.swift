import Foundation

/// The official modules that are the app's own code, not module files: AI 推薦 (AI 推薦 plan 8c),
/// then 古騰堡 and 青空文庫 (M2b, maintainer 2026-10-17: 「公有書庫都算是官方模塊」) where the
/// storefront offers them (`LibraryKeys.available`). 資源庫's 模組 and 模組 → 官方模組 both list them
/// from here, in this order, before the bundled module files (`RuleModuleLibrary.official`): until
/// 2026-10-27 官方模組 listed the files alone, and the maintainer found all three missing.
enum AppOfficialModule: Hashable, Identifiable {
    case aiRecommendations
    case library(SourceInstanceKey)

    static func available(librariesAvailable: Bool) -> [AppOfficialModule] {
        [.aiRecommendations]
            + LibraryKeys.available(connections: [], librariesAvailable: librariesAvailable).map { .library($0) }
    }

    var id: String {
        switch self {
        case .aiRecommendations: "aiRecommendations"
        case .library(let key): key.id
        }
    }

    var title: String {
        switch self {
        case .aiRecommendations: localized("AI 推薦")
        case .library(let key): key.type == .aozora ? localized("青空文庫") : localized("Project Gutenberg")
        }
    }

    /// What it is, in a line: AI 推薦's purpose, a library's site.
    var summary: String {
        switch self {
        case .aiRecommendations: localized("依你最近讀的書推薦作品")
        case .library(let key): key.type == .aozora ? "aozora.gr.jp" : "gutenberg.org"
        }
    }

    /// Its page: what it gives 首頁 and 搜索, and the sites it reaches.
    var route: ExploreNavigationRoute {
        switch self {
        case .aiRecommendations: .aiRecommendations
        case .library(let key): .library(key)
        }
    }
}
