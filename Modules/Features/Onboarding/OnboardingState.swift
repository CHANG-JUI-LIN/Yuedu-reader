import Foundation
import Observation

/// 新手導覽 (maintainer, 2026-10-24): what the app is and how it is used, 探索 first, in six
/// pages a reader can skip at any point, the last one opening where they choose to start.
/// Shown once on each device, to a new install and to a reader updating from an earlier
/// version alike, and again from 設定 → 關於.
///
/// Its own key rather than a `GlobalSettings` value, which the settings sync and export carry:
/// having seen the tour on one device says nothing about another.
@MainActor
@Observable
final class OnboardingState {
    /// UI tests launch with `-onboarding.completed YES` to start on the tabs.
    static let completedKey = "onboarding.completed"

    /// Whether the tour is on screen.
    private(set) var isPresented: Bool
    /// A choice from the last page that opens a page past its tab, until that tab takes it.
    private(set) var pendingStart: OnboardingStart?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPresented = !defaults.bool(forKey: Self.completedKey)
    }

    /// 設定 → 關於 → 新手導覽.
    func replay() {
        isPresented = true
    }

    /// Skipped, finished, or left through one of the last page's choices.
    func finish(startingAt start: OnboardingStart?) {
        defaults.set(true, forKey: Self.completedKey)
        isPresented = false
        pendingStart = start?.opensPage == true ? start : nil
    }

    /// True once, for the tab whose page `start` opens: that tab opens it, and nothing else does.
    func take(_ start: OnboardingStart) -> Bool {
        guard pendingStart == start else { return false }
        pendingStart = nil
        return true
    }
}

/// The tour's pages, in order.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    /// 從探索找書.
    case explore
    /// 一部作品，一個頁面: 搜尋 and 作品詳情 by the work.
    case works
    /// 連接你的所有資源.
    case sources
    /// 長時間閱讀也舒服.
    case reading
    case start

    var id: Int { rawValue }
}

/// Where the last page sends the reader: a tab, and on 書架 and 資源庫 the page past it.
enum OnboardingStart: String, CaseIterable, Identifiable {
    case explore
    case addSources
    case connectLibrary
    case importFiles

    var id: String { rawValue }

    var tab: RootTabItem {
        switch self {
        case .explore: return .explore
        case .addSources, .connectLibrary: return .library
        case .importFiles: return .bookshelf
        }
    }

    /// 資源庫's 來源配置管理 and 遠端書庫, and 書架's 添加書籍, are a page past the tab; 探索 is
    /// the tab itself.
    var opensPage: Bool { self != .explore }

    var titleKey: String {
        switch self {
        case .explore: return "去探索找書"
        // 資源庫's ••• item, by its name.
        case .addSources: return "新增來源配置"
        case .connectLibrary: return "連接書庫"
        // 添加書籍's own tab, by its name.
        case .importFiles: return "匯入文件"
        }
    }

    var detailKey: String {
        switch self {
        case .explore: return "看看首頁幫你排好的書"
        case .addSources: return "從檔案或網址匯入，也能手動新增"
        case .connectLibrary: return "連上 WebDAV、OPDS 或 Calibre"
        case .importFiles: return "把 TXT、EPUB、PDF、漫畫或有聲書加入書架"
        }
    }
}
