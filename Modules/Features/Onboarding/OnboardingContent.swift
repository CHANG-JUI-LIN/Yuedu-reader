import Foundation

/// What the tour says, worked out from the app in front of the reader: a tab they hid is not
/// walked through or offered as a start, a storefront without the public libraries is not
/// promised them, a home made without rankings is not said to have them, and a 閱讀Pro feature
/// they do not have yet says so.
struct OnboardingContent: Equatable {
    /// A line of a page's list: a feature, by the name it has in the app, and its sentence.
    struct Row: Equatable, Identifiable {
        let titleKey: String
        let textKey: String
        /// A 閱讀Pro feature this reader does not have yet: the title carries the Pro lock.
        var isLocked = false

        var id: String { titleKey + textKey }
    }

    /// A page's sentence under its title, where it depends on the reader, and its list.
    struct Copy: Equatable {
        let textKey: String
        let rows: [Row]
    }

    /// 從探索找書; nil while 探索 is hidden, and the page is then left out.
    let explore: Copy?
    /// 一部作品，一個頁面.
    let works: [Row]
    /// 連接你的所有資源.
    let sources: Copy
    /// 長時間閱讀也舒服: how the reader reads, then the looks the reader makes their own.
    let reading: [Row]
    /// 選一個起點: the starts whose tab is shown.
    let starts: [OnboardingStart]

    /// The pages shown: 從探索找書 only while 探索 is, 選一個起點 only while it has a start.
    var pages: [OnboardingPage] {
        OnboardingPage.allCases.filter { page in
            switch page {
            case .explore: return explore != nil
            case .start: return !starts.isEmpty
            case .welcome, .works, .sources, .reading: return true
            }
        }
    }

    /// - Parameters:
    ///   - visibleTabs: The tabs the reader shows.
    ///   - librariesAvailable: Whether the storefront is known and offers the public libraries.
    ///   - languages: 中繼資料語言偏好推薦's languages, which choose a new home's rankings.
    ///   - lockedFeatures: The 閱讀Pro features the reader does not have.
    init(visibleTabs: [RootTabItem], librariesAvailable: Bool, languages: [String],
         lockedFeatures: Set<PremiumFeature>) {
        if visibleTabs.contains(.explore) {
            // The rankings a new home is made with (`HomePageDefaults`): none yet for Korean, nor
            // for Japanese where なろう is hidden.
            let hasRankings = !HomePageDefaults.officialModuleLists(
                languages: languages, publicLibrariesAvailable: librariesAvailable
            ).isEmpty
            explore = Copy(
                textKey: hasRankings
                    ? "打開探索，就有依你的語言排好的排行。各處的書排在同一頁，不分本機或線上。"
                    : "探索是你的首頁，各處的書排在同一頁，不分本機或線上。",
                rows: [
                    Row(titleKey: "最新", textKey: "你連接的書庫一有新書，就會出現在這裡"),
                    Row(titleKey: "編輯首頁", textKey: "在右上角的選單裡排欄目和呈現方式，還能存成好幾套首頁配置"),
                ]
            )
        } else {
            explore = nil
        }

        var works: [Row] = []
        // A tab of its own, which the reader can hide.
        if visibleTabs.contains(.search) {
            works.append(Row(titleKey: RootTabItem.search.titleKey, textKey: "輸入書名或作者，各處的結果依作品合併成一份清單"))
        }
        works += [
            Row(titleKey: "作品詳情", textKey: "同一部作品在各處的版本列在一起，用「換源」挑要讀哪一個"),
            Row(titleKey: "自動補齊書籍資料", textKey: "你的書缺封面、簡介或分類，會在 Wi-Fi 下自動補上"),
            Row(titleKey: "聚合設定", textKey: "要搜尋哪些地方、先用哪裡的資料，都能自己選"),
        ]
        self.works = works

        sources = Copy(
            textKey: visibleTabs.contains(.library)
                ? "來源配置、模組和遠端書庫都在資源庫，加進來就跟內建的一起用。"
                : "加進來的來源配置、模組和遠端書庫，跟內建的一起用。",
            rows: [
                Row(titleKey: "來源配置", textKey: "匯入或手動新增，搜尋和換源就會用上，它的分類也能加進首頁"),
                Row(titleKey: "模組", textKey: librariesAvailable
                    ? "內建 Project Gutenberg、青空文庫、Open Library、小説家になろう、Bangumi、AniList 等官方模組，也能自己加入更多"
                    : "內建 Open Library、Bangumi、AniList、openBD 等官方模組，也能自己加入更多"),
                Row(titleKey: "遠端書庫", textKey: "連接 WebDAV、OPDS 或 Calibre，新書會出現在首頁的最新"),
                Row(titleKey: "本機檔案", textKey: "TXT、EPUB、PDF、漫畫和有聲書，也能用電腦傳書從 Calibre 傳過來"),
                Row(titleKey: "iCloud 同步", textKey: "書籍、閱讀進度、來源配置和閱讀設定，在你的裝置之間同步"),
            ]
        )

        reading = [
            Row(titleKey: "劃線與書籤", textKey: "選取文字就能劃線，重要的頁面加上書籤"),
            Row(titleKey: "聽書", textKey: "把書念給你聽"),
            Row(titleKey: "自動閱讀", textKey: "自動往下讀，速度和翻頁方式都能調"),
            // By the names their rows have in 設定.
            Row(titleKey: "外觀主題", textKey: "在設定裡自己調 App 與閱讀的配色，還有每一頁的背景",
                isLocked: lockedFeatures.contains(.readerThemePacks)),
            Row(titleKey: "底部 Tab", textKey: "在外觀主題裡選要顯示哪些分頁，還有大小和圖示",
                isLocked: lockedFeatures.contains(.bottomBarCustomization)),
        ]

        starts = OnboardingStart.allCases.filter { visibleTabs.contains($0.tab) }
    }
}
