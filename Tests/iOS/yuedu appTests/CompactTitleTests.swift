import Foundation
import Testing
@testable import yuedu_app

/// `ReaderHTMLUtilities.compactTitle` replaced `displayText(fromHTMLFragment:)` + a `\s+`
/// regex removal in title comparison and the volume-separator rules. It must give the same
/// answer: a difference would make an unchanged table of contents read as changed (every
/// chapter re-validated) or a volume heading read as a chapter.
@Suite("Compact chapter titles")
struct CompactTitleTests {
    /// What every caller computed before.
    private func legacy(_ text: String) -> String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    static let corpus: [String] = [
        "第1章 風起雲湧",
        "  第二章\t開端  ",
        "第三章\u{3000}全形空白",
        "第四章\u{00A0}不換行空白",
        "第五章\r\n換行",
        "第六章\u{000B}垂直定位\u{000C}換頁",
        "第七章\u{2028}行分隔\u{2029}段分隔",
        "第八章\u{0085}NEL",
        "第九章\u{200B}零寬空白",
        "第十章\u{200E}方向\u{202B}控制\u{FEFF}",
        "<b>第十一章</b> 粗體",
        "第十二章&nbsp;實體&amp;符號",
        "第十三章 &lt;br&gt; 編碼標籤",
        "第十四章<br/>換行標籤",
        "第一卷 少年行",
        "第十卷第三章 卷中章",
        "正文卷",
        "作品相關",
        "番外",
        "Chapter 1:  The   Beginning",
        "",
        "   ",
        "&#160;",
        "😀 表情 🇹🇼",
    ]

    @Test("matches the old display-text + whitespace-regex result", arguments: corpus)
    func matchesLegacy(_ title: String) {
        #expect(ReaderHTMLUtilities.compactTitle(title) == legacy(title))
    }

    @Test("volume-separator rules are unchanged")
    func volumeSeparators() {
        #expect(OnlineChapterRef.isVolumeSeparatorTitle("第一卷 少年行"))
        #expect(OnlineChapterRef.isVolumeSeparatorTitle(" 正文 "))
        #expect(OnlineChapterRef.isVolumeSeparatorTitle("<b>番外卷</b>"))
        #expect(!OnlineChapterRef.isVolumeSeparatorTitle("第十卷第三章 卷中章"))
        #expect(!OnlineChapterRef.isVolumeSeparatorTitle("第1章 風起雲湧"))
        #expect(!OnlineChapterRef.isVolumeSeparatorTitle("卷首語"))
    }
}
