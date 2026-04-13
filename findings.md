# Findings（技術發現記錄）

## 現有 ASTNode 結構（Phase 1 的起點）

`HTMLAttributedStringBuilder.ASTNode` 位於：
`Models/CoreText/HTMLAttributedStringBuilder.swift:130`

```swift
indirect enum ASTNode {
    case text(TextNode)          // TextNode { text: String }
    case lineBreak(BreakNode)    // BreakNode { resolvedStyle: ResolvedStyle }
    case element(ElementNode)    // ElementNode { tag, id, classes, attributes, resolvedStyle, children: [ASTNode] }
}
```

**重要**：`BreakNode` 和 `ElementNode` 都帶著 `ResolvedStyle`（CSS 計算結果），
這是 HTML/EPUB 特有的資訊。在 `RenderableNode` 設計中，
我們把 CSS 解析結果對映到輕量的 `RenderStyle`（Sendable struct），
讓 IR 可以跨 actor 傳遞。

## AttributedStringBuilding 消費介面

```swift
protocol AttributedStringBuilding {
    var chapterCount: Int { get }
    func chapterTitle(at index: Int) -> String
    func chapterDataSize(at index: Int) async -> Int
    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult
}
```

`AttributedChapterBuildResult` 包含：
- `attributedString: NSAttributedString`
- `imagePage: HTMLAttributedStringBuilder.ImagePage?`
- `pageBackgroundImage: UIImage?`
- `anchorOffsets: [String: Int]`

**Phase 3 的 NodeAttributedStringRenderer 需要產出相同的 AttributedChapterBuildResult。**

## 現有管道的資料流

### TXT 路徑（目前）
```
TXTChapterParser.parseUnifiedChapters(text)
  → [UnifiedChapter] (id/title/plainText)
  → TXTAttributedStringBuilder.buildChapter(at:)
      → 直接把 plainText 按段落轉成 NSAttributedString（不過 HTML）
  → CoreTextPaginator.paginate(attributedString:)
  → [PageFrame]
```

**注意**：TXT 路徑**其實已經不過 HTML 了**！
`TXTAttributedStringBuilder` 直接建立 NSAttributedString，
唯一的問題是它繞過了統一 IR（每種 Builder 各自發明自己的段落建構邏輯）。

### EPUB 路徑（目前）
```
EPUBBookParser.parse(url:)
  → ParsedBookDocument
  → PublicationSession.chapterHTML(at:)  → HTML string
  → HTMLAttributedStringBuilder.build(html:config:)
      → HTMLBuilderDOMParser: HTML → SwiftSoup DOM
      → HTMLBuilderStyleResolver: DOM → [ASTNode]（帶 ResolvedStyle）
      → HTMLBuilderCoreTextRenderer: [ASTNode] → NSAttributedString
  → CoreTextPaginator.paginate()
```

### Web/Online 路徑（目前）
```
ChapterFetcher
  → WebNovelParser.extractContent() → 純文字 or 帶 HTML 標籤的字串
  → buildRenderableNormalizedHTML()
      → SwiftSoup.parse() [Task.detached]
      → 序列化回 HTML string（<!DOCTYPE html>…）
  → HTMLAttributedStringBuilder.build(html:config:)  ← 又解析一次！
  → CoreTextPaginator
```

**雙重解析問題**：Web 路徑先 parse DOM，再序列化成 HTML string，
再讓 HTMLAttributedStringBuilder 重新 parse 一次。Phase 6 可以消滅這個浪費。

## CoreTextPaginator 的消費點

`CoreTextPaginator` 不直接接觸 Parser，它只接受 `NSAttributedString`：
```swift
func paginate(
    attributedString: NSAttributedString,
    pageSize: CGSize,
    chapterIndex: Int,
    ...
) -> ChapterLayout
```

**這意味著 Phase 3 的 NodeAttributedStringRenderer 只要產出 NSAttributedString，
就不需要改動 CoreTextPaginator 任何一行。**

## 重要風險點

1. **`anchorOffsets`**：EPUB 內部連結依賴 `[String: Int]`（anchor href → char offset 映射）。
   Phase 3 的 renderer 需要在渲染 `anchor` case 時同步收集這個表。
   
2. **`imagePage`**：EPUB 封面頁可能整頁都是圖片。
   `HTMLAttributedStringBuilder` 有特殊邏輯偵測「body 下第一個 img = 全頁圖片」。
   Phase 7 （EPUB → RenderableNode）需要在 Converter 裡保留這個偵測邏輯。

3. **`pageBackgroundImage`**：部分 EPUB 用 `body { background-image }` 設置背景圖。
   同上，需要在 Phase 7 的 Converter 裡保留。

4. **CJK 字元間距**：`CJKTypographyProcessor.apply(to:)` 在 NSAttributedString 層面做後處理。
   Phase 3 的 Renderer 輸出的 NSAttributedString 也需要套用這個 processor。

5. **字型降級（Font Fallback）**：
   `HTMLAttributedStringBuilder` 的 `resolvedFont` closure 做自定義字型解析。
   Phase 3 的 Renderer 需要接受同樣的注入點。

## Phase 6-9 續做發現

1. `HTMLAttributedStringBuilder+RenderableNode.swift` 在整個 workspace 沒有任何實際呼叫點，只剩 task_plan 文字提及；刪除後 build 仍通過，證明它是純死碼。

2. `ReaderView.loadOnlineCoreText` 在 RenderableNode 路徑下其實只需要 `BookDocumentFactory.makeOnlineDocument` 與 `OnlineNodeAttributedStringBuilder`；`BookContentProviderFactory.makeOnlineProvider` 只屬於 legacy `loadWithProvider` 分支，延後建立後 build 仍通過。

3. `RenderableNode.swift` 裡的 `RenderableChapter` 包裝型別沒有任何使用點，刪除後 build 仍通過。現行渲染介面實際上以 `AttributedStringBuilding.buildChapter` 為唯一章節邊界。

4. 目前真正仍保留的舊 HTML 路徑有兩塊：
    - Online legacy fallback：`EPUBPageRenderer.loadWithProvider(...)`
    - EPUB 內容建構：`EPUBAttributedStringBuilder` 內部仍委派 `HTMLAttributedStringBuilder`

5. Phase 7 已完成後，搜尋 `build(html:config:)` 僅剩兩個匹配：
    - `HTMLAttributedStringBuilder.build(html:config:)` 定義本身
    - `CoreTextPageEngine` 的 legacy `resourceProvider` 分支

6. EPUB 直接節點路徑的穩定 seam 是：
    - `HTMLAttributedStringBuilder.buildStyledAST(...)`
    - `HTMLAttributedStringBuilder.imagePage(from:)`
    - `HTMLAttributedStringBuilder.pageBackgroundImage(from:)`
    - `HTMLAttributedStringBuilder.anchorOffsets(in:)`

7. `HTMLStyledASTRenderableNodeConverter` 現在負責把 styled AST 中的 `id` 轉為 `.anchorTarget`，並把 `ResolvedStyle` 映射到擴充後的 `RenderStyle`；這讓 EPUB 保留 CSS resolved data，但不再透過 HTML builder 直接輸出 `NSAttributedString`。

8. `NodeAttributedStringRenderer` 已升級為 async renderer，且已補齊 EPUB 所需能力：
    - 透過 `RunDelegateProvider` 發出圖片 placeholder
    - 寫入 `anchorIDAttribute`
    - 寫入 block decoration / block image attrs
    - 支援自定字型 resolver 與 image loader 注入
    - 對輸出套用 `CJKTypographyProcessor`
