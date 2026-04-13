# Progress（會話進度日誌）

## Session 1 — 2026-04-13

### 已完成
- [x] Phase 0：探索所有 Parser 入口、渲染消費介面、資料流
- [x] 建立 task_plan.md（9 個階段的完整計畫）
- [x] 建立 findings.md（技術發現，含風險點清單）

### 關鍵發現摘要
- `HTMLAttributedStringBuilder.ASTNode` 已存在，Phase 1 是升格而非從零設計
- TXT 路徑其實已不過 HTML，Phase 4 工作量較預估小
- Web 路徑有**雙重解析**浪費（SwiftSoup parse → HTML string → 再 parse），Phase 6 可消滅
- `CoreTextPaginator` 只吃 `NSAttributedString`，Phase 3 完成後不需動 Paginator

### 下一步（Session 2 開始）
1. Phase 1：建立 `Models/CoreText/RenderableNode.swift`
2. Phase 2：建立 `Models/CoreText/HTMLAttributedStringBuilder+RenderableNode.swift`
3. 建完兩個新檔案後，先 build 確認無錯誤再繼續

### 測試指令
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && xcodebuild -scheme "yuedu app" -destination 'platform=iOS Simulator,id=60E7FA08-53CE-4483-9DBF-229CBB236D66' build 2>&1 | grep -E "error:|BUILD"
```

## Session 2 — 2026-04-13

### 已完成
- [x] Phase 1：RenderableNode.swift
- [x] Phase 2：橋接 extension
- [x] Phase 3：NodeAttributedStringRenderer
- [x] Phase 4：TXT / Online Node builder
- [x] Phase 5：Feature flag 驗收
- [x] Phase 6：Online/Web 改走 AttributedStringBuilding + RenderableNode path
- [x] Phase 7：EPUB 改走 styled AST → RenderableNode → NodeAttributedStringRenderer
- [x] Phase 8：Markdown 保留原始 .md/.markdown 匯入，閱讀器走 MarkdownAttributedStringBuilder
- [x] Phase 9：新路徑已切斷 HTML 繞路；legacy fallback 保留於 feature flag

### 遇到的問題
- `xcodebuild build` 在 EPUB 直接節點路徑完成後再次通過。
- `xcodebuild test` 仍在 `yuedu appTests/CoreTextPipelineTests.swift:177` 與 `:215` 因 `CGFloat(String)` / `CGFloat(raw.dropLast(2))` 編譯失敗；屬既有測試問題，未在本輪處理。

### 本會話增量
- 新增 `EPUBAttributedStringBuilder`，讓 EPUB 也可進入 `CoreTextPageEngine(attributedBuilder:)` 路徑。
- 新增 `MarkdownAttributedStringBuilder` 與 `MarkdownSectionParser`，並修改匯入流程保留 markdown 原檔。
- 刪除未使用的 `HTMLAttributedStringBuilder+RenderableNode.swift`。
- 刪除未使用的 `RenderableChapter` 包裝型別。
- 清理 `ReaderView.loadOnlineCoreText`，只在 legacy branch 建立 `BookContentProvider`。

## Session 3 — 2026-04-13

### 已完成
- [x] `HTMLAttributedStringBuilder` 曝露 styled AST / imagePage / pageBackgroundImage / anchorOffsets helper
- [x] 新增 `HTMLStyledASTRenderableNodeConverter`
- [x] `RenderableNode` / `RenderStyle` 補齊 EPUB metadata
- [x] `NodeAttributedStringRenderer` 補齊 async 圖片 / anchor / block decoration / 字型注入能力
- [x] `EPUBAttributedStringBuilder` 改走 styled AST → RenderableNode → Node renderer

### 驗證結果
- `xcodebuild -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build` 成功
- `xcodebuild -project 'yuedu app.xcodeproj' -scheme 'yuedu app' -destination 'id=60E7FA08-53CE-4483-9DBF-229CBB236D66' CODE_SIGNING_ALLOWED=NO test` 失敗，但失敗點仍是既有測試檔 `CoreTextPipelineTests.swift` 的 `CGFloat(String)` 問題

### 補充
- 目前搜尋 `build(html:config:)`，除了定義本身外，只剩 `CoreTextPageEngine` 的 legacy provider 分支呼叫它；新 RenderableNode 路徑已不再直接依賴 HTML builder 輸出內容字串。
