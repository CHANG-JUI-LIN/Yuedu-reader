# Incremental Chapter Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the O(N) engine rebuild when a chapter finishes fetching by adding incremental update support to `CoreTextPageEngine`.

**Architecture:** When a chapter fetch completes, instead of destroying and recreating the entire `CoreTextPageEngine` (which triggers a full O(N) byte scan), we add a `notifyChapterDataChanged(at:)` method that clears only that chapter's layout, updates its byte size, and re-preloads it — O(1) per chapter. ReaderView is modified to use this method when the engine already exists, falling back to full `rebuildPages()` only on first load.

**Tech Stack:** Swift, CoreText, UIKit, async/await

---

### Task 1: Add `notifyChapterDataChanged(at:)` to PageLayoutEngine protocol

**Files:**
- Modify: `yuedu app/Models/Reader/CoreText/PageRenderingProvider.swift:54-68` (PageLayoutEngine protocol)

- [ ] **Step 1: Add protocol method with default no-op**

In `PageRenderingProvider.swift`, add `notifyChapterDataChanged(at:)` to the `PageLayoutEngine` protocol's engine lifecycle section, and provide a default empty implementation:

```swift
// In the PageLayoutEngine protocol, after line 59 (func cancelPendingWork()):
/// 通知引擎：指定章節的底層資料已更新（如網路抓取完成）。
/// 引擎清除該章節的 layout 並重新載入，不影響其他章節。
func notifyChapterDataChanged(at spineIndex: Int) async
```

```swift
// In the PageLayoutEngine default extension (after line 114: func cancelPendingWork() {}):
func notifyChapterDataChanged(at spineIndex: Int) async {}
```

- [ ] **Step 2: Verify build**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && xcodebuild -project "yuedu app.xcodeproj" -scheme "yuedu app" -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Users/zhangruilin/Desktop/yuedu app"
git add "yuedu app/Models/Reader/CoreText/PageRenderingProvider.swift"
git commit -m "feat: add notifyChapterDataChanged(at:) to PageLayoutEngine protocol

Adds an incremental chapter update method with a default no-op
implementation. CoreTextPageEngine will override this to avoid
full engine rebuilds on each chapter fetch.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Implement `notifyChapterDataChanged(at:)` in CoreTextPageEngine

**Files:**
- Modify: `yuedu app/Models/Reader/CoreText/CoreTextPageEngine.swift:612-624` (after existing `preloadChapter`)

- [ ] **Step 1: Add implementation**

In `CoreTextPageEngine.swift`, add the following method right after `preloadChapter(at:)` (after line 624):

```swift
func notifyChapterDataChanged(at spineIndex: Int) async {
    guard (0..<chapterCount).contains(spineIndex) else { return }

    // 1. 清除舊 layout 與進行中的 preload task
    layouts[spineIndex] = nil
    preloadTasks[spineIndex]?.cancel()
    preloadTasks[spineIndex] = nil
    chapterSnapshots.removeObject(forKey: NSNumber(value: spineIndex))

    // 2. 增量更新該章節的 byte size（O(1)，不重掃全書）
    if let builder = attributedBuilder {
        let size = await builder.chapterDataSize(at: spineIndex)
        if spineIndex < chapterByteSizes.count {
            chapterByteSizes[spineIndex] = size
        } else if chapterByteSizes.count == spineIndex {
            chapterByteSizes.append(size)
        }
    }

    // 3. 重新載入該章節（preloadChapter 會檢查 layouts[spineIndex] == nil 後執行）
    await preloadChapter(at: spineIndex)
}
```

Note: `rebuildPageOffsets()` is already called inside `preloadChapterInternal` (line 661), so we don't need to call it again here.

- [ ] **Step 2: Verify build**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && xcodebuild -project "yuedu app.xcodeproj" -scheme "yuedu app" -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Users/zhangruilin/Desktop/yuedu app"
git add "yuedu app/Models/Reader/CoreText/CoreTextPageEngine.swift"
git commit -m "feat: implement notifyChapterDataChanged(at:) in CoreTextPageEngine

Clears stale layout, cancels pending preload task, removes snapshot,
incrementally updates the chapter's byte size, and re-preloads the
chapter. O(1) instead of O(N) full engine rebuild.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Modify ReaderView.fetchChapterIfNeeded to use incremental update

**Files:**
- Modify: `yuedu app/Views/Reader/ReaderView.swift:1611-1662`

- [ ] **Step 1: Replace success-path `rebuildPages()` calls with incremental update**

Replace the entire `fetchChapterIfNeeded` method body. There are 3 `rebuildPages()` calls to replace:

**Call 1 (line 1627)** — cached chapter detected:
```swift
// BEFORE:
        if dependencies.bookSourceFetcher.isChapterCached(
            bookId: b.id, chapterIndex: chapterIndex,
            expectedSourceURL: nil, expectedTOCTitle: nil
        ) {
            rebuildPages()
            prefetchAdjacentChapters(around: chapterIndex)
            return
        }

// AFTER:
        if dependencies.bookSourceFetcher.isChapterCached(
            bookId: b.id, chapterIndex: chapterIndex,
            expectedSourceURL: nil, expectedTOCTitle: nil
        ) {
            if let engine = epubRenderer.engine {
                Task { await engine.preloadChapter(at: chapterIndex) }
            } else {
                rebuildPages()
            }
            prefetchAdjacentChapters(around: chapterIndex)
            return
        }
```

**Call 2 (line 1652)** — fetch success:
```swift
// BEFORE:
                await MainActor.run {
                    if pkg.state == .cached && !pkg.content.isEmpty {
                        failedChapters.remove(chapterIndex)
                    } else {
                        failedChapters.insert(chapterIndex)
                        lastChapterError = "ch\(chapterIndex): \(pkg.failureReason ?? "內容為空")"
                    }
                    rebuildPages()
                    prefetchAdjacentChapters(around: chapterIndex)
                }

// AFTER:
                await MainActor.run {
                    if pkg.state == .cached && !pkg.content.isEmpty {
                        failedChapters.remove(chapterIndex)
                    } else {
                        failedChapters.insert(chapterIndex)
                        lastChapterError = "ch\(chapterIndex): \(pkg.failureReason ?? \"內容為空\")"
                    }
                    if let engine = epubRenderer.engine {
                        Task { await engine.notifyChapterDataChanged(at: chapterIndex) }
                    } else {
                        rebuildPages()
                    }
                    prefetchAdjacentChapters(around: chapterIndex)
                }
```

**Call 3 (line 1659)** — fetch error:
```swift
// BEFORE:
                await MainActor.run {
                    failedChapters.insert(chapterIndex)
                    lastChapterError = "ch\(chapterIndex): \(error.localizedDescription)"
                    rebuildPages()
                }

// AFTER:
                await MainActor.run {
                    failedChapters.insert(chapterIndex)
                    lastChapterError = "ch\(chapterIndex): \(error.localizedDescription)"
                    // 錯誤時不需重建引擎 — failedChapters 的 UI 綁定已足夠
                    // 若引擎不存在（不應發生），fallback 到全量重建
                    if epubRenderer.engine == nil {
                        rebuildPages()
                    }
                }
```

- [ ] **Step 2: Verify build**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && xcodebuild -project "yuedu app.xcodeproj" -scheme "yuedu app" -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Users/zhangruilin/Desktop/yuedu app"
git add "yuedu app/Views/Reader/ReaderView.swift"
git commit -m "perf: use incremental chapter update instead of full engine rebuild

fetchChapterIfNeeded now calls engine.notifyChapterDataChanged(at:)
when a chapter fetch completes, instead of destroying and recreating
the entire CoreTextPageEngine via rebuildPages(). Falls back to full
rebuild only when the engine doesn't exist (first load).

Eliminates O(N) byte scan on every chapter fetch for online books.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Add documentation comments to OnlineBookCoordinator's download-only methods

**Files:**
- Modify: `yuedu app/Models/Online/OnlineReadingPipeline.swift:613-793`

- [ ] **Step 1: Add doc comments to buildConvertedBook and buildPackage**

Add clarifying documentation to these methods that are only used by the download flow:

Before `buildConvertedBook` (around line 613):
```swift
/// 將全書章節轉換為 XHTML 格式的 BookPackage。
/// ⚠️ 此方法為 O(N) 操作（遍歷所有章節），僅供**下載離線閱讀**使用。
/// 線上閱讀的渲染路徑使用 CoreTextPageEngine 的增量載入機制，不經過此方法。
```

Before `buildPackage` (around line 712):
```swift
/// 建構完整的 BookPackage 供離線閱讀。僅供下載流程呼叫。
/// 線上閱讀使用 OnlineNodeAttributedStringBuilder + CoreTextPageEngine，不經過此方法。
```

Before `warmCurrentWindow` (around line 741):
```swift
/// 預熱下載流程所需的章節視窗。僅供下載流程呼叫。
```

Before `fetchJumpTarget` (around line 764):
```swift
/// 跳轉到指定章節並建構 BookPackage。僅供下載/離線跳轉流程呼叫。
```

- [ ] **Step 2: Verify build**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && xcodebuild -project "yuedu app.xcodeproj" -scheme "yuedu app" -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Users/zhangruilin/Desktop/yuedu app"
git add "yuedu app/Models/Online/OnlineReadingPipeline.swift"
git commit -m "docs: clarify OnlineBookCoordinator download-only methods

Add doc comments to buildConvertedBook, buildPackage, warmCurrentWindow,
and fetchJumpTarget explaining they are O(N) download-only paths.
Online reading uses CoreTextPageEngine's incremental loading.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Final verification

- [ ] **Step 1: Full clean build**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && xcodebuild -project "yuedu app.xcodeproj" -scheme "yuedu app" -destination "platform=iOS Simulator,name=iPhone 17 Pro" clean build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify no regressions in grep for rebuildPages usage**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && grep -n "rebuildPages" "yuedu app/Views/Reader/ReaderView.swift"
```

Expected: `rebuildPages()` should still exist in:
- `performUnifiedRelayout` (line ~2045) — settings/layout changes, correct
- `loadContent` guard fallback — engine creation, correct
- `fetchChapterIfNeeded` error fallback (only when engine is nil) — correct

It should NOT appear as a bare call in the success path of `fetchChapterIfNeeded`.

- [ ] **Step 3: Review diff**

Run:
```bash
cd "/Users/zhangruilin/Desktop/yuedu app" && git --no-pager log --oneline -5
```

Verify 4 new commits on top of the design spec commit.
