import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1c: the one comparison key for titles and authors (design §7.1).
@Suite("Work match key")
struct WorkMatchKeyTests {
    @Test("titles fold width, case, script, kana, punctuation and symbols")
    func titleFolding() {
        #expect(WorkMatchKey.title("《三體》") == WorkMatchKey.title("三体"))
        #expect(WorkMatchKey.title("ＡＢＣ") == "abc")
        #expect(WorkMatchKey.title("Harry Potter: The Philosopher's Stone") == "harrypotterthephilosophersstone")
        #expect(WorkMatchKey.title("ネコ") == WorkMatchKey.title("ねこ"))
        #expect(WorkMatchKey.title("「吾輩は猫である」") == WorkMatchKey.title("吾輩は猫である"))
        #expect(WorkMatchKey.title(" 【 】 ").isEmpty)
    }

    @Test("digits and the text inside brackets stay")
    func sequelsStayApart() {
        #expect(WorkMatchKey.title("三體") != WorkMatchKey.title("三體Ⅱ"))
        #expect(WorkMatchKey.title("三體Ⅱ") == WorkMatchKey.title("三体II"))
        #expect(WorkMatchKey.title("斗羅大陸") != WorkMatchKey.title("斗罗大陆3"))
        #expect(WorkMatchKey.title("三體（精校版）") == "三体精校版")
    }

    @Test("authors are compatible when equal or contained, at 2 characters or more, on both sides")
    func authors() {
        #expect(WorkMatchKey.authorsCompatible(["劉慈欣"], ["刘慈欣"]))
        #expect(WorkMatchKey.authorsCompatible(["刘慈欣 著"], ["劉慈欣"]))
        #expect(WorkMatchKey.authorsCompatible(["Ken Liu", "劉慈欣"], ["刘慈欣"]))
        #expect(!WorkMatchKey.authorsCompatible(["金"], ["金庸"]), "one character is not enough to contain")
        #expect(!WorkMatchKey.authorsCompatible([], ["刘慈欣"]), "B-level needs an author on both sides")
        #expect(!WorkMatchKey.authorsCompatible([" "], ["刘慈欣"]))
        #expect(!WorkMatchKey.authorsCompatible(["王小波"], ["刘慈欣"]))
    }

    @Test("language tags keep only what the tag says")
    func languageTags() {
        #expect(LanguageTag("zh-Hans") == LanguageTag(language: "zh", script: "Hans"))
        #expect(LanguageTag("zh_TW") == LanguageTag(language: "zh", script: "Hant"), "a written region gives the script")
        #expect(LanguageTag("zh") == LanguageTag(language: "zh"), "no script is filled in")
        #expect(LanguageTag("zho") == LanguageTag(language: "zh"))
        #expect(LanguageTag("chi") == LanguageTag(language: "zh"), "ISO 639-2/B")
        #expect(LanguageTag("jpn") == LanguageTag(language: "ja"))
        #expect(LanguageTag("en-US") == LanguageTag(language: "en", script: "Latn"))
        #expect(LanguageTag("und") == nil)
        #expect(LanguageTag("") == nil)
        #expect(LanguageTag(nil) == nil)
        #expect(LanguageTag("12") == nil)
        #expect(LanguageTag("zh-Hant")?.identifier == "zh-Hant")
    }
}
