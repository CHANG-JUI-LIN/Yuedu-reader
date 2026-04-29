import UIKit

/// CJK 排版後處理器。
/// 在 HTMLAttributedStringBuilder.build() 產出 NSAttributedString 後呼叫，
/// 對相鄰全形標點施加負 kern，實現標點擠壓（Punctuation Compression）。
///
/// ## W3C JLREQ 壓縮規則
/// - 閉括號（」。，等）後接閉括號：壓縮閉括號尾部空白（-0.5em kern）
/// - 閉括號後接開括號（「（等）：閉括號尾部 + 開括號前導空白都壓縮（-1.0em kern）
/// - 開括號後接開括號：壓縮後一個開括號的前導空白（-0.5em kern on 前一個開括號）
///
/// ## 不修改字串長度
/// 只修改 `.kern` attribute，不插入字符，charOffset 進度紀錄不受影響。
enum CJKTypographyProcessor {

    // MARK: - 標點分類

    /// 閉括號 / 句尾標點：字形在左，右半為空白
    public static let closingMarks: Set<Unicode.Scalar> = [
        "」", "』", "）", "】", "〕", "｝", "〉", "》",
        "。", "．", "，", "、", "；", "：", "！", "？",
        "\u{2026}", // …
    ]

    /// 開括號：字形在右，左半為空白
    public static let openingMarks: Set<Unicode.Scalar> = [
        "「", "『", "（", "【", "〔", "｛", "〈", "《",
    ]

    /// 行首禁則：不應該出現在行首的標點（通常是閉括號）
    public static let lineStartForbidden: Set<Unicode.Scalar> = closingMarks

    /// 行末禁則：不應該出現在行末的標點（通常是開括號）
    public static let lineEndForbidden: Set<Unicode.Scalar> = openingMarks

    // MARK: - 公開 API

    /// 判斷第一個字是否為開括號，用於行首擠壓
    static func isOpening(_ char: Character) -> Bool {
        guard let first = char.unicodeScalars.first else { return false }
        return openingMarks.contains(first)
    }

    /// 判斷最後一個字是否為閉括號，用於行末擠壓
    static func isClosing(_ char: Character) -> Bool {
        guard let first = char.unicodeScalars.first else { return false }
        return closingMarks.contains(first)
    }

    /// 對 `attrStr` 套用 CJK 標點擠壓與中英混排間距，回傳修改後的副本。
    static func apply(to attrStr: NSAttributedString) -> NSAttributedString {
        guard attrStr.length > 1 else { return attrStr }

        let mutable = NSMutableAttributedString(attributedString: attrStr)
        let string = attrStr.string

        // 使用 Unicode scalar view 以正確處理多 code unit 字符
        let scalars = Array(string.unicodeScalars)
        // 預建 scalar → UTF-16 offset 的對應表
        let utf16Offsets = buildUTF16OffsetMap(for: string)

        guard scalars.count == utf16Offsets.count else { return attrStr }

        for i in 0 ..< scalars.count - 1 {
            let curr = scalars[i]
            let next = scalars[i + 1]
            let utf16Idx = utf16Offsets[i]

            let currIsClosing = closingMarks.contains(curr)
            let currIsOpening = openingMarks.contains(curr)
            let nextIsClosing = closingMarks.contains(next)
            let nextIsOpening = openingMarks.contains(next)

            // 取得當前字符的字體大小，以計算 em 單位
            let fontSize = fontSizeAt(utf16Idx, in: attrStr)
            let halfEm = fontSize * 0.5

            if currIsClosing && nextIsOpening {
                // 閉 + 開：壓縮兩個半寬空白（共 1em）
                addKern(-halfEm * 2, at: utf16Idx, in: mutable)
            } else if currIsClosing && nextIsClosing {
                // 閉 + 閉：壓縮前一個閉括號的尾部空白（0.5em）
                addKern(-halfEm, at: utf16Idx, in: mutable)
            } else if currIsOpening && nextIsOpening {
                // 開 + 開：向左推後一個開括號，壓縮其前導空白（0.5em）
                addKern(-halfEm, at: utf16Idx, in: mutable)
            }

            if shouldApplyCJKLatinSpacing(between: curr, and: next) {
                let spacing = fontSize * 0.125
                addKern(spacing, at: utf16Idx, in: mutable)
            }
        }

        return mutable
    }

    // MARK: - Private helpers

    private static func fontSizeAt(_ utf16Offset: Int, in attrStr: NSAttributedString) -> CGFloat {
        guard attrStr.length > 0, utf16Offset < attrStr.length else { return 17 }
        let font = attrStr.attribute(.font, at: utf16Offset, effectiveRange: nil) as? UIFont
        return font?.pointSize ?? 17
    }

    /// 在 utf16Offset 處累加 kern（若已有 kern 則疊加，避免覆蓋既有排版）
    private static func addKern(_ delta: CGFloat, at utf16Offset: Int, in mutable: NSMutableAttributedString) {
        let range = NSRange(location: utf16Offset, length: 1)
        let existing = mutable.attribute(.kern, at: utf16Offset, effectiveRange: nil) as? CGFloat ?? 0
        mutable.addAttribute(.kern, value: existing + delta, range: range)
    }

    private static func shouldApplyCJKLatinSpacing(
        between lhs: Unicode.Scalar,
        and rhs: Unicode.Scalar
    ) -> Bool {
        (isCJKTextScalar(lhs) && isLatinOrNumberScalar(rhs))
            || (isLatinOrNumberScalar(lhs) && isCJKTextScalar(rhs))
    }

    private static func isLatinOrNumberScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0030...0x0039, 0x0041...0x005A, 0x0061...0x007A:
            return true
        default:
            return false
        }
    }

    private static func isCJKTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    /// 建立 Unicode scalar index → UTF-16 code unit offset 的對應陣列
    private static func buildUTF16OffsetMap(for string: String) -> [Int] {
        var map: [Int] = []
        map.reserveCapacity(string.unicodeScalars.count)
        var utf16Offset = 0
        for scalar in string.unicodeScalars {
            map.append(utf16Offset)
            utf16Offset += scalar.utf16.count
        }
        return map
    }
}
