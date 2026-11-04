import CoreText
import UIKit
import YueduCoreTextTypography

/// Authored `text-emphasis` on a text node, until `ReaderTextEmphasis.applyMarks` turns it
/// into marks (`HTMLAttributedStringBuilder.textEmphasisAttribute`).
final class ReaderTextEmphasisMark: NSObject {
    let emphasis: RenderTextEmphasis

    init(_ emphasis: RenderTextEmphasis) {
        self.emphasis = emphasis
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ReaderTextEmphasisMark)?.emphasis == emphasis
    }

    override var hash: Int { emphasis.style.mark(vertical: false).hashValue }
}

/// Legacy's emphasis marks: one ruby annotation per character that takes a mark
/// (`TextEmphasisCharacters`, BrowserAuto's rules), the mark at half the text's size, `before`
/// for `over` and `right`, `after` for `under` and `left`. Core Text then makes room for the
/// marks and draws them wherever it draws ruby: paged and scrolled, in both writing modes.
///
/// Chosen by probe over drawing the marks in the page and scroll views as 縦中横 cells are
/// drawn (iOS 27.2 simulator, 2026-11-04; Aozora plan, Task 7):
/// - each character's annotation stays its own mark, next to an identical one too: three
///   marked characters drew three marks, horizontally and vertically;
/// - `before` is drawn over the text and, in vertical writing, on its right; `after` under it
///   and on its left;
/// - Core Text grows only the lines that hold marks, as WebKit does;
/// - only layout code reads the ruby attribute, so speech, search and copied text never see a mark.
///
/// A character under a ruby keeps the ruby and takes no mark. On the ruby's side CSS does the
/// same; on the other WebKit draws both, which one annotation per character cannot. A 縦中横
/// cell's characters take none either, where WebKit gives the cell one.
enum ReaderTextEmphasis {
    /// Turns every `textEmphasisAttribute` run into marks and removes the attribute. Runs after
    /// `relaxParagraphsContainingRubyAnnotations`, which loosens a ruby's whole paragraph: marks
    /// need only their own lines grown, and Core Text grows those.
    static func applyMarks(to text: NSMutableAttributedString, vertical: Bool, language: String?) {
        let full = NSRange(location: 0, length: text.length)
        var runs: [(range: NSRange, emphasis: RenderTextEmphasis)] = []
        text.enumerateAttribute(HTMLAttributedStringBuilder.textEmphasisAttribute, in: full) { value, range, _ in
            if let mark = value as? ReaderTextEmphasisMark { runs.append((range, mark.emphasis)) }
        }
        guard !runs.isEmpty else { return }
        text.removeAttribute(HTMLAttributedStringBuilder.textEmphasisAttribute, range: full)
        let string = text.string as NSString
        var previous: (end: Int, annotation: CTRubyAnnotation)?
        // Two annotations per emphasis, taken in turn. One shared by neighbouring characters
        // would join them into a single ruby with a single mark. One per character made every
        // mark a new attribute value: 43624 spine 1's 17 814 marks took 9 461 ms that way and
        // take 15 ms in turn (iOS 27.2 simulator, 2026-11-04).
        var pairs: [(emphasis: RenderTextEmphasis, annotations: [CTRubyAnnotation])] = []
        for run in runs {
            let pair: [CTRubyAnnotation]
            if let made = pairs.first(where: { $0.emphasis == run.emphasis }) {
                pair = made.annotations
            } else {
                pair = annotations(for: run.emphasis, vertical: vertical, language: language)
                pairs.append((run.emphasis, pair))
            }
            var index = run.range.location
            while index < NSMaxRange(run.range) {
                let unit = string.rangeOfComposedCharacterSequence(at: index)
                index = NSMaxRange(unit)
                guard let scalar = string.substring(with: unit).unicodeScalars.first,
                      TextEmphasisCharacters.receivesMark(scalar),
                      text.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute, at: unit.location,
                                     effectiveRange: nil) == nil,
                      text.attribute(HTMLAttributedStringBuilder.textCombineUprightAttribute, at: unit.location,
                                     effectiveRange: nil) == nil else { continue }
                // The other of the pair from the character just before, whichever run marked it.
                let annotation = previous.map { $0.end == unit.location && $0.annotation === pair[0] } == true
                    ? pair[1] : pair[0]
                text.addAttribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute, value: annotation, range: unit)
                previous = (NSMaxRange(unit), annotation)
            }
        }
    }

    private static func annotations(for emphasis: RenderTextEmphasis, vertical: Bool,
                                    language: String?) -> [CTRubyAnnotation] {
        let mark = emphasis.style.mark(vertical: vertical) as CFString
        let over = vertical ? emphasis.position.right : emphasis.position.isOver(language: language)
        var attributes: [CFString: Any] = [
            kCTRubyAnnotationSizeFactorAttributeName: 0.5,
            kCTRubyAnnotationScaleToFitAttributeName: false,
        ]
        // Without a colour of its own the mark takes its text's, also after a theme change.
        if let color = emphasis.color {
            attributes[kCTForegroundColorAttributeName] = color.uiColor.cgColor
        }
        return (0..<2).map { _ in
            CTRubyAnnotationCreateWithAttributes(.center, .none, over ? .before : .after, mark,
                                                 attributes as CFDictionary)
        }
    }
}
