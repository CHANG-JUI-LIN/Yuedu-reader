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
- **`BrowserLayoutPageEngine` / `FixedLayoutPageEngine` 用索引推導的預設 `positionAfter/Before`**。固定版面永不重新編號，所以那裡是精確的。browser engine 自 2026-09-07 起是 `.browserAuto`（開著的），而它**會**重新編號——章節先發佈第一頁、其餘頁在背景補完。目前安全的理由是時序而非設計：`pageIndex(for:) → page ± 1 → readingPosition(forPage:)` 三步在同一個 MainActor 呼叫內完成，中間插不進重新編號。仍應給它一個直接走 `pageSourceRanges` 的真實實作，別再依賴這個時序巧合。

## 護欄

- `Tests/iOS/yuedu appTests/ReaderPositionWalkTests.swift` — 章內／章界／書界／未排版／部分排版的步進行為，以及「重新排版前面的章節不得移動步進目的地」。
- `Tests/iOS/yuedu appTests/ReaderStackWriteGateTests.swift` — 所有權窗口、巢狀轉場、一次只重播一筆、優先序不受回呼順序影響。
- `Tests/iOS/yuedu appTests/ReaderPageTransitionQueueTests.swift` — 排隊翻頁的重新錨定。

## 儀器覆蓋率審計（2026-09-08）

起因：使用者問「分頁模式是不是通用的日誌系統」。答案當時是**不是**，而且不是靠評估得出的，
是靠數的。方法很簡單，之後每加一個軸都該重跑一次：

> **列出真正改變狀態的機制，數有幾個經過儀器。**

| 軸 | 機制數 | 經過儀器 | 結論 |
|---|---|---|---|
| 分頁位置 | `currentCoreTextPosition` **4 個寫入者** | 1 | ❌ → **已修**（`private(set)` + `setCurrentPosition`）|
| 捲動位置 | `readingPosition` **4 個寫入者** | 1 | ❌ → **已修**（`setReadingPosition(_:_:)`）|
| 章節供給 | `_layouts` 安裝只走 `installLayout` | 全部 | ✅ 本來就是咽喉點 |
| 排版世代 | `cancelPendingWorkInternal` 是 private、單一呼叫者 | 全部 | ✅ 本來就是咽喉點 |
| TTS 跟隨 | `setActiveTTSAnchor` 3 個呼叫點 | **0** | ❌ → **已修**（`JumpIntent.ttsAnchor` 有 case 但零呼叫點）|
| 渲染內容 | 內容綁到視圖只走 `CoreTextPageView.configure` | 全部 | ⚠️ **可辨識、尚不可偵測**（見下）|
| 點擊 | `shouldHandleTap` 1 | 全部 | ✅ **已修**（每個分支具名）|

**最貴的教訓：儀器要裝在機制上，不要裝在路徑上。** 位置守衛原本掛在 `syncStablePosition`
這條*路徑*上，於是「覆蓋」翻頁動畫整個樣式從來沒被看到過——它走的是
`captureStablePosition` → `publishCurrentPage`。路徑可以被新增而沒人記得補；變數不行。
現在兩個模式的位置變數都是 `private(set)`／私有儲存 + 具名寫入方法，**直接賦值編不過**。

### 渲染這軸還缺什麼

`CoreTextPageView.configure` 是內容綁到視圖的**唯一**機制點，現在每次綁定都記下身分與**實際
字元範圍**（`[RenderTrace] pageView.configure`）。跟同一份日誌的 `⟐ layoutGeneration` 交叉比對，
「畫的是舊排版的內容」**辨識得出來**。

但**偵測不出來**：視圖持有的是 `ChapterLayout` 的**複本**，重新排版後它照舊畫，沒有任何東西
會發現。要變成結構性守衛，得給 `ChapterLayout` 一個世代戳並在繪製時比對——那是動一個廣泛
建構的 struct，這輪刻意沒做。**在那之前不要說渲染這軸有守衛。**

### 點擊

`shouldHandleTap` 的四個出口全部具名（`[TapTrace]`，trace 級、靠飛行記錄器帶出）。回 `false`
會讓觸控整個落到翻頁／選單，所以錯誤的 `false` 不長得像點擊 bug，長得像「我點筆記結果翻頁了」
（見 `project_page_view_tap_gate`）。失敗分支特別分開 `noLayout` / `pageOutOfRange` /
`noInteractionContext` / `noCharacterAtPoint` / `notALink`——它們去同一個地方，但對閱讀器狀態
的含意完全不同。

## 位置守衛（`ReaderPositionSentry`）

**A1 是通用的那一條，其餘都是它的特例。** 一筆位置提交是「有來源的」，當且僅當：
宣告過的意圖解釋了它（`declareIntent`，由 `moveReaderSession` 對 `ReaderLocation.Source`
的**窮舉**映射餵入）、翻頁的 expectation 預測了它、或**讀者自己的手指**造成了它
（`readerDriven:`）。否則就記一筆 `guard=A1`，**不看距離**。

`readerDriven` 是原本缺的那個輸入。兩個模式一直都知道答案——分頁看
`stackWriteGate.isAnimatingTransition`，捲動看是哪個 delegate 回呼——只是從來沒告訴 sentry，
於是守衛只能退回去用距離猜。

| 守衛 | 覆蓋 | 現況 |
|---|---|---|
| **A1** 位置變動沒有來源 | 兩個模式，任何距離 | `notice`。**刻意不設門檻。** |
| G1 落點與步進目的地不符 | 分頁手勢 | anomaly |
| G2 章節位置無故跳動 | 兩個模式，**≥2 章** | anomaly |
| G3 翻頁動畫跑完但沒前進 | 分頁，**連續 2 次** | anomaly |
| S1 內容在讀者底下移動 | 捲動，結構變動後，**>120 字元** | anomaly |
| S2 章節順序錯亂 | 捲動 | anomaly |

⚠️ **G2 的 `≥2`、G3 的連續 2 次、S1 的 120 字元都是猜的。** 它們是照著當時回報的症狀選來
避免誤報的，代價是「跳剛好一章／一頁／半段」對三者都是隱形的。A1 存在就是為了把這個洞
量出來：它記下每一筆無主變動與距離，**下一份真機日誌會給出真實分布，然後這些門檻應該被
刪掉，而不是再猜一次。** 在那之前不要用它們的存在來論證什麼是「正常」。

## 日誌判準（Release Console 可見）

- `⟐ positionSentry 位置變動沒有來源` — A1。無主的位置變動，帶 `charDelta`／`spineDelta`。
- `[FlipTrace] pageForward from=<position> to=<position>` — 步進兩端都是 position。出現絕對頁碼就是回歸。
- `⟐ stackWrite deferred <kind>` / `[FlipTrace] stackWrite replay <kind>` — gate 有在擋。
- `⟐ stackWrite dropped <kind> inFavourOf=<kind>` — 欠著的堆疊寫入被更高優先級蓋掉。
- `⟐ stackWrite watchdog` — 有 completion 掉了，該查。
- `⟲ scrollpos.phase.resign` / `.phase.active` — 捲動模式進出前台，附當下位置。
- `⟲ scrollpos.*` — 捲動的還原全程（`restore.resolve` / `restore.deferred` / `insert`）。
- `[ProgressTrace][ScrollVC] commit … moved=<Δ>` — 每次捲動落定的**位移量**，不只落點。
