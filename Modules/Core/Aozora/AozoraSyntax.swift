import Foundation

// The syntax tree of an Aozora Bunko document. Every construct that changes
// the displayed text (gaiji, accents, くの字点, header and colophon) is
// settled here, so later phases change styles only.

/// Which side of the text a ruby, emphasis mark or sideline sits on: right
/// (the default; above in horizontal text) or left (below in horizontal text).
enum AozoraSide: Equatable, Sendable {
    case right
    case left
}

/// The nine 傍点 shapes of aozora2html `command_table.yml`.
enum AozoraEmphasisStyle: String, CaseIterable, Equatable, Sendable {
    case sesameDot = "傍点"
    case whiteSesameDot = "白ゴマ傍点"
    case blackCircle = "丸傍点"
    case whiteCircle = "白丸傍点"
    case blackTriangle = "黒三角傍点"
    case whiteTriangle = "白三角傍点"
    case bullseye = "二重丸傍点"
    case fisheye = "蛇の目傍点"
    case saltire = "ばつ傍点"
}

/// The five 傍線 shapes of aozora2html `command_table.yml`.
enum AozoraSidelineStyle: String, CaseIterable, Equatable, Sendable {
    case solid = "傍線"
    case double = "二重傍線"
    case chain = "鎖線"
    case dashed = "破線"
    case wave = "波線"
}

/// 上付き／下付き小文字 and 行右／行左小書き.
enum AozoraScriptKind: String, CaseIterable, Equatable, Sendable {
    case upper = "上付き小文字"
    case lower = "下付き小文字"
    case lineRight = "行右小書き"
    case lineLeft = "行左小書き"
}

/// 大・中・小見出し.
enum AozoraHeadingLevel: Equatable, Sendable {
    case large
    case medium
    case small
}

/// A heading on its own line, a 同行見出し run into its paragraph, or a
/// 窓見出し set into the start of its paragraph.
enum AozoraHeadingKind: Equatable, Sendable {
    case normal
    case sameLine
    case window
}

/// 改ページ (also written 改頁), 改丁, 改段 and 改見開き.
enum AozoraPageBreakKind: Equatable, Sendable {
    case page
    case leaf
    case column
    case spread
}

enum AozoraGaijiCode: Equatable, Sendable {
    /// JIS X 0213 plane-row-cell, e.g. 1-2-24.
    case jis(plane: Int, row: Int, cell: Int)
    case unicode(UInt32)
}

/// A character outside JIS X 0208, written ※［＃description、code］.
struct AozoraGaiji: Equatable, Sendable {
    /// The character, or nil when the annotation only describes its shape.
    var resolved: String?
    /// The shape description, without the page-line reference.
    var description: String
    var code: AozoraGaijiCode?

    /// The resolved character, or ※ followed by the description in full-width
    /// parentheses (the writer sets the parenthesised part smaller).
    var displayedText: String {
        if let resolved { return resolved }
        return description.isEmpty ? "※" : "※（\(description)）"
    }
}

indirect enum AozoraInline: Equatable, Sendable {
    case text(String)
    case ruby(base: [AozoraInline], reading: String, side: AozoraSide)
    case emphasis(AozoraEmphasisStyle, side: AozoraSide, [AozoraInline])
    case sideline(AozoraSidelineStyle, side: AozoraSide, [AozoraInline])
    case bold([AozoraInline])
    case italic([AozoraInline])
    /// 字級: positive is N steps larger, negative N steps smaller.
    case size(steps: Int, [AozoraInline])
    case tateChuYoko([AozoraInline])
    case gaiji(AozoraGaiji)
    case script(AozoraScriptKind, [AozoraInline])
    case kaeriten(String)
    case kuntenOkurigana(String)
    case warichu([AozoraInline])
    /// A heading that shares its line with other text: 同行見出し, 窓見出し, or a
    /// heading followed by more text on the same source line.
    case heading(AozoraHeadingLevel, AozoraHeadingKind, [AozoraInline])
    /// 罫囲み.
    case boxed([AozoraInline])
    /// 横組み.
    case horizontal([AozoraInline])
    /// キャプション.
    case caption([AozoraInline])
    /// A figure set into a line of text; on a line of its own it is an
    /// `AozoraBlock.image`.
    case image(source: String, width: Int?, height: Int?, caption: [AozoraInline])
    /// ［＃改行］, or the end of a line inside a multi-line heading.
    case lineBreak
    /// 底本では…, ママ, 入力者注 and other proofreading notes. Never displayed.
    case editorialNote(String)
    /// An annotation the parser does not know. Never displayed; counted in diagnostics.
    case unknownAnnotation(String)
}

struct AozoraParagraphStyle: Equatable, Sendable {
    /// 字下げ of the first line, in characters.
    var firstLineIndent = 0
    /// 字下げ of the following lines; differs from the first line only for 折り返して.
    var indent = 0
    /// nil: aligned to the start edge. N: aligned to the end edge, N characters
    /// in (地付き is 0, 地からN字上げ is N).
    var endAlignment: Int?
    /// 字級: positive is N steps larger, negative N steps smaller.
    var sizeSteps = 0
    /// 字詰め: at most N characters per line.
    var characterLimit: Int?
    /// 罫囲み.
    var isBoxed = false
    /// 横組み.
    var isHorizontal = false
    /// キャプション.
    var isCaption = false

    static let plain = AozoraParagraphStyle()
}

enum AozoraBlock: Equatable, Sendable {
    case paragraph([AozoraInline], AozoraParagraphStyle)
    case heading(AozoraHeadingLevel, AozoraHeadingKind, [AozoraInline], AozoraParagraphStyle)
    case pageBreak(AozoraPageBreakKind)
    case image(source: String, width: Int?, height: Int?, caption: [AozoraInline])
}

extension AozoraInline {
    /// The text a reader sees: ruby readings and notes are left out, a gaiji
    /// contributes its character or its ※（description）.
    var displayedText: String {
        switch self {
        case .text(let text): return text
        case .gaiji(let gaiji): return gaiji.displayedText
        case .kaeriten(let text), .kuntenOkurigana(let text): return text
        case .lineBreak: return "\n"
        case .editorialNote, .unknownAnnotation: return ""
        case .ruby(let children, _, _), .emphasis(_, _, let children), .sideline(_, _, let children),
             .bold(let children), .italic(let children), .size(_, let children),
             .tateChuYoko(let children), .script(_, let children), .warichu(let children),
             .heading(_, _, let children), .boxed(let children), .horizontal(let children),
             .caption(let children), .image(_, _, _, let children):
            return children.displayedText
        }
    }
}

extension Array where Element == AozoraInline {
    var displayedText: String { map(\.displayedText).joined() }
}

extension AozoraBlock {
    var displayedText: String {
        switch self {
        case .paragraph(let inlines, _), .heading(_, _, let inlines, _): return inlines.displayedText
        case .pageBreak: return ""
        case .image(_, _, _, let caption): return caption.displayedText
        }
    }
}
