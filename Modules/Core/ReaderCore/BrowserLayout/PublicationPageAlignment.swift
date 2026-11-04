import YueduCoreText
import Foundation

/// Whether a chapter asks to sit in the middle of its page, as a title page does
/// (Aozora Bunko's ページの左右中央; Aozora plan, Task 15).
///
/// CSS cannot say it: a page's block axis is not a box the stylesheet can centre
/// in. So the chapter says it on its body, as `zy-fontsize-adjust` does, with
/// `zy-page-align: center`. Both engines read it: BrowserAuto through
/// `BrowserLayoutConfig.centersSinglePage`, legacy through
/// `CoreTextPaginator.paginate(centresSinglePage:)`. A chapter longer than a page,
/// and scroll mode, lay out as without it.
enum PublicationPageAlignment {
    static let property = "zy-page-align"

    /// Parsed with the shared CSS declaration parser, as the font scale policy is.
    static func centresSinglePage(bodyInlineStyle: String) -> Bool {
        let decl = CSSParser.parseDeclarationBlock(bodyInlineStyle)
        let value = decl.normal[property] ?? decl.important[property] ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "center"
    }
}
