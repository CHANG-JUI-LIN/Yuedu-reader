import Foundation
import UIKit

// MARK: - RenderableNode
//
// 渲染管道的統一中介表示（IR, Intermediate Representation）。
//
// 設計目標：
//   - 所有格式的 Parser（TXT / EPUB / Web / Markdown / PDF）都輸出此型別
//   - 所有渲染器（CoreText 翻頁 / UIScrollView 捲動 / 未來的 PDF 匯出）都消費此型別
//   - 格式與渲染容器完全解耦，加新格式只需寫 Converter，渲染層一行不動
//
// 遷移策略：
//   `HTMLAttributedStringBuilder.ASTNode` 透過橋接 extension 轉成 RenderableNode，
//   讓 HTML 路徑在過渡期繼續正常工作，不做大爆炸重寫。

/// 渲染 IR 節點。`indirect` 支援巢狀容器（block 內有 inline 等）。
public indirect enum RenderableNode: Sendable {

    // MARK: 區塊（Block-level）

    /// 段落。由一組行內節點組成，前後各有段落間距。
    case paragraph([RenderableNode], style: RenderStyle = .body)

    /// 標題（h1-h6）。
    case heading([RenderableNode], level: Int, style: RenderStyle = .none)

    /// 分隔線（<hr>）。
    case horizontalRule(style: RenderStyle = .none)

    /// 引言區塊（<blockquote>）。
    case blockquote([RenderableNode])

    /// 列表項目（<li>）。bullet 為文字前綴（"•" / "1."）。
    case listItem([RenderableNode], bullet: String)

    /// 通用容器（<div>/<section>/<article> 等，或格式轉換時的包裝節點）。
    case block(tag: String, children: [RenderableNode], style: RenderStyle = .none)

    // MARK: 行內（Inline-level）

    /// 純文字片段。
    case text(String)

    /// 換行（<br>）。
    case lineBreak

    /// 行內容器（<span>/<em>/<strong>/<code> 等）。
    case inline(tag: String, children: [RenderableNode], style: RenderStyle = .none)

    /// 連結（<a>），href 為目標 URL 或 anchor ID。
    case anchor(href: String, children: [RenderableNode])

    /// Anchor 目標（對應任意元素的 id）。Renderer 會在輸出結果上標記 anchor offset。
    case anchorTarget(id: String, child: RenderableNode)

    // MARK: 媒體

    /// 圖片。src 為相對或絕對路徑，imageLoader 在 Renderer 階段負責非同步載入。
    case image(src: String, alt: String, style: RenderStyle = .none)

    // MARK: 特殊

    /// EPUB 強制分頁（page-break-before / page-break-after）。
    case pageBreak

    /// 降級節點：無法解析的 HTML 片段，交由舊 HTMLAttributedStringBuilder 路徑處理。
    case rawHTML(String)
}

// MARK: - RenderStyle（節點樣式屬性）
//
// 有意設計為輕量 value type（struct + Sendable），
// 可以跨 actor / Task 邊界傳遞，不依賴 UIKit（UIColor → RenderColor）。
// Renderer 階段才把 RenderColor 轉成 UIColor。

public struct RenderStyle: Sendable {
    public var fontSizeMultiplier: CGFloat
    public var fontFamilies: [String]
    public var fontWeight: Int
    public var bold: Bool
    public var italic: Bool
    public var color: RenderColor?
    public var backgroundColor: RenderColor?
    /// CSS text-indent（em 單位）
    public var textIndent: CGFloat
    public var textAlign: RenderTextAlignment
    public var lineHeightMultiplier: CGFloat
    /// CSS margin-left（blockquote、list 縮排）
    public var marginLeft: CGFloat
    /// CSS padding-left
    public var paddingLeft: CGFloat
    /// CSS padding-right
    public var paddingRight: CGFloat
    /// 段落前間距（段距乘數，由 Renderer 套用 baseFontSize 換算）
    public var paragraphSpacingBefore: CGFloat
    /// 段落後間距
    public var paragraphSpacingAfter: CGFloat
    /// 顯式寬高（常見於圖片 / 卡片區塊）
    public var width: CGFloat?
    public var height: CGFloat?
    /// 透明度（常見於圖片 / 裝飾）
    public var opacity: CGFloat
    public var borderTopWidth: CGFloat
    public var borderBottomWidth: CGFloat
    public var borderLeftWidth: CGFloat
    public var borderRightWidth: CGFloat
    public var borderTopColor: RenderColor?
    public var borderBottomColor: RenderColor?
    public var borderLeftColor: RenderColor?
    public var borderRightColor: RenderColor?
    public var isHorizontallyCentered: Bool

    public init(
        fontSizeMultiplier: CGFloat = 1.0,
        fontFamilies: [String] = [],
        fontWeight: Int = 400,
        bold: Bool = false,
        italic: Bool = false,
        color: RenderColor? = nil,
        backgroundColor: RenderColor? = nil,
        textIndent: CGFloat = 0,
        textAlign: RenderTextAlignment = .natural,
        lineHeightMultiplier: CGFloat = 1.0,
        marginLeft: CGFloat = 0,
        paddingLeft: CGFloat = 0,
        paddingRight: CGFloat = 0,
        paragraphSpacingBefore: CGFloat = 0,
        paragraphSpacingAfter: CGFloat = 0,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        opacity: CGFloat = 1.0,
        borderTopWidth: CGFloat = 0,
        borderBottomWidth: CGFloat = 0,
        borderLeftWidth: CGFloat = 0,
        borderRightWidth: CGFloat = 0,
        borderTopColor: RenderColor? = nil,
        borderBottomColor: RenderColor? = nil,
        borderLeftColor: RenderColor? = nil,
        borderRightColor: RenderColor? = nil,
        isHorizontallyCentered: Bool = false
    ) {
        self.fontSizeMultiplier = fontSizeMultiplier
        self.fontFamilies = fontFamilies
        self.fontWeight = fontWeight
        self.bold = bold
        self.italic = italic
        self.color = color
        self.backgroundColor = backgroundColor
        self.textIndent = textIndent
        self.textAlign = textAlign
        self.lineHeightMultiplier = lineHeightMultiplier
        self.marginLeft = marginLeft
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.paragraphSpacingBefore = paragraphSpacingBefore
        self.paragraphSpacingAfter = paragraphSpacingAfter
        self.width = width
        self.height = height
        self.opacity = opacity
        self.borderTopWidth = borderTopWidth
        self.borderBottomWidth = borderBottomWidth
        self.borderLeftWidth = borderLeftWidth
        self.borderRightWidth = borderRightWidth
        self.borderTopColor = borderTopColor
        self.borderBottomColor = borderBottomColor
        self.borderLeftColor = borderLeftColor
        self.borderRightColor = borderRightColor
        self.isHorizontallyCentered = isHorizontallyCentered
    }

    /// 無任何樣式覆蓋（行內 case 預設）。
    public static let none = RenderStyle()

    /// 正文段落樣式（block case 預設）。
    public static let body = RenderStyle()
}

// MARK: - RenderTextAlignment

public enum RenderTextAlignment: Sendable {
    case natural
    case left
    case center
    case right
    case justify
}

// MARK: - RenderColor（UIKit 無關的顏色型別）

public struct RenderColor: Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 從 UIColor 轉換。
    ///
    /// - Note: UIColor.getRed(_:green:blue:alpha:) 對程式碼建立的顏色（RGB/hex）在任何 thread 均安全。
    ///   動態系統色（.systemBackground 等）若需要 trait solution 時應在 Main thread 呼叫。
    public init?(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.red = r; self.green = g; self.blue = b; self.alpha = a
    }

    /// 轉回 UIColor（在 Renderer 階段使用）。
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

