# Canonical Reading Position 統一設計

## 目標

將 yuedu 閱讀器內分散在多處的定位系統，統一為以 `CoreTextReadingPosition(spineIndex, charOffset)` 為唯一權威來源的架構。Paged mode 的 `pageIndex` 和 Scroll mode 的 `contentOffset/chunkIndex` 都降級為 derived state。

## 核心架構

### 三層結構

```
Canonical Layer（唯一真實位置）
  CoreTextReadingPosition(spineIndex, charOffset)
  ReadingPositionStore（持久化）
  ReadingPositionCoordinator（讀寫閘道）

Paged Mode（derived）
  pageIndex → canonical
  canonical → pageIndex
  不儲存 pageIndex 作為權威來源

Scroll Mode（derived）
  chunk/offset → canonical
  canonical → chunk/offset
  不儲存 contentOffset 作為權威來源
```

### 原則

- 只有 `coordinator.commit(position)` 會觸發持久化
- 模式切換永遠走 `coordinator.positionForModeSwitch()`
- Paged mode 不碰 scroll 的 contentOffset；scroll mode 不碰 paged 的 pageIndex
- `currentPage`、`currentChapterIndex`、`scrollVisibleChapter` 降級為純 UI display state

---

## 組件設計

### 1. ReadingPositionStore（持久層）

統一取代目前的三層儲存：`ReaderProgressManager`(UserDefaults)、`CharOffsetStore`(檔案)、`EPUBProgressStore`(檔案)。

```swift
protocol ReadingPositionStore {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func flush(for bookId: String) async
}
```

實作：檔案儲存於 `Documents/reading_position/<bookId>.json`。

**遷移策略：**
1. 首次載入時，依序嘗試 `CharOffsetStore.load` → `ReaderProgressManager.loadSnapshot` → fallback (chapter 0, charOffset 0)
2. 讀取成功後立即寫入新的 `ReadingPositionStore`，後續只讀新 store

**儲存時機：**
- Paged：翻頁停止後 0.3s debounce 後 commit
- Scroll：`didEndDecelerating` / `didEndDragging` 時 commit
- 退到背景 / 關閉閱讀器：`flush`

**要移除的：**
- `ReaderProgressManager` 的三個 save 方法（保留 `loadSnapshot` 作為遷移來源）
- `CharOffsetStore` 的 save 呼叫（保留 `load` 作為遷移來源）
- `EPUBProgressStore` 的 save 呼叫（保留 `load` 作為遷移來源）

---

### 2. ReadingPositionCoordinator（讀寫閘道）

```swift
@MainActor
final class ReadingPositionCoordinator: ObservableObject {
    private let store: any ReadingPositionStore
    private let bookId: String
    private var debounceTask: Task<Void, Never>?

    @Published private(set) var committed: CoreTextReadingPosition
    @Published private(set) var isRestoring = true

    init(store: any ReadingPositionStore, bookId: String, fallback: CoreTextReadingPosition) {
        self.store = store
        self.bookId = bookId
        self.committed = fallback
    }

    func restore() async {
        if let saved = await store.load(for: bookId) {
            committed = saved
        }
        isRestoring = false
    }

    func commit(_ position: CoreTextReadingPosition) {
        committed = position
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s debounce
            guard let self else { return }
            await self.store.save(position, for: self.bookId)
        }
    }

    func flush() async {
        debounceTask?.cancel()
        await store.save(committed, for: self.bookId)
        await store.flush(for: self.bookId)
    }

    func positionForModeSwitch() -> CoreTextReadingPosition {
        committed
    }
}
```

- `commit` + 0.3s debounce：避免翻頁/滾動過程中頻繁寫磁碟
- `flush`：場景切換時立即寫入
- `committed` 是 `@Published`：可 observe 但不可直接 mutate
- `ReaderView` 持有 `@StateObject private var positionCoordinator`

---

### 3. Paged Mode 整合

```
翻頁 → pageIndex → coordinator.commit(canonical)
恢復 → coordinator.committed → pageIndex → setPage
```

**commit 時機：** `onPageChanged` callback（頁面翻轉停止時），不是每次 `scrollViewDidScroll`。

**`ReaderView.onPageChanged` 改為：**

```swift
onPageChanged: { globalPage in
    let position = pagedEngine.readingPosition(forPage: globalPage)
        ?? CoreTextReadingPosition(spineIndex: currentChapterIndex, charOffset: 0)
    positionCoordinator.commit(position)

    // display-only: 更新書架進度條
    let pct = pagedEngine.totalProgress(for: position)
    store.updatePosition(bookId: bookId, position: pct)
}
```

**恢復時機：** paged engine start 完成後，從 coordinator 讀 canonical position，轉成 pageIndex：

```swift
await positionCoordinator.restore()
let position = positionCoordinator.positionForModeSwitch()
let page = pagedEngine.pageIndex(for: position) ?? 0
currentPage = page
```

**要移除的：**
- `epubRenderer.updateCurrentPosition` / `syncProgress` / `flushProgress` 呼叫
- paged engine 內部 `currentPage` 作為持久化來源的角色
- `savedPositionSnapshot`、`isRestoringPosition` 等 `ReaderRuntimeState` 中與 paged restore 相關的旗標

---

### 4. Scroll Mode 整合

```
停止滾動 → 解析視窗中心的 charOffset → coordinator.commit(canonical)
恢復 → coordinator.committed → chunkIndex + scrollTo
```

**commit 時機：** `scrollViewDidEndDecelerating` / `didEndDragging` 時 commit，**不在** `scrollViewDidScroll` 中寫入持久層或同步 paged engine。

**charOffset 解析（解決目前只用 chunk-start 的問題）：**

```swift
private func visibleCanonicalPosition() -> CoreTextReadingPosition? {
    let visibleCenter = CGPoint(
        x: collectionView.bounds.midX + collectionView.contentOffset.x,
        y: collectionView.bounds.midY + collectionView.contentOffset.y
    )
    guard let (_, chunk, localPoint) = hitTestChunk(at: visibleCenter) else {
        return fallbackChunkStartPosition()
    }
    let char = chunk.stringIndex(atLocalPoint: localPoint) ?? chunk.charRange.location
    return CoreTextReadingPosition(spineIndex: chunk.chapterIndex, charOffset: char)
}
```

**`ReaderView.onProgressCommit` 改為：**

```swift
onProgressCommit: { position in
    positionCoordinator.commit(position)
    let pct = pagedEngine.totalProgress(for: position)
    store.updatePosition(bookId: bookId, position: pct)
}
```

**`CoreTextCollectionScrollViewController.commitProgress` 改為解析 canonical position：**

```swift
private func commitProgress() {
    guard let pos = visibleCanonicalPosition() else { return }
    onProgressCommit?(pos)
}
```

**移除 paged engine 污染：** `onProgressCommit` 不再有 `currentPage = pagedEngine.pageIndex(...)` 的 live sync。

**`currentChapterIndex` 降級：** 從 `positionCoordinator.committed.spineIndex` 衍生，不再獨立儲存。

**`scrollVisibleChapter` 移除。**

**link tap / bookmark jump 簡化：** 設 `coordinator.commit(position)` + bump `scrollResliceToken`，移除 `savedCoreTextRestoreTarget`。

---

### 5. 模式切換

```swift
func switchToScrollMode() {
    let position = positionCoordinator.positionForModeSwitch()
    settings.scrollMode = true
    scrollResliceToken &+= 1
    // computeScrollInitialPosition 從 coordinator.committed 取值
}

func switchToPagedMode() {
    let position = positionCoordinator.positionForModeSwitch()
    settings.scrollMode = false
    let page = pagedEngine.pageIndex(for: position) ?? 0
    currentPage = page
}
```

`computeScrollInitialPosition` 改為讀取 `positionCoordinator.committed`：

```swift
private func computeScrollInitialPosition() -> (chapter: Int, charOffset: Int) {
    let pos = positionCoordinator.positionForModeSwitch()
    return (pos.spineIndex, pos.charOffset)
}
```

---

### 6. legacy 相容

- `Bookmark.position` 已經是 `CoreTextReadingPosition`，無需遷移
- `BookStore.updatePosition(percentage)` 保留（書架顯示用），但不再是位置恢復來源
- `ReaderProgressManager.loadSnapshot` 保留作為一次性遷移來源
- `CharOffsetStore.load` 保留作為一次性遷移來源

---

## 要刪除/降級的狀態

| 狀態 | 目前角色 | 新角色 |
|------|---------|--------|
| `currentPage` | paged 權威位置 | UI display only |
| `currentChapterIndex` | scroll 權威章節 | derived from coordinator |
| `scrollVisibleChapter` | scroll 章節追蹤 | 移除 |
| `savedCoreTextRestoreTarget` | jump 暫存 | coordinator.committed 取代 |
| `savedPositionSnapshot` | paged restore 快取 | 移除 |
| `isRestoringPosition` | restore 旗標 | coordinator.isRestoring |
| `ReaderProgressManager.saveScroll/savePaged/saveCoreText` | 持久化 | 由 ReadingPositionStore 取代 |
| `epubRenderer.updateCurrentPosition/syncProgress/flushProgress` | EPUB 持久化編排 | 移除 |
| `CharOffsetStore.save` | paged 持久化 | 保留 load 作為遷移，移除 save |
| `EPUBProgressStore.save` | EPUB 持久化 | 保留 load 作為遷移，移除 save |

---

## 實作順序

1. 建立 `ReadingPositionStore` protocol + `JSONFileReadingPositionStore` 實作
2. 建立 `ReadingPositionCoordinator`
3. 在 `AppDependencies` 中註冊，注入 `ReaderView`
4. 修改 paged mode commit flow（`onPageChanged` → coordinator）
5. 修改 paged mode restore flow（coordinator → pageIndex）
6. 修改 scroll mode commit flow（`didEndDecelerating` → visibleCanonicalPosition → coordinator）
7. 修改 scroll mode restore flow（coordinator → chunkIndex + scrollTo）
8. 簡化 `computeScrollInitialPosition`
9. 清理 `ReaderProgressManager` / `CharOffsetStore` / `EPUBProgressStore` 的 save 路徑
10. 清理 `ReaderRuntimeState` 中已廢棄的狀態
11. 移除 scroll mode 對 paged engine 的 live sync（`onProgressCommit` 中的 `currentPage = ...`）
