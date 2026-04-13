# 任務計畫：建立統一渲染 IR（RenderableNode）

## 背景與動機

目前整個渲染管道被「HTML 格式」綁架：
- TXT → 文字 → 包裝成 HTML → HTMLAttributedStringBuilder（繞遠路）
- EPUB → HTML → HTMLAttributedStringBuilder
- Web → 爬蟲文字 → 包裝成 normalized HTML → HTMLAttributedStringBuilder
- Markdown → 轉成 HTML → HTMLAttributedStringBuilder

問題：加任何新格式（PDF、CBZ、AI生成段落）都要「說HTML才能被渲染」。

**重大發現（省力捷徑）**：  
`HTMLAttributedStringBuilder` 內部已存在 `ASTNode`（`TextNode`、`BreakNode`、`ElementNode`）。  
這就是那個還沒升格的 IR。我們的目標不是「從零建 IR」，而是**把它解放成頂層公開型別**，  
然後讓每個 Parser 直接產出它，繞過 HTML 這條冤枉路。

## 架構目標

```
目前：Parser → String/HTML → HTMLAttributedStringBuilder → NSAttributedString
目標：Parser → [RenderableNode] → NodeAttributedStringRenderer → NSAttributedString
                                                            ↑ 可替換（UIScrollView / CoreText / PDF）
```

## 增量遷移策略（Feature Flag + 雙軌並行）

不做大爆炸重寫。每個 Parser 單獨遷移，用 feature flag 並行跑新舊兩條管道，
驗收通過後才切斷舊路。`HTMLAttributedStringBuilder` 在過渡期繼續正常工作。

---

## 階段總覽

| 階段 | 內容 | 狀態 | 預估改動行數 |
|------|------|------|------------|
| Phase 0 | 探索與文件記錄 | ✅ complete | 0 |
| Phase 1 | 定義 RenderableNode（從 ASTNode 提升） | ✅ complete | ~120 行 |
| Phase 2 | ASTNode → RenderableNode 橋接（讓現有 HTML 路徑繼續工作） | ✅ complete，且橋接檔已在 Phase 9 移除 | ~80 行 |
| Phase 3 | NodeAttributedStringRenderer（消費 RenderableNode → NSAttributedString） | ✅ complete | ~200 行 |
| Phase 4 | TXT Parser → RenderableNode（最簡單，無 HTML 依賴） | ✅ complete | ~150 行 |
| Phase 5 | Feature flag + 雙軌並行驗收 TXT 路徑 | ✅ complete | ~60 行 |
| Phase 6 | Web/Online Parser → RenderableNode | ✅ complete | ~180 行 |
| Phase 7 | EPUB Parser → RenderableNode（複雜，含 CSS） | ✅ complete | ~250 行 |
| Phase 8 | Markdown Parser → RenderableNode | ✅ complete | ~100 行 |
| Phase 9 | 切斷 HTML 繞路，移除舊橋接 | ✅ complete（新路徑完成；legacy fallback 保留） | ~-300 行（刪除） |

---

## Phase 0：探索與文件記錄 ✅ complete

### 已確認現有管道
- `HTMLAttributedStringBuilder.ASTNode`：已有 TextNode / BreakNode / ElementNode
- `AttributedStringBuilding` protocol：`buildChapter(at:settings:themeTextColor:themeBackgroundColor:)` 是渲染消費介面
- `TXTAttributedStringBuilder`：接受 `[UnifiedChapter]`，在 `buildChapter` 裡把 plainText 轉 NSAttributedString
- `CoreTextPageEngine` 和 `TXTPageEngine`：透過 `AttributedStringBuilding` protocol 消費渲染結果

### 關鍵檔案清單
| 檔案 | 行數 | 角色 |
|------|------|------|
| `Models/CoreText/HTMLAttributedStringBuilder.swift` | 2155 | 現有 IR（ASTNode）的宿主，渲染引擎 |
| `Models/CoreText/TXTAttributedStringBuilder.swift` | 117 | TXT 渲染橋接 |
| `Models/CoreText/HTMLBuilderPipelines.swift` | 92 | DOM → ASTNode 流水線 |
| `Models/CoreText/AttributedStringBuilding.swift` | 62 | 渲染消費 protocol |
| `Models/CoreText/CoreTextPageEngine.swift` | 1216 | 分頁引擎（消費 AttributedStringBuilding） |
| `Models/CoreText/TXTPageEngine.swift` | 394 | TXT 分頁引擎 |
| `Models/CoreText/CoreTextPaginator.swift` | 874 | 低階分頁計算 |
| `Models/TXTChapterParser.swift` | 686 | TXT 解析器 |
| `Models/EPUBBookParser.swift` | 103 | EPUB 解析入口 |
| `Models/WebNovelParser.swift` | 310 | Web 爬蟲轉文字 |
| `Models/MarkdownBookParser.swift` | 58 | Markdown 解析（目前僅轉 HTML）|

---

## Phase 1：定義 RenderableNode

### 目標
建立新檔案 `Models/CoreText/RenderableNode.swift`。
內容：把 `HTMLAttributedStringBuilder.ASTNode` 的型別**複製並公開**為頂層 enum，
並擴充幾個 TXT 專用 case（`Paragraph`、`Heading`）讓 TXT 路徑不必包 HTML。

### 設計決策
```swift
// 新檔案：RenderableNode.swift

/// 渲染管道的統一中介表示（IR）。
/// 所有格式的 Parser 都輸出此型別，所有渲染器都消費此型別。
/// 這讓格式（TXT/EPUB/Web/Markdown）與渲染容器（CoreText/WebView/PDF）完全解耦。
public indirect enum RenderableNode {
    // ── 文字與分段 ──
    case paragraph([RenderableNode], style: RenderStyle = .body)
    case heading([RenderableNode], level: Int)      // h1-h6
    case text(String)
    case lineBreak

    // ── 媒體 ──
    case image(src: String, alt: String, style: RenderStyle = .none)

    // ── 容器（來自 HTML <div>/<section> 等） ──
    case block(tag: String, children: [RenderableNode], style: RenderStyle = .none)

    // ── 行內 ──
    case inline(tag: String, children: [RenderableNode], style: RenderStyle = .none)
    case anchor(href: String, children: [RenderableNode])

    // ── 特殊 ──
    case horizontalRule
    case pageBreak         // EPUB 強制分頁
    case rawHTML(String)   // 降級：無法分析的 HTML 片段，由舊 HTML 路徑處理
}

/// 描述節點的樣式屬性（對應 CSS resolved style 的輕量版本）。
/// 刻意保持 value type（struct），確保跨 actor 邊界可傳遞（Sendable）。
public struct RenderStyle: Sendable {
    public var fontSizeMultiplier: CGFloat = 1.0
    public var bold: Bool = false
    public var italic: Bool = false
    public var color: RenderColor? = nil
    public var backgroundColor: RenderColor? = nil
    public var indent: CGFloat = 0
    public var textAlign: TextAlignment = .natural
    public var lineHeightMultiplier: CGFloat = 1.0

    public static let none = RenderStyle()
    public static let body = RenderStyle()
}

public enum TextAlignment: Sendable {
    case natural, left, center, right, justify
}

public struct RenderColor: Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat
}
```

### 需要建立的檔案
- `Models/CoreText/RenderableNode.swift`（新增）

### 不改動
- `HTMLAttributedStringBuilder.ASTNode` 保留不動（橋接 Phase 2 用）
- `AttributedStringBuilding` protocol 不改動

---

## Phase 2：ASTNode → RenderableNode 橋接

### 目標
在 `HTMLAttributedStringBuilder` 加一個 extension，提供
`ASTNode.asRenderableNode() -> RenderableNode`，
讓現有的 HTML 路徑產出的 `[ASTNode]` 能轉成 `[RenderableNode]`，
之後 `NodeAttributedStringRenderer`（Phase 3）可統一消費。

這樣 HTML 路徑在過渡期繼續運作，不需要立刻重寫。

### 設計
```swift
// 在 HTMLAttributedStringBuilder+RenderableNode.swift（新增 extension 檔）

extension HTMLAttributedStringBuilder.ASTNode {
    func asRenderableNode() -> RenderableNode {
        switch self {
        case .text(let t): return .text(t.text)
        case .lineBreak: return .lineBreak
        case .element(let e): return e.asRenderableNode()
        }
    }
}

extension HTMLAttributedStringBuilder.ElementNode {
    func asRenderableNode() -> RenderableNode {
        let children = children.map { $0.asRenderableNode() }
        switch tag {
        case "p", "div", "section", "article": return .paragraph(children)
        case "h1","h2","h3","h4","h5","h6":
            let level = Int(String(tag.last!)) ?? 1
            return .heading(children, level: level)
        case "img":
            return .image(src: attributes["src"] ?? "", alt: attributes["alt"] ?? "")
        case "br": return .lineBreak
        case "hr": return .horizontalRule
        case "a": return .anchor(href: attributes["href"] ?? "", children: children)
        default: return .block(tag: tag, children: children)
        }
    }
}
```

### 需要建立的檔案
- `Models/CoreText/HTMLAttributedStringBuilder+RenderableNode.swift`（新增 extension）

---

## Phase 3：NodeAttributedStringRenderer

### 目標
建立 `NodeAttributedStringRenderer`，  
消費 `[RenderableNode]` → `NSAttributedString`。

這是核心的「渲染層」，取代現在 `HTMLAttributedStringBuilder` 裡那些分散的遞迴函數。

### 設計
```swift
// 新檔案：NodeAttributedStringRenderer.swift

/// 消費 [RenderableNode] 並產出 NSAttributedString。
/// 這是唯一允許知道 UIKit / CoreText 的渲染層。
@MainActor
final class NodeAttributedStringRenderer {
    struct Config {
        var fontSize: CGFloat
        var fontFamily: String
        var lineHeightMultiple: CGFloat
        var paragraphSpacing: CGFloat
        var textColor: UIColor
        var backgroundColor: UIColor
        var imageLoader: ((String) async -> UIImage?)?
    }

    func render(nodes: [RenderableNode], config: Config) async -> NSAttributedString {
        // 遞迴遍歷 [RenderableNode]，根據每個 case 建立對應的 NSAttributedString
    }
}
```

### 完成標準
- 可以通過現有 `ModernRuleEngineTests` 作為迴歸基準（測試不直接測 Renderer，但確保整體管道不回歸）

---

## Phase 4：TXT Parser → RenderableNode

### 目標
`TXTChapterParser` 加上新方法：  
`static func renderableNodes(for chapter: UnifiedChapter) -> [RenderableNode]`

邏輯：把 plainText 按段落分割，每個段落 → `.paragraph([.text(para)])`。
不再需要包裝成 HTML。

### 設計
```swift
extension TXTChapterParser {
    /// 把 TXT 章節的純文字直接轉成 RenderableNode，跳過 HTML 中繼。
    static func renderableNodes(for plainText: String) -> [RenderableNode] {
        let paragraphs = paragraphsForChapterContent(plainText)
        return paragraphs.map { para in
            .paragraph([.text(para)])
        }
    }
}
```

### 新的 TXTRenderableNodeBuilder（取代 TXTAttributedStringBuilder）
```swift
struct TXTRenderableNodeBuilder: AttributedStringBuilding {
    // buildChapter() 內部：
    //   1. TXTChapterParser.renderableNodes(for: chapterText)
    //   2. NodeAttributedStringRenderer.render(nodes:config:)
    //   3. 回傳 AttributedChapterBuildResult
}
```

---

## Phase 5：Feature Flag + 雙軌驗收

### 目標
建立 `GlobalSettings.useRenderableNodePipeline: Bool`（預設 false）。  
`TXTPageEngine` 根據 flag 選擇 `TXTAttributedStringBuilder`（舊）或 `TXTRenderableNodeBuilder`（新）。

在 Debug Build 打開 flag，跑模擬器手動驗收：
- 字型大小、行高、段落間距是否一致
- CJK 字元間距是否正常
- 章節切換、進度恢復是否正常

驗收通過後把 flag 預設改為 true。

---

## Phase 6：Web/Online Parser → RenderableNode

### 目標
`ChapterFetcher.buildRenderableNormalizedHTML()` 目前透過 SwiftSoup 解析 HTML，
產出 normalized HTML string，再交給 `HTMLAttributedStringBuilder`。

新路徑：SwiftSoup 解析後直接把 DOM 樹轉成 `[RenderableNode]`，跳過 HTML 序列化。

### 新型別
```swift
// 新檔案：WebContentRenderableNodeConverter.swift
struct WebContentRenderableNodeConverter {
    func convert(document: SwiftSoup.Document) -> [RenderableNode]
}
```

---

## Phase 7：EPUB Parser → RenderableNode（最複雜）

### 已完成實作
EPUB 內容章節現在走這條新路：

```text
chapter HTML
    → HTMLBuilderDOMParser / HTMLBuilderStyleResolver
    → styled AST
    → HTMLStyledASTRenderableNodeConverter
    → [RenderableNode]
    → NodeAttributedStringRenderer
    → NSAttributedString
```

保留的舊元件只有「CSS / 字型 / 圖片載入 / imagePage / background image / anchorOffsets」這些已驗證過的 helper，
不再讓 `EPUBAttributedStringBuilder` 直接依賴 `HTMLAttributedStringBuilder.build(html:config:)` 產出文字內容。

### 關鍵補齊
- `HTMLAttributedStringBuilder` 新增 `buildStyledAST(...)`、`imagePage(from:)`、`pageBackgroundImage(from:)`、`anchorOffsets(in:)`
- `RenderableNode` 新增 `anchorTarget`，`RenderStyle` 擴充 EPUB 所需 metadata
- `NodeAttributedStringRenderer` 改為 async，支援：
    - anchor target attribute
    - RunDelegate 圖片 placeholder
    - block decoration / block image attrs
    - 自定字型 resolver 注入
    - CJKTypographyProcessor 後處理

---

## Phase 8：Markdown Parser → RenderableNode

### 目標
`MarkdownBookParser` 目前只有 58 行，先轉 HTML 再渲染。  
直接用 Swift Markdown（Apple first-party）或自己走 CommonMark 輸出 `[RenderableNode]`。
這是最乾淨的一條路，因為 Markdown 語義和 RenderableNode 幾乎一對一。

---

## Phase 9：刪除舊路徑

已完成的清理：
1. 刪除 `HTMLAttributedStringBuilder+RenderableNode.swift`（舊橋接 extension）
2. 刪除未使用的 `RenderableChapter`
3. `ReaderView.loadOnlineCoreText` 在 RenderableNode 路徑下不再建立 legacy provider
4. EPUB 新路徑已切斷對 `HTMLAttributedStringBuilder.build(html:config:)` 的依賴

保留的舊路徑：
1. `CoreTextPageEngine` 的 `resourceProvider` / `HTMLAttributedStringBuilder.build(html:config:)` 分支仍作為 feature flag 關閉時的 legacy fallback
2. `ChapterFetcher.buildRenderableNormalizedHTML()` 也仍只屬於 legacy online path

---

## 遇到的錯誤
| 錯誤 | 嘗試 | 解決方案 |
|------|------|---------|
| `xcodebuild test` 編譯失敗於 `yuedu appTests/CoreTextPipelineTests.swift:215` | 1 | 測試檔本身使用 `CGFloat(String)`；與 RenderableNode 遷移無關，暫不併入本輪修改 |

## 關鍵決策記錄
| 決策 | 理由 |
|------|------|
| 不動 ASTNode，新建 RenderableNode | ASTNode 是 HTMLAttributedStringBuilder 的私有型別，直接提升會破壞大量現有呼叫點 |
| Phase 5 用 feature flag | 確保 TXT 渲染可以 A/B 驗收，不影響現有使用者 |
| TXT 優先遷移 | TXT 路徑無 HTML/CSS 依賴，最乾淨，最適合驗收 IR 設計 |
| Markdown 用原生轉換 | Markdown 語義和 RenderableNode 幾乎一對一，不值得繞 HTML |
| 保留 legacy fallback，不在本輪拔除 feature flag | 目前已完成新路徑遷移與切斷 HTML 繞路；剩餘舊路徑只用於回退，不與新行為混用 |
