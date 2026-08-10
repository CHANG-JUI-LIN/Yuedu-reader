import Testing
import UIKit
@testable import yuedu_app

/// The line breaker must never split a grapheme/shaping cluster, and must not
/// lose text. Exercises emoji ZWJ sequences, combining marks, Arabic, CJK.
struct BrowserLayoutLineBreakerClusterTests {

    private func assertClusterSafe(attributed: NSAttributedString, maxWidth: CGFloat) {
        let lines = CoreTextLineBreaker().breakLines(attributed: attributed, maxWidth: maxWidth)
        let total = lines.map(\.range.length).reduce(0, +)
        #expect(total == attributed.length, "text lost: \(lines)")
        let ns = attributed.string as NSString
        for line in lines {
            let end = line.range.location + line.range.length
            guard end < ns.length, end > 0 else { continue }
            // The boundary must fall on a composed-character boundary.
            let cluster = ns.rangeOfComposedCharacterSequence(at: end - 1)
            #expect(cluster.location + cluster.length == end,
                    "cluster split at \(end) in '\(attributed.string)'")
        }
    }

    @Test func emojiZWJFamilyNeverSplits() throws {
        let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units, 1 grapheme
        let text = family + " " + family + " " + family + " " + family
        let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        assertClusterSafe(attributed: attr, maxWidth: 100)
        assertClusterSafe(attributed: attr, maxWidth: 40)
        assertClusterSafe(attributed: attr, maxWidth: 15)
    }

    @Test func combiningMarksNeverSeparated() throws {
        let text = "e\u{0301}\u{0301} e\u{0301} e\u{0301} e\u{0301} e\u{0301} e\u{0301} e\u{0301} e\u{0301}"
        let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        assertClusterSafe(attributed: attr, maxWidth: 30)
        assertClusterSafe(attributed: attr, maxWidth: 12)
    }

    @Test func zWJSequencesNeverSplit() throws {
        let text = "👩‍💻 👨‍🚀 👩‍🎤 🧑‍🤝‍🧑 " + String(repeating: "👍👍👍👍 ", count: 4)
        let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        assertClusterSafe(attributed: attr, maxWidth: 60)
        assertClusterSafe(attributed: attr, maxWidth: 20)
    }

    @Test func arabicTextPreservedAndClusterSafe() throws {
        let text = "مرحبا بالعالم هذا نص طويل بما يكفي ليتم تقسيمه إلى عدة أسطر في عمود ضيق"
        let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        assertClusterSafe(attributed: attr, maxWidth: 100)
        let lines = CoreTextLineBreaker().breakLines(attributed: attr, maxWidth: 100)
        #expect(lines.count >= 2)
    }

    @Test func cjkPunctuationClusterSafe() throws {
        let text = "「這是測試！」「第二句！」「第三句！」「第四句！」「第五句！」"
        let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        assertClusterSafe(attributed: attr, maxWidth: 100)
        let lines = CoreTextLineBreaker().breakLines(attributed: attr, maxWidth: 100)
        #expect(lines.count >= 2)
    }
}
