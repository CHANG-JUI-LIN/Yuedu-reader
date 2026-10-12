import Foundation
import Testing
@testable import yuedu_app

/// The idiomatic localization review (2026-10-12, `docs/localization/glossary.md`): each
/// language reads like its Apple apps, counts agree in English, and no language says 書源.
struct LocalizationIdiomTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func text(_ key: String, _ language: String) throws -> String {
        NSLocalizedString(key, bundle: try bundle(language), comment: "")
    }

    @Test func detailActionsReadLikeAppleBooks() throws {
        #expect(try text("開始閱讀", "en") == "Read")
        #expect(try text("加入書架", "en") == "Add to Library")
        #expect(try text("加入書架", "ja") == "本棚に追加")
        #expect(try text("加入書架", "ko") == "서재에 추가")
    }

    /// Simplified Chinese is not a character conversion of Taiwan wording.
    @Test func simplifiedChineseUsesMainlandWording() throws {
        #expect(try text("設定", "zh-Hans") == "设置")
        #expect(try text("匯入", "zh-Hans") == "导入")
    }

    @Test func traditionalChineseUsesTaiwanWording() throws {
        #expect(try text("搜索", "zh-Hant") == "搜尋")
        #expect(try text("默認", "zh-Hant") == "預設")
    }

    /// The reader's cover opens a menu (Emby's in-player ⋯), one of whose items is 作品詳情;
    /// VoiceOver must not hear both as the same name.
    @Test func readerBookMenuIsNotTheDetailPage() throws {
        for language in ["zh-Hant", "zh-Hans", "en", "ja", "ko"] {
            #expect(try text("書本選單", language) != text("作品詳情", language), "\(language)")
        }
        #expect(try text("書本選單", "en") == "Book Menu")
    }

    /// The plural rule is the formatting locale's: the app formats in its own language, and the
    /// test host runs in zh-Hant, whose only category is "other" — so the test names English.
    @Test func englishCountsAgree() throws {
        let english = Locale(identifier: "en")
        let format = try text("%d 章", "en")
        #expect(String(format: format, locale: english, 1) == "1 chapter")
        #expect(String(format: format, locale: english, 3) == "3 chapters")
        let mixed = try text("%1$@ · %2$d 個來源配置", "en")
        #expect(String(format: mixed, locale: english, "Gutenberg", 1) == "Gutenberg · 1 source")
        #expect(String(format: mixed, locale: english, "Gutenberg", 2) == "Gutenberg · 2 sources")
    }

    /// One Chinese word, two meanings (關閉 a sheet / a setting that is 關閉): the second meaning
    /// has its own key, 「情境：原字」, so English, Japanese and Korean can say each. Traditional
    /// Chinese reads the same either way.
    @Test func splitKeysSayTheOtherMeaning() throws {
        let splits: [(base: String, split: String, english: String)] = [
            ("關閉", "狀態：關閉", "Off"),
            ("開啟", "動作：開啟", "Open"),
            ("新增", "動作：新增", "Add"),
            ("啟用", "動作：啟用", "Enable"),
            ("隱藏", "動作：隱藏", "Hide"),
            ("顯示", "狀態：顯示", "Shown"),
            ("複製", "動作：建立副本", "Duplicate"),
            ("繼續", "播放：繼續", "Resume"),
            ("重新整理", "網頁：重新整理", "Reload"),
            ("重新驗證", "會員：重新驗證", "Verify Again"),
            ("編輯規則", "提示：編輯規則", "Edits the rule."),
            ("作品詳情", "提示：作品詳情", "Opens Book Details."),
        ]
        for pair in splits {
            #expect(try text(pair.split, "en") == pair.english, "\(pair.split)")
            #expect(try text(pair.split, "en") != text(pair.base, "en"), "\(pair.split)")
            #expect(try text(pair.split, "zh-Hant") == text(pair.base, "zh-Hant"), "\(pair.split)")
        }
        #expect(try text("簡介：更多", "ja") == "続きを読む")
        #expect(try text("值：是", "ja") == "あり")
        #expect(try text("值：否", "ko") == "없음")
        #expect(String(format: try text("章節 %d", "en"), 3) == "Chapter 3")
        #expect(try text("標題：章節", "en") == "Chapter")
    }

    /// A count and its unit were glued from fragments (`"\(n) \(localized("分鐘"))"`), so English
    /// said "1 min" beside "3 books" and could never agree in number; each is one format now.
    @Test func countsAreWholeSentences() throws {
        let english = Locale(identifier: "en")
        func en(_ key: String, _ args: CVarArg...) throws -> String {
            String(format: try text(key, "en"), locale: english, arguments: args)
        }
        #expect(try en("%d 分鐘", 1) == "1 minute")
        #expect(try en("%d 分鐘", 30) == "30 minutes")
        #expect(try en("已選取 %d 個書籤", 1) == "1 Bookmark Selected")
        #expect(try en("已選取 %d 個重點", 2) == "2 Highlights Selected")
        #expect(try en("「%1$@」%2$d 本", "Dune", 1) == "“Dune”: 1 book")
        #expect(try en("抓取 %d 字", 2) == "Fetched 2 characters")
        #expect(try en("%@ 解除連結", "Google") == "Unlink Google")
        #expect(try text("，", "en") == ", ")
        #expect(try text("%d 段落", "ja") == "%d段落", "the overlay's segment count had no key in any table")
        #expect(try text("全選(%1$d/%2$d)", "zh-Hant") == "全選(%1$d/%2$d)")
    }

    /// 「來源配置」 stands in for 書源 on purpose: no language may say it.
    @Test func noLanguageSaysBookSource() throws {
        for language in ["zh-Hant", "zh-Hans", "en", "ja", "ko"] {
            let url = try #require(try bundle(language).url(forResource: "Localizable", withExtension: "strings"))
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            let offending = table.values.filter { $0.range(of: "書源|书源|Book Source|ブックソース|책 소스", options: [.regularExpression, .caseInsensitive]) != nil }
            #expect(offending.isEmpty, "\(language): \(offending.prefix(3))")
        }
    }
}
