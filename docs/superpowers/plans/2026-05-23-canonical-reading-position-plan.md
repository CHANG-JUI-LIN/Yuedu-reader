# Canonical Reading Position 統一實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 將閱讀位置系統統一為以 `CoreTextReadingPosition(spineIndex, charOffset)` 為唯一權威來源，paged pageIndex 和 scroll chunkIndex 降級為 derived state，移除模式間位置污染。

**Architecture:** 新建 `ReadingPositionStore` (protocol + JSON file 實作) 統一持久層，`ReadingPositionCoordinator` (@MainActor ObservableObject) 作為讀寫閘道提供 debounced commit / flush / restore。Paged mode 從 `onPageChanged` commit，Scroll mode 從 `visibleCanonicalPosition()` commit。兩邊只碰 coordinator，不互相寫入對方內部狀態。

**Tech Stack:** Swift, SwiftUI, CoreText, UIKit (UICollectionView/PageViewController)

---

### Task 1: 建立 ReadingPositionStore

**Files:**
- Create: `iOS/Models/Reader/ReadingPositionStore.swift`

- [ ] **Step 1: 建立 protocol + JSON 檔案實作**

```swift
import Foundation

protocol ReadingPositionStore: AnyObject, Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func flush(for bookId: String) async
}

final class JSONFileReadingPositionStore: ReadingPositionStore {
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseURL = docs.appendingPathComponent("reading_position", isDirectory: true)
        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func fileURL(for bookId: String) -> URL {
        baseURL.appendingPathComponent("\(bookId).json")
    }

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        let data = try? encoder.encode(position)
        let url = fileURL(for: bookId)
        let tmp = url.appendingPathExtension("tmp")
        try? data?.write(to: tmp, options: .atomic)
        try? fileManager.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        let url = fileURL(for: bookId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CoreTextReadingPosition.self, from: data)
    }

    func flush(for bookId: String) async {
        // JSONFileReadingPositionStore writes atomically; no-op flush.
    }
}
```

- [ ] **Step 2: 確認 CoreTextReadingPosition 遵循 Codable**

Read `iOS/Models/Reader/CoreText/CoreTextReadingPosition.swift` to check if `CoreTextReadingPosition` already conforms to `Codable`. If not, add conformance.

- [ ] **Step 3: Commit**

```bash
git add iOS/Models/Reader/ReadingPositionStore.swift
git commit -m "feat: add ReadingPositionStore protocol + JSONFileReadingPositionStore"
```

---

### Task 2: 建立 ReadingPositionCoordinator

**Files:**
- Create: `iOS/Models/Reader/ReadingPositionCoordinator.swift`

- [ ] **Step 1: 建立 Coordinator**

```swift
import Foundation
import Combine

@MainActor
final class ReadingPositionCoordinator: ObservableObject {
    private let store: any ReadingPositionStore
    private let bookId: String
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: UInt64 = 300_000_000 // 0.3s

    @Published private(set) var committed: CoreTextReadingPosition
    @Published private(set) var isRestoring = true

    init(
        store: any ReadingPositionStore,
        bookId: String,
        fallback: CoreTextReadingPosition
    ) {
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
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceInterval)
            guard !Task.isCancelled else { return }
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

- [ ] **Step 2: Commit**

```bash
git add iOS/Models/Reader/ReadingPositionCoordinator.swift
git commit -m "feat: add ReadingPositionCoordinator"
```

---

### Task 3: 在 AppDependencies 註冊 ReadingPositionStore

**Files:**
- Modify: `iOS/Models/App/AppDependencies.swift`

- [ ] **Step 1: 將 store 加進 AppDependencies 和 EnvironmentValues**

在 `AppDependencies` struct 中加入：

```swift
struct AppDependencies {
    var webContentFetcher: WebContentFetching
    var bookSourceFetcher: BookSourceFetching
    var chapterFetcher: ChapterFetching
    var onlineBookCoordinator: OnlineBookCoordinating
    var readingPositionStore: ReadingPositionStore  // NEW
    // ...
}
```

在 `static let live` 中加入：

```swift
static let live: AppDependencies = {
    // ... existing ...
    return AppDependencies(
        webContentFetcher: LiveWebContentFetcher(webFetcher: webFetcher),
        bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: bsf),
        chapterFetcher: LiveChapterFetcher(chapterFetchManager: cfm),
        onlineBookCoordinator: OnlineBookCoordinator.shared,
        readingPositionStore: JSONFileReadingPositionStore()  // NEW
    )
}()
```

- [ ] **Step 2: Commit**

```bash
git add iOS/Models/App/AppDependencies.swift
git commit -m "feat: register ReadingPositionStore in AppDependencies"
```

---

### Task 4: ReaderView 導入 ReadingPositionCoordinator

**Files:**
- Modify: `iOS/Views/Reader/ReaderView.swift`

- [ ] **Step 1: 新增 coordinator 屬性並初始化**

在 `ReaderView` struct 新增：

```swift
@Environment(\.appDependencies) private var appDependencies
@StateObject private var positionCoordinator: ReadingPositionCoordinator = {
    // placeholder, will be replaced in init or .task
    ReadingPositionCoordinator(
        store: JSONFileReadingPositionStore(),
        bookId: "",
        fallback: CoreTextReadingPosition(spineIndex: 0, charOffset: 0)
    )
}()
```

But `@StateObject` can't depend on Environment. 改用 `.task` 初始化：

在 `ReaderView` body 最外層加上 `.task`:

```swift
.task {
    guard !positionCoordinatorReady else { return }
    let store = appDependencies.readingPositionStore
    let bookIdStr = book?.id.uuidString ?? ""
    let fallback = CoreTextReadingPosition(spineIndex: 0, charOffset: 0)
    positionCoordinator = ReadingPositionCoordinator(store: store, bookId: bookIdStr, fallback: fallback)
    await positionCoordinator.restore()
    positionCoordinatorReady = true
}
```

需要新增：
```swift
@State private var positionCoordinatorReady = false
```

並移除 `@StateObject private var positionCoordinator` 的佔位。改為在 ReaderView 內部用 `@State` 持有:

```swift
@State private var _positionCoordinator: ReadingPositionCoordinator?
private var positionCoordinator: ReadingPositionCoordinator? { _positionCoordinator }
```

但這樣到處都要 optional unwrap。更好的做法：讓 `ReaderView` 在建構時接收 coordinator，或使用 factory pattern。

**最終方案：** 在 `ReaderView` 的 `body` 中，先檢查 `positionCoordinator` 是否存在，不存在時顯示 loading。`.task` 中建立 coordinator。

由於 ReaderView 沒有便利的 init point（由 NavigationLink 自動建立），我們在 `body` 中用 group + if-let：

```swift
@State private var positionCoordinator: ReadingPositionCoordinator?

var body: some View {
    Group {
        if let coordinator = positionCoordinator {
            readerBody(coordinator: coordinator)
        } else {
            Color.clear  // brief loading placeholder
        }
    }
    .task {
        guard positionCoordinator == nil else { return }
        let store = appDependencies.readingPositionStore
        let bookIdStr = book?.id.uuidString ?? ""
        let fallback = CoreTextReadingPosition(spineIndex: 0, charOffset: 0)
        let c = ReadingPositionCoordinator(store: store, bookId: bookIdStr, fallback: fallback)
        await c.restore()
        positionCoordinator = c
    }
}

private func readerBody(coordinator: ReadingPositionCoordinator) -> some View {
    // ... move all existing body content here, replacing references to isRestoringPosition with coordinator.isRestoring
}
```

- [ ] **Step 2: Commit**

```bash
git add iOS/Views/Reader/ReaderView.swift
git commit -m "feat: integrate ReadingPositionCoordinator into ReaderView"
```

---

### Task 5: Paged mode 改用 coordinator commit

**Files:**
- Modify: `iOS/Views/Reader/ReaderView.swift`

- [ ] **Step 1: 修改 handleCoreTextPageChanged**

將 `ReaderView.handleCoreTextPageChanged` 中的：
```swift
epubRenderer.updateCurrentPosition(globalPage: newPage, engine: engine)
if let progressBookId = localEPUBBookIdentifier {
    epubRenderer.syncProgress(bookId: progressBookId)
}
```

改為：
```swift
let position = engine.readingPosition(forPage: newPage)
    ?? CoreTextReadingPosition(spineIndex: currentChapterIndex, charOffset: 0)
positionCoordinator?.commit(position)

let pct = engine.totalProgress(forSpine: position.spineIndex, charOffset: position.charOffset)
store.updatePosition(bookId: bookId, position: pct)
```

- [ ] **Step 2: 修改 applyInitialProgressIfNeeded**

將其中從 `epubRenderer.updateCurrentPosition` 的呼叫移除。保留 engine page 作為 initial display 設定（`currentPage = currentEnginePage`），但不再觸發 epubRenderer 的進度儲存。

改為：
```swift
if currentPage != currentEnginePage {
    currentPage = currentEnginePage
    currentChapterIndex = engine.charOffset(forPage: currentEnginePage).spineIndex
}
ensureChapterReady(chapterIndex: currentChapterIndex)
// 不再呼叫 epubRenderer.updateCurrentPosition
```

同時，`savedCoreTextRestoreTarget` 相關邏輯改為讀取 `positionCoordinator?.committed`。

- [ ] **Step 3: Commit**

```bash
git add iOS/Views/Reader/ReaderView.swift
git commit -m "refactor: paged mode commit through coordinator"
```

---

### Task 6: Scroll mode 解析 visibleCanonicalPosition

**Files:**
- Modify: `iOS/Views/Reader/CoreTextCollectionScrollViewController.swift`

- [ ] **Step 1: 新增 visibleCanonicalPosition 方法**

在 `CoreTextCollectionScrollViewController` 中新增：

```swift
private func visibleCanonicalPosition() -> CoreTextReadingPosition? {
    guard !engine.chunks.isEmpty else { return nil }

    let visibleCenter: CGPoint
    switch scrollAxis {
    case .vertical:
        visibleCenter = CGPoint(
            x: collectionView.bounds.midX + collectionView.contentOffset.x,
            y: collectionView.bounds.midY + collectionView.contentOffset.y
        )
    case .horizontalRTL:
        visibleCenter = CGPoint(
            x: collectionView.bounds.midX + collectionView.contentOffset.x,
            y: collectionView.bounds.midY + collectionView.contentOffset.y
        )
    }

    if let (_, chunk, localPoint) = hitTestChunk(at: visibleCenter) {
        let char = chunk.stringIndex(atLocalPoint: localPoint) ?? chunk.charRange.location
        return CoreTextReadingPosition(spineIndex: chunk.chapterIndex, charOffset: char)
    }

    // Fallback: use the chunk closest to the visible center
    guard let path = visibleProgressIndexPath(),
          path.item < engine.chunks.count else { return nil }
    let chunk = engine.chunks[path.item]
    return CoreTextReadingPosition(spineIndex: chunk.chapterIndex, charOffset: chunk.charRange.location)
}
```

- [ ] **Step 2: 修改 commitProgress 使用 canonical position**

將 `commitProgress` 從：
```swift
private func commitProgress() {
    guard let pos = pendingProgress else { return }
    onProgressCommit?(pos)
}
```

改為：
```swift
private func commitProgress() {
    guard let pos = visibleCanonicalPosition() else { return }
    onProgressCommit?(pos)
}
```

- [ ] **Step 3: 修改 onProgressCommit callback 型別**

將 `var onProgressCommit: ((ScrollProgress) -> Void)?` 改為：
```swift
var onProgressCommit: ((CoreTextReadingPosition) -> Void)?
```

同時更新 `CoreTextScrollHostView` 中的對應型別。

- [ ] **Step 4: Commit**

```bash
git add iOS/Views/Reader/CoreTextCollectionScrollViewController.swift iOS/Views/Reader/CoreTextScrollHostView.swift
git commit -m "feat: scroll mode commit canonical position from visible center"
```

---

### Task 7: ReaderView onProgressCommit 改用 coordinator

**Files:**
- Modify: `iOS/Views/Reader/ReaderView.swift`

- [ ] **Step 1: 改寫 onProgressCommit callback**

在 `ReaderView.scrollBody` 中，將 `onProgressCommit` 從：

```swift
onProgressCommit: { pos in
    scrollVisibleChapter = pos.chapter
    currentChapterIndex = pos.chapter
    savedCoreTextRestoreTarget = nil
    progressManager.saveScroll(
        bookId: bookId,
        chapterIndex: pos.chapter,
        charOffset: pos.charOffset,
        percentage: pos.percentage
    )
    store.updatePosition(bookId: bookId, position: pos.percentage)
    if let pagedEngine = epubRenderer.engine, epubRenderer.isCoreTextReady {
        let page = pagedEngine.pageIndex(forSpine: pos.chapter, charOffset: pos.charOffset)
        if page >= 0 { currentPage = page }
    }
}
```

改為：

```swift
onProgressCommit: { position in
    positionCoordinator?.commit(position)
    currentChapterIndex = position.spineIndex
    let pct = epubRenderer.engine?.totalProgress(forSpine: position.spineIndex, charOffset: position.charOffset) ?? 0
    store.updatePosition(bookId: bookId, position: pct)
}
```

**關鍵移除：**
- `scrollVisibleChapter = pos.chapter`（不再需要）
- `progressManager.saveScroll(...)`（由 coordinator 取代）
- `currentPage = pagedEngine.pageIndex(...)`（移除對 paged engine 的 live sync 污染）

- [ ] **Step 2: 簡化 computeScrollInitialPosition**

改成只從 coordinator 讀取：

```swift
private func computeScrollInitialPosition() -> (chapter: Int, charOffset: Int) {
    if let pos = positionCoordinator?.positionForModeSwitch() {
        return (pos.spineIndex, pos.charOffset)
    }
    return (max(0, currentChapterIndex), 0)
}
```

- [ ] **Step 3: 簡化 link tap / bookmark jump**

在 `onInternalLinkTap` 中，移除 `savedCoreTextRestoreTarget`，改為直接 commit：

```swift
onInternalLinkTap: { href in
    Task {
        guard let targetPage = await epubRenderer.resolveInternalLink(href, fromSpineIndex: currentChapterIndex),
              let pagedEngine = epubRenderer.engine else { return }
        let (spine, charOffset) = pagedEngine.charOffset(forPage: targetPage)
        await MainActor.run {
            let position = CoreTextReadingPosition(spineIndex: spine, charOffset: charOffset)
            positionCoordinator?.commit(position)
            currentChapterIndex = spine
            scrollResliceToken &+= 1
        }
    }
}
```

同樣在 `jumpToBookmark` 和 `jumpToChapter` 的 scroll 分支中，將 `savedCoreTextRestoreTarget = (idx, charOffset)` 改為 `positionCoordinator?.commit(CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset))`。

- [ ] **Step 4: Commit**

```bash
git add iOS/Views/Reader/ReaderView.swift
git commit -m "refactor: scroll mode position through coordinator, remove paged engine live sync"
```

---

### Task 8: 清理 ReaderRuntimeState

**Files:**
- Modify: `iOS/Views/Reader/ReaderRuntimeState.swift`

- [ ] **Step 1: 移除已廢棄的狀態**

移除：
- `isRestoringPosition` → 由 `positionCoordinator.isRestoring` 取代
- `savedPositionSnapshot` → 不再需要（coordinator 的 `committed` 才是真來源）
- `savedCoreTextRestoreTarget` → 由 `coordinator.committed` 取代
- `isApplyingCoreTextRestore` → 不再需要
- `hasAppliedNonZeroRestore` → 不再需要

保留：
- `systemBrightness`
- `isLoadingPipeline`
- `curlStartupStartedAt`
- `hasLoggedCurlInteractiveReady`
- `hasPerformedInitialLoad`

修改後 `ReaderRuntimeState` 為：

```swift
import Foundation

final class ReaderRuntimeState {
    var systemBrightness: Double = 0.5
    var isLoadingPipeline = false
    var curlStartupStartedAt: CFAbsoluteTime?
    var hasLoggedCurlInteractiveReady = false
    var hasPerformedInitialLoad = false
}
```

- [ ] **Step 2: 移除 ReaderView 中對應的 wrapper properties**

移除 ReaderView 中的：
```swift
private var isRestoringPosition: Bool { get set }
private var savedPositionSnapshot: Double { get set }
private var savedCoreTextRestoreTarget: (...) { get set }
private var isApplyingCoreTextRestore: Bool { get set }
private var hasAppliedNonZeroRestore: Bool { get set }
```

- [ ] **Step 3: Commit**

```bash
git add iOS/Views/Reader/ReaderRuntimeState.swift iOS/Views/Reader/ReaderView.swift
git commit -m "refactor: remove deprecated runtime state replaced by coordinator"
```

---

### Task 9: 清理 ReaderProgressManager

**Files:**
- Modify: `iOS/Models/Reader/ReaderProgressManager.swift`

- [ ] **Step 1: 將 save 方法標記為 deprecated，保留 load 作為遷移來源**

將 `saveCoreText`、`savePaged`、`saveScroll` 的 body 清空（或加上 `@available(*, deprecated)` 註解），保留 `loadSnapshot`。

修改 `loadSnapshot` 加入 migration logic：

```swift
func loadSnapshot(bookId: UUID) -> BookProgressSnapshot? {
    let key = snapshotKey(bookId: bookId)
    guard let data = defaults.data(forKey: key) else { return nil }
    // existing decode logic...
}
```

保留三個 save 方法的簽名但清空 body（編譯相容），讓現有的呼叫處不會立即報錯。

- [ ] **Step 2: Commit**

```bash
git add iOS/Models/Reader/ReaderProgressManager.swift
git commit -m "refactor: deprecate ReaderProgressManager save methods, keep load for migration"
```

---

### Task 10: 清理 EPUBPageRenderer 的 progress 方法

**Files:**
- Modify: `iOS/Models/Reader/EPUBPageRenderer.swift`

- [ ] **Step 1: 清空 updateCurrentPosition / syncProgress / flushProgress 的 body**

```swift
func updateCurrentPosition(globalPage: Int, engine eng: any PageRenderingProvider) {
    // Deprecated: use ReadingPositionCoordinator.commit() instead
}

func syncProgress(bookId: String) {
    // Deprecated: use ReadingPositionCoordinator.commit() instead
}

func flushProgress(bookId: String) {
    // Deprecated: use ReadingPositionCoordinator.flush() instead
}
```

保留方法簽名以維持編譯相容，但內容清空。

- [ ] **Step 2: Commit**

```bash
git add iOS/Models/Reader/EPUBPageRenderer.swift
git commit -m "refactor: deprecate EPUBPageRenderer progress methods"
```

---

### Task 11: 清理 ReaderView 的 autoSaveProgress / saveProgress

**Files:**
- Modify: `iOS/Views/Reader/ReaderView.swift`

- [ ] **Step 1: 簡化 saveProgress（onDisappear / background 時呼叫）**

將 `saveProgress` 中的：
```swift
epubRenderer.flushProgress(bookId: bookId)
```

改為：
```swift
if let coordinator = positionCoordinator {
    await coordinator.flush()
}
```

`saveProgress` 本身是同步方法，需要改成 async，或使用 `Task { await coordinator.flush() }`。

修改 `saveProgress` body：

```swift
private func saveProgress() {
    guard let coordinator = positionCoordinator else { return }
    Task {
        await coordinator.flush()
    }
}
```

並從 `autoSaveProgress` 中移除對 `ReaderProgressManager.saveScroll/savePaged/saveCoreText` 和 `epubRenderer.updateCurrentPosition/syncProgress` 的呼叫。`autoSaveProgress` 保留 `store.updatePosition` 和 chapter preloading 邏輯。

- [ ] **Step 2: 簡化 autoSaveProgress**

由於大部分持久化邏輯已在 `onPageChanged` 和 `onProgressCommit` 中處理，`autoSaveProgress` 可以大幅簡化為只做：
1. chapter preloading (`ensureChapterAhead/Behind`)
2. `store.updatePosition`（書架進度條）

移除 scroll 分支中的 `progressManager.saveScroll(...)` 呼叫。
移除 paged 分支中的 `epubRenderer.updateCurrentPosition/syncProgress` 和 `progressManager.saveCoreText/savePaged` 呼叫。

- [ ] **Step 3: Commit**

```bash
git add iOS/Views/Reader/ReaderView.swift
git commit -m "refactor: simplify autoSaveProgress/saveProgress after coordinator migration"
```

---

### Task 12: 最終驗證 - 編譯

**Files:** all modified

- [ ] **Step 1: 完整編譯**

```bash
cd "/Users/zhangruilin/Desktop/Yuedu-reader"
xcodebuild -project "Yuedu-Reader.xcodeproj" \
  -scheme "Yuedu-Reader" \
  -destination 'generic/platform=iOS Simulator' \
  build
```

確認 BUILD SUCCEEDED。

- [ ] **Step 2: 修復任何編譯錯誤**

如果 `localEPUBBookIdentifier` 仍被其他程式碼引用，確認它仍可存取但不再寫入位置。

如果 `savedCoreTextRestoreTarget` 仍有殘留引用（在 `refreshInitialRestoreState` 等處），移除這些參照或改用 coordinator。

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: final compilation fixes for canonical position migration"
```
