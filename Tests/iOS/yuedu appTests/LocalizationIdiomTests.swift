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
