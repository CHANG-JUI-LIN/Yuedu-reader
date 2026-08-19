# 分頁閱讀器契約：頁面身分與頁堆疊所有權

> 日期：2026-08-18　起因：使用者回報「滑動翻頁時，章末往前撥會連跳到下一章第二頁」

## 為什麼需要這份文件

翻頁不穩定從自製引擎開始就反覆出現，而且每次的表徵都不一樣：連跳一頁、翻不過去、載入中卡死、換渲染路徑就壞。它們不是四個 bug，是同一個架構缺陷的四種投影。

缺陷是：**我們把一個會在背後重新編號的索引，交給 `UIPageViewController` 保管。**

`CLAUDE.md` 早就寫著「Reading position: `(spineIndex, charOffset)`, never a global page index」，但這條規則只在三個下游呼叫點各補了一次修正——`ReaderPageTurnCommand.targetPosition`、`ReaderPageTransitionQueue` 的重新錨定、`syncStablePosition`。**資料源本身從來沒有遵守過。**

---

## 三條不變量

### 1　資料源只走 position，絕不走絕對頁碼

`viewControllerBefore` / `viewControllerAfter` 交給 UIKit 的每一頁，身分都是 `(spineIndex, charOffset)`。

實作在 `CoreTextReadingPositionMapper.positionAfter/positionBefore`（[CoreTextReadingPosition.swift](../Modules/Core/ReaderCore/CoreText/CoreTextReadingPosition.swift)），由 `PagePositionWalking` 能力協定暴露。它只讀 `layouts[spine].pageRanges` 與 `chapterCount`：

- 章內：走到下／上一個 `pageRanges[...].location`。
- 章界：`.chapterStart(spine+1)` / `.chapterEnd(spine-1)`——只需要 `chapterCount`，**對面那章不需要有 layout**。
- 部分排版（`isPartial`）：走到第一個尚未量測的字元位移。那是一個真實錨點，全量排版落地後會解析到正確的下一頁，中間沒有任何索引會過期。
- 書首書尾、或當前頁根本沒有 layout：回 `nil`。UIKit 讀 `nil` 為「那個方向沒有頁」，這是對一個沒人量過的鄰居唯一誠實的答案。

**絕對頁碼降級成只供顯示**：頁尾「12/300」、進度條。任何把 `globalPageIndex` 存起來跨越一次排版的地方都是 bug。

> 例外（有意保留）：跨頁對開（固定版面配對）與 curl 背面的 front/back 虛擬索引仍走索引。固定版面永不重新編號，curl 的正反面配對本質上就是索引配對。

### 2　UIKit 回呼進行中，不得同步改寫頁堆疊

`setViewControllers` 不可以在 UIKit 擁有頁堆疊時執行：

- `.scroll`（滑動）底下是 `_UIQueuingScrollView`。在 `didFinishAnimating` 裡同步寫入，會在它還沒把剛結束的捲動收乾淨時重新播種，**可見頁因此比使用者要求的多走一頁**。
- `.pageCurl`（仿真）會用同樣的方式弄壞它的正面／背面／底頁簿記。

唯一擁有者是 `ReaderStackWriteGate`（[ReaderStackWriteGate.swift](../Modules/Core/ReaderCore/ReaderStackWriteGate.swift)）。所有想改頁堆疊的路徑都先 `request(_:)`，被拒就由 `drainStackWrites` 在**下一個 runloop** 重播，而且一次只重播一筆。

改動前的狀態值得記住，因為它就是這次 bug 的形狀——保護與危險是完美反向配對：

| | 保護機制 | 危險動作 |
|---|---|---|
| 條件 | `guard pageTurnStyle == .curl` ×3 | `if pageTurnStyle != .curl` ×3 |
| curl | 全部拿到 | 全部避開 |
| slide | **一個都沒有** | **全部踩到** |

現在 gate 對所有翻頁樣式一視同仁。

### 3　資料源查詢是投機提問，不是使用者的承諾

UIKit 會在它自己選的時機、為使用者可能永遠不會翻到的頁呼叫資料源。`.scroll` 的預取比 `.pageCurl` 積極得多——這就是為什麼「只換渲染路徑」也會冒出翻頁問題。

因此 `neighbourViewController(for:)` **不寫任何 coordinator 狀態**。導航意圖記在真正落地的地方：`didFinishAnimating`。這條不變量現在是結構性的——那個函式已經沒有能力寫入 `pendingNavigation`。

---

## 已知的未竟項

- **`readingPosition(forPage:)` 在頁面超出已排版範圍時回 `.chapterStart(spine)`**，而對稱的 `pageIndex(for:)` 回 `nil`。落在章中佔位頁時會把「章首」寫進持久化位置。沒有在這輪改掉：14 個呼叫點裡有數個寫成 `?? .chapterStart(0)`，直接改回 `nil`會讓它們錨到**第 0 章**，比現況更糟。要修得先給那些呼叫點更好的退路。資料源這條路徑已用 `committedReadingPosition(of:)` 擋住，不受影響。
- **引擎的頁面供給仍由資料源查詢觸發**：`pageViewController(at:)` / `(for:)` 在被查詢時會啟動 `Task { preloadChapter; onChapterReady }`。架構上這違反不變量 3。沒有移除，因為 2026-08-05 那輪重構（`ReaderArchitectureDecision-2026-08-07.md` 路線 A）正是在「載入觸發點搬家後鏈條斷掉」上實機失敗、整輪回退的。不變量 2 的 gate 已經把它的實際危害——回呼內的堆疊寫入——擋掉了。要動它必須先把每一個 commit 點列全。
- **`BrowserLayoutPageEngine` / `FixedLayoutPageEngine` 用索引推導的預設 `positionAfter/Before`**。固定版面永不重新編號，所以那裡是精確的；browser engine 目前是關閉的（`.legacy`），重新啟用前要給它真實實作。

## 護欄

- `Tests/iOS/yuedu appTests/ReaderPositionWalkTests.swift` — 章內／章界／書界／未排版／部分排版的步進行為，以及「重新排版前面的章節不得移動步進目的地」。
- `Tests/iOS/yuedu appTests/ReaderStackWriteGateTests.swift` — 所有權窗口、巢狀轉場、一次只重播一筆、優先序不受回呼順序影響。
- `Tests/iOS/yuedu appTests/ReaderPageTransitionQueueTests.swift` — 排隊翻頁的重新錨定。

## 日誌判準（Release Console 可見）

- `[FlipTrace] pageForward from=<position> to=<position>` — 步進兩端都是 position。出現絕對頁碼就是回歸。
- `[FlipTrace] stackWrite deferred <kind>` / `stackWrite replay <kind>` — gate 有在擋。
- `⟐ stackWrite watchdog` — 有 completion 掉了，該查。
