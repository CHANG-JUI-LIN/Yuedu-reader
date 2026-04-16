# 增量章節更新設計 (Incremental Chapter Update)

## 問題陳述

當線上書籍的某一章抓取完成後，`ReaderView.fetchChapterIfNeeded()` 呼叫 `rebuildPages()` → `loadOnlineCoreText()` → 建立**全新的** `CoreTextPageEngine`。這導致：

1. **O(N) byte scan 重跑**：每次建立新引擎都觸發 `scanChapterByteSizes()`，對所有 N 章呼叫 `loadChapterPackageSync()` 檢查大小
2. **已有 layout 丟棄**：已渲染章節的分頁結果被銷毀，需要重新計算
3. **閱讀位置恢復開銷**：每次都從磁碟讀取存檔並重新定位
4. **CPU/電量浪費**：一本 3000 章的書，每抓到一章就跑一次完整的引擎初始化流程

## 核心發現

`CoreTextPageEngine` 已經具備增量載入能力：
- `preloadChapter(at:)` 可以按需載入單章並更新 `layouts[]`
- `onChapterReady` callback 通知 UI 刷新
- `rebuildPageOffsets()` 可以只更新頁碼映射

**真正的問題不在引擎，在 `ReaderView` 每次都銷毀引擎重建。**

## 方案選擇

### 方案 A：引擎增量更新（推薦）
在 `CoreTextPageEngine` 新增 `notifyChapterDataChanged(at:)` 方法，讓 `ReaderView` 在章節抓取完成後呼叫它而非 `rebuildPages()`。

**優點**：O(1) 更新、保留現有 layout、不中斷閱讀  
**風險**：需要處理引擎狀態一致性

### 方案 B：byte scan 快取 + 差量更新
保持 `rebuildPages()` 流程不變，但讓 `scanChapterByteSizes()` 使用快取跳過已知章節。

**優點**：改動最小  
**風險**：仍然重建引擎，layout 仍被丟棄

### 方案 C：A + B 組合
先做 B（低風險快取），再做 A（增量更新）。

**選擇**：方案 A（直接解決根本問題，方案 B 的 scan 快取效果在 A 完成後變得多餘）

## 詳細設計

### 1. CoreTextPageEngine 新增方法

```swift
/// 通知引擎：指定章節的底層資料已更新（例如從網路抓取完成）。
/// 引擎會清除該章節的 layout 快取並重新載入，不影響其他章節。
func notifyChapterDataChanged(at spineIndex: Int) async {
    guard (0..<chapterCount).contains(spineIndex) else { return }
    
    // 1. 清除舊 layout（可能是空的佔位符）
    layouts[spineIndex] = nil
    preloadTasks[spineIndex] = nil
    
    // 2. 更新該章節的 byte size（O(1)，不重掃全書）
    if let builder = attributedBuilder {
        let size = await builder.chapterDataSize(at: spineIndex)
        if spineIndex < chapterByteSizes.count {
            chapterByteSizes[spineIndex] = size
        }
    }
    
    // 3. 重新載入該章節
    await preloadChapter(at: spineIndex)
    
    // 4. 只更新頁碼映射（不銷毀其他章節的 layout）
    rebuildPageOffsets()
}
```

### 2. ReaderView 修改 fetchChapterIfNeeded

**現有流程**（每次重建）：
```swift
// 章節抓取完成後
rebuildPages()  // ← 銷毀整個引擎
```

**新流程**（增量更新）：
```swift
// 章節抓取完成後
if let engine = epubRenderer.engine {
    Task { await engine.notifyChapterDataChanged(at: chapterIndex) }
} else {
    rebuildPages()  // 只有第一次需要完整建立
}
```

### 3. 首次已快取章節的處理

`fetchChapterIfNeeded` 開頭有一段：
```swift
if isChapterCached(...) {
    rebuildPages()  // ← 這裡也不該重建
    return
}
```

改為：
```swift
if isChapterCached(...) {
    if let engine = epubRenderer.engine {
        Task { await engine.preloadChapter(at: chapterIndex) }
    }
    prefetchAdjacentChapters(around: chapterIndex)
    return
}
```

### 4. buildConvertedBook 清理

`OnlineBookCoordinator` 中的 `buildConvertedBook()` / `buildPackage()` / `warmCurrentWindow()` / `fetchJumpTarget()`：
- 這些只被下載流程使用
- 加上文檔註解標明用途
- 不在此次修改範圍內刪除（保持下載功能正常）

## 影響範圍

| 檔案 | 改動 |
|------|------|
| `CoreTextPageEngine.swift` | 新增 `notifyChapterDataChanged(at:)` 方法 (~15 行) |
| `ReaderView.swift` | 修改 `fetchChapterIfNeeded` 的 3 處 `rebuildPages()` 呼叫 (~10 行) |
| `OnlineReadingPipeline.swift` | 加文檔註解（可選） |

**總改動量**：~25 行新增/修改

## 邊界情況

1. **引擎尚未建立**：fallback 到 `rebuildPages()`（首次進入閱讀器）
2. **使用者跳章**：引擎的 `navigateToChapter` 已有處理，觸發 `preloadChapter` 後會按需載入
3. **併發抓取**：多章同時完成時，各自呼叫 `notifyChapterDataChanged`，CoreTextPageEngine 作為 non-Sendable class 運行在 MainActor 上，天然序列化
4. **主題/字型變更**：仍走現有的 `invalidateLayout` / `applyThemeChange` 路徑，不受影響
5. **byte scan 第一次**：引擎建立時的初始 byte scan 保持不變（提供全書進度估算），後續章節更新走增量路徑

## 驗證標準

1. 翻頁抓取新章時不再觸發 `loadOnlineCoreText` 全量重建
2. 已渲染章節的 layout 不被丟棄
3. 全書進度條正確更新
4. 閱讀位置不因章節更新而跳動
5. Build 通過，無新增 warning
