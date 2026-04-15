import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

// MARK: - CJK 排版後處理器

@Suite("CJKTypographyProcessor")
struct CJKTypographyProcessorTests {

    // MARK: kern 壓縮

    @Test("閉括號後接開括號套用 -1em kern")
    func closingThenOpeningAppliesFullEmKern() {
        let font = UIFont.systemFont(ofSize: 20)
        let attr = NSAttributedString(string: "」「", attributes: [.font: font])

        let result = CJKTypographyProcessor.apply(to: attr)

        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        // halfEm = 10, 閉+開 → -halfEm * 2 = -20
        #expect(kern == -20.0)
    }

    @Test("閉括號後接閉括號套用 -0.5em kern")
    func closingThenClosingAppliesHalfEmKern() {
        let font = UIFont.systemFont(ofSize: 20)
        let attr = NSAttributedString(string: "。，", attributes: [.font: font])

        let result = CJKTypographyProcessor.apply(to: attr)

        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        // halfEm = 10, 閉+閉 → -halfEm = -10
        #expect(kern == -10.0)
    }

    @Test("開括號後接開括號套用 -0.5em kern")
    func openingThenOpeningAppliesHalfEmKern() {
        let font = UIFont.systemFont(ofSize: 20)
        let attr = NSAttributedString(string: "「（", attributes: [.font: font])

        let result = CJKTypographyProcessor.apply(to: attr)

        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        #expect(kern == -10.0)
    }

    @Test("一般 ASCII 文字不加 kern")
    func asciiTextUnchanged() {
        let attr = NSAttributedString(string: "Hello World")
        let result = CJKTypographyProcessor.apply(to: attr)

        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        #expect(kern == 0.0)
    }

    @Test("開括號後接一般字不加 kern")
    func openingThenNormalNokern() {
        let font = UIFont.systemFont(ofSize: 20)
        let attr = NSAttributedString(string: "「你好", attributes: [.font: font])
        let result = CJKTypographyProcessor.apply(to: attr)

        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        #expect(kern == 0.0)
    }

    @Test("單字元輸入直接回傳不修改")
    func singleCharacterSkipped() {
        let attr = NSAttributedString(string: "。")
        let result = CJKTypographyProcessor.apply(to: attr)
        #expect(result.length == 1)
        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        #expect(kern == 0.0)
    }

    @Test("空字串回傳空字串")
    func emptyStringReturnedUnchanged() {
        let attr = NSAttributedString(string: "")
        let result = CJKTypographyProcessor.apply(to: attr)
        #expect(result.length == 0)
    }

    @Test("已有 kern 的情況下累加而非覆蓋")
    func kernAccumulates() {
        let font = UIFont.systemFont(ofSize: 20)
        let mutable = NSMutableAttributedString(string: "」「", attributes: [.font: font])
        mutable.addAttribute(.kern, value: CGFloat(-5.0), range: NSRange(location: 0, length: 1))

        let result = CJKTypographyProcessor.apply(to: mutable)
        let kern = result.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        // 既有 -5 + 閉+開 -20 = -25
        #expect(kern == -25.0)
    }

    // MARK: 字元分類器

    @Test("閉括號分類器識別句末標點")
    func isClosingRecognizesClosingMarks() {
        #expect(CJKTypographyProcessor.isClosing("。"))
        #expect(CJKTypographyProcessor.isClosing("」"))
        #expect(CJKTypographyProcessor.isClosing("）"))
        #expect(CJKTypographyProcessor.isClosing("，"))
        #expect(CJKTypographyProcessor.isClosing("！"))
        #expect(!CJKTypographyProcessor.isClosing("「"))
        #expect(!CJKTypographyProcessor.isClosing("A"))
        #expect(!CJKTypographyProcessor.isClosing("你"))
    }

    @Test("開括號分類器識別前置標點")
    func isOpeningRecognizesOpeningMarks() {
        #expect(CJKTypographyProcessor.isOpening("「"))
        #expect(CJKTypographyProcessor.isOpening("（"))
        #expect(CJKTypographyProcessor.isOpening("【"))
        #expect(!CJKTypographyProcessor.isOpening("）"))
        #expect(!CJKTypographyProcessor.isOpening("。"))
        #expect(!CJKTypographyProcessor.isOpening("Z"))
    }

    @Test("所有閉括號標點都在 lineStartForbidden 集合中")
    func closingMarksAreLineStartForbidden() {
        let diff = CJKTypographyProcessor.closingMarks.subtracting(
            CJKTypographyProcessor.lineStartForbidden)
        #expect(diff.isEmpty)
    }
}

// MARK: - CSS 屬性套用器

@Suite("HTMLCSSPropertyApplierRegistry")
struct CSSPropertyApplierTests {

    private static func makeDefaultStyle(fontSize: CGFloat = 17) -> HTMLAttributedStringBuilder.ResolvedStyle {
        HTMLAttributedStringBuilder.ResolvedStyle(
            fontSize: fontSize,
            fontFamilies: [],
            fontWeight: 400,
            isItalic: false,
            textColor: .black,
            textAlign: .natural,
            textIndent: 0,
            lineHeight: fontSize * 1.4,
            lineHeightExplicit: false,
            paragraphSpacing: 0,
            paragraphSpacingBefore: 0,
            visualOffsetBefore: 0,
            marginLeft: 0,
            listBullet: nil,
            verticalAlign: .baseline,
            isBlock: false,
            backgroundImage: nil,
            backgroundFillColor: nil,
            width: nil,
            height: nil,
            marginRight: 0,
            paddingLeft: 0,
            paddingRight: 0,
            isHorizontallyCentered: false,
            borderTopWidth: 0,
            borderBottomWidth: 0,
            borderLeftWidth: 0,
            borderRightWidth: 0,
            borderTopColor: nil,
            borderBottomColor: nil,
            borderLeftColor: nil,
            borderRightColor: nil,
            opacity: 1,
            letterSpacing: nil,
            hasCSSColor: false,
            configParagraphSpacing: 0
        )
    }

    /// 最小 context，不依賴書源或網路
    private static func makeContext(
        parentStyle: HTMLAttributedStringBuilder.ResolvedStyle,
        rootFontSize: CGFloat = 17
    ) -> HTMLCSSApplyContext {
        HTMLCSSApplyContext(
            parentStyle: parentStyle,
            rootFontSize: rootFontSize,
            resolveLength: { raw, currentFontSize, rootFontSize, _ in
                if raw.hasSuffix("px"), let px = Double(raw.dropLast(2)) { return CGFloat(px) }
                if raw.hasSuffix("em"), let em = Double(raw.dropLast(2)) { return CGFloat(em) * currentFontSize }
                if raw.hasSuffix("rem"), let rem = Double(raw.dropLast(3)) { return CGFloat(rem) * rootFontSize }
                return Double(raw).map { CGFloat($0) }
            },
            parseColor: { raw in
                if raw == "red" { return .red }
                if raw.hasPrefix("#") && raw.count == 7 {
                    var hex = UInt64(0)
                    Scanner(string: String(raw.dropFirst())).scanHexInt64(&hex)
                    return UIColor(
                        red: CGFloat((hex >> 16) & 0xFF) / 255,
                        green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255,
                        alpha: 1)
                }
                return nil
            },
            cssFontWeight: { value, _ in
                switch value {
                case "bold": return 700
                case "normal": return 400
                default: return Int(value) ?? 400
                }
            },
            cssAlignment: { value in
                switch value {
                case "center": return .center
                case "right": return .right
                case "justify": return .justified
                default: return .natural
                }
            },
            cssDisplayIsBlock: { value in
                value == "block" || value == "flex" || value == "grid"
            },
            resolveLineHeight: { raw, fontSize, _ in
                if raw == "normal" { return fontSize * 1.4 }
                if let d = Double(raw) { return CGFloat(d) * fontSize }
                if raw.hasSuffix("px"), let px = Double(raw.dropLast(2)) { return CGFloat(px) }
                return nil
            },
            extractURL: { raw in
                guard raw.hasPrefix("url(") && raw.hasSuffix(")") else { return nil }
                return String(raw.dropFirst(4).dropLast())
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            },
            parseEmbeddedColor: { _ in nil }
        )
    }

    @Test("font-style italic 設定 isItalic")
    func fontStyleItalic() {
        var style = Self.makeDefaultStyle()
        let ctx = Self.makeContext(parentStyle: style)

        HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["font-style": "italic"],
            style: &style,
            context: ctx
        )

        #expect(style.isItalic == true)
    }

    @Test("font-style normal 清除 isItalic")
    func fontStyleNormal() {
        var style = Self.makeDefaultStyle()
        style.isItalic = true
        let ctx = Self.makeContext(parentStyle: style)

        HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["font-style": "normal"],
            style: &style,
            context: ctx
        )

        #expect(style.isItalic == false)
    }

    @Test("font-weight bold 設定 700")
    func fontWeightBold() {
        var style = Self.makeDefaultStyle()
        let ctx = Self.makeContext(parentStyle: style)

        HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["font-weight": "bold"],
            style: &style,
            context: ctx
        )

        #expect(style.fontWeight == 700)
    }

    @Test("text-align center 設定對齊")
    func textAlignCenter() {
        var style = Self.makeDefaultStyle()
        let ctx = Self.makeContext(parentStyle: style)

        HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["text-align": "center"],
            style: &style,
            context: ctx
        )

        #expect(style.textAlign == .center)
    }

    @Test("font-size px 設定字型大小")
    func fontSizePx() {
        var style = Self.makeDefaultStyle()
        let ctx = Self.makeContext(parentStyle: style)

        HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["font-size": "24px"],
            style: &style,
            context: ctx
        )

        #expect(style.fontSize == 24.0)
    }

    @Test("display block 設定 isBlock")
    func displayBlock() {
        var style = Self.makeDefaultStyle()
        let ctx = Self.makeContext(parentStyle: style)

        HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["display": "block"],
            style: &style,
            context: ctx
        )

        #expect(style.isBlock == true)
    }

    @Test("未知屬性不影響 style")
    func unknownPropertyIgnored() {
        var style = Self.makeDefaultStyle()
        let ctx = Self.makeContext(parentStyle: style)
        let originalFontSize = style.fontSize

        let handled = HTMLCSSPropertyApplierRegistry.defaultRegistry.apply(
            declarations: ["unknown-prop": "some-value"],
            style: &style,
            context: ctx
        )

        #expect(!handled.contains("unknown-prop"))
        #expect(style.fontSize == originalFontSize)
    }
}

// MARK: - CoreTextPaginator.ChapterLayout

@Suite("CoreTextPaginator.ChapterLayout")
struct ChapterLayoutTests {

    private func makeLayout(text: String, fontSize: CGFloat = 18) -> CoreTextPaginator.ChapterLayout {
        let font = UIFont.systemFont(ofSize: fontSize)
        let attr = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: UIColor.black])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let halfLen = text.utf16.count / 2

        return CoreTextPaginator.ChapterLayout(
            spineIndex: 0,
            attributedString: attr,
            framesetter: framesetter,
            pageRanges: [CFRangeMake(0, halfLen), CFRangeMake(halfLen, text.utf16.count - halfLen)],
            inlineAttachments: [:],
            blockAttachments: [:],
            blockRenderables: [:],
            pageKinds: [.text, .text],
            pageBackgroundImage: nil,
            anchorOffsets: [:],
            renderSize: CGSize(width: 320, height: 568),
            fontSize: fontSize,
            contentInsets: UIEdgeInsets(top: 10, left: 15, bottom: 10, right: 15)
        )
    }

    @Test("withUpdatedColors 保留結構，僅更新顏色")
    func withUpdatedColorsPreservesStructure() {
        let layout = makeLayout(text: "春眠不覺曉，處處聞啼鳥。")

        let updated = layout.withUpdatedColors(
            textColor: .blue,
            backgroundColor: .systemGray6
        )

        #expect(updated.pageRanges.count == layout.pageRanges.count)
        #expect(updated.fontSize == layout.fontSize)
        #expect(updated.renderSize == layout.renderSize)
        #expect(updated.spineIndex == layout.spineIndex)
    }

    @Test("withUpdatedColors 更新後前景色正確")
    func withUpdatedColorsChangesTextColor() {
        let layout = makeLayout(text: "朝辭白帝彩雲間，千里江陵一日還。")
        let updated = layout.withUpdatedColors(textColor: .red, backgroundColor: .white)

        let color = updated.attributedString.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(color == .red)
    }

    @Test("空字串 layout withUpdatedColors 直接回傳自身")
    func withUpdatedColorsEmptyStringReturnsSelf() {
        let layout = makeLayout(text: "")
        let updated = layout.withUpdatedColors(textColor: .green, backgroundColor: .clear)
        #expect(updated.attributedString.length == 0)
    }
}
