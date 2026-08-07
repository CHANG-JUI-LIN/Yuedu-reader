# 閱讀器架構重構：路線對照與決策依據

> 日期：2026-08-07　作者：CHANG-JUI-LIN（與研究報告對照）
> 定位：**決策對照文檔**——不替任何路線定案，只陳列事實、失敗證據、路線差異與需要真機驗證的 A/B 案例。

## 1. 為什麼需要這份文檔

過去兩週有兩條互斥的架構路線被提出，其中一條已實機失敗並被整個回退：

| 路線 | 來源 | 狀態 |
|---|---|---|
| A：三槽視窗＋畫面純函數（Legado 化） | 2026-08-05 當晚執行，reflog 留 19 個 commit | ❌ 實機出現「載入中卡死」與「跳頁/翻頁不準」，整輪 reset 回 `df6c392` |
| B：transaction 邊界（ReaderTransaction/PageSlot/immutable snapshot） | 兩份 deep-research 報告（report 1、report 2） | 📝 只有文件，未動程式 |

使用者回報（實機）：**載入中卡死、跳頁/翻頁不準**。本文件把路線 A 的實際做法與可能的失敗根因攤開，與路線 B 對照，並列出決定方向所需的真機驗證案例。

## 2. 路線 A（8/5 那輪）實際做了什麼

reflog 依序（`git reflog`，時間為當晚）：

| Commit | 內容 | 對應執行計劃 Task |
|---|---|---|
| `81873f3` | config：webview pool wait 15s、chapter load watchdog 60s | Task 1 |
| `46c9cae` | WebViewFetcher 池排隊：取消、超時、waiter 清理 | Task 2 |
| `e8406c9` | docs(image)：withTimeoutOrNil 的取消保證 | Task 3 |
| `29892fe` | ChapterSupply watchdog：.loading 逾時變 .failed | Task 4 |
| `9163333` | ChapterSupply 成為 readiness 單一擁有者；LayoutCache 保護 eviction | Step A 前奏 |
| `2ffc18f` | LayoutCache 改 window-based retention（取代 distance-LRU） | Task 7 前奏 |
| `df27808` | ReaderSession 三槽型別＋測試 | Task 6 |
| `8a0aec0` | **layout 併入章節 attempt**：fetch 完成後同一 attempt 內排版，`.ready` 必帶版面 | Step A |
| `acdfd57` | **跳過 refresh transactions**：chapter-ready 直接驅動換頁 | Task 10 前奏 |
| `6aac6fc` | LayoutCache 固定 windowRadius=1（三槽，prev/cur/next） | Task 7 |
| `c728efa` | page-number shift 不跳 view；read path 信任 cache | 顯示層修補 |
| `bd3a5f1` | 不重裝同一 (spine, charOffset) 頁 | 顯示層修補 |
| `1d3c1db`/`13135a2` | 診斷：placeholder monitor、2s snapshot | 診斷 |
| `2adc529` | placeholder 自己等自己的 layout（0.5s 輪詢，上限 30s） | 顯示層 |
| `eb12c7d` | **⟐ VC SELF-HEAL**：每 2 秒檢查可見 VC，layout 存在即換頁 | 顯示層 |
| `e708acb`/`c3e8356` | perf：並行 preload 圖片、SVG timeout 7s→3s | perf |
| `6c1c80d` | **no placeholder VC**：同一 VC 從「載入中」自己重繪成正文 | Step D 極致 |

路線 A 的架構本質（寫在當時的 `ReaderArchitectureMigration.md`）：

- 「抓到了」與「排好了」合成一個值 `ChapterRender`——`.ready` 不可能缺 layout。
- 三個槽取代 LayoutCache——**淘汰策略整個消失**，「該丟哪個」的問題不存在。
- 畫面是 `ReaderSession.display` 的純函數——`cur == nil` 就是載入中，沒有獨立 loading flag。
- Step D：刪 `onChapterReady` 廣播（16 處）、`refreshTransactions`＋revision＋visible commit（57 處）。

## 3. 路線 A 實機失敗的根因推論（基於 diff 證據）

> 標注：以下每一條都是**從 diff 推得的候選根因**，不是已證實的結論。證實手段見 §6。

### 3.1 「載入中卡死」的候選鏈

**證據 A：6c1c80d 把 2adc529 的 30 秒自等輪詢刪掉了。**

2adc529 的 placeholder 等待迴圈：

```swift
var waitedSeconds = 0
while _layouts[spineIndex] == nil, !Task.isCancelled, waitedSeconds < 30 {
    try? await Task.sleep(for: .seconds(0.5))
    waitedSeconds += 1
}
```

6c1c80d 刪成：

```swift
await self.preloadChapter(at: spineIndex)
guard _layouts[spineIndex] != nil else { return }
self.onChapterReady?(spineIndex)
```

`preloadChapter` 返回後 layout 仍為 nil（內容尚未就緒、builder 讀到空內容、或 preload 被 8a0aec0 的 prepareLayout 拋錯打斷），`onChapterReady` 就不會發——而 `refreshFromProvider`（no placeholder VC 的唯一重繪路徑）**唯一**呼叫者是 `handleChapterReady` 的 refreshInPlace 分支。鏈斷了，VC 就永遠停在載入中。

**證據 B：SELF-HEAL 的換頁條件不查 intent/revision。**

`eb12c7d` 的 SELF-HEAL：

```swift
if isPH,
   let position = self.currentCoreTextPosition,
   self.currentEngine.layouts[position.spineIndex] != nil {
    self.handleChapterReady(on: pageViewController)
}
```

只檢查「layout 存在」，不檢查該 layout 屬於目前 session/intent/content revision。若使用者的最新意圖已跳走而 `currentCoreTextPosition` 滯後，SELF-HEAL 會把畫面換到舊位置（跳頁來源之一），或把載入中的新章蓋回舊章（卡死感知來源之一）。

**證據 C：SELF-HEAL 任務生命周期無歸屬。**

`startVisibleVCLog` 在 `bindEngineCallbacks` 啟動，但 `clearEngineCallbacks` 沒有取消 `visibleVCLogTask`——engine 換代後舊的 2 秒任務仍可能繼續跑（weak self 只是不保活，不代表停止）。每 2 秒無條件掃描可見 VC，正好是報告 2 點名的「永久 polling watchdog」模式。

### 3.2 「跳頁/翻頁不準」的候選鏈

**證據 D：三槽 window 的跨章重排。**

`6aac6fc` 把 windowRadius 固定為 1：翻到第 N+1 章時，第 N-1 章的 layout 立即丟棄。往回翻時必須重新 paginate——重排後 global page 數可能與使用者記憶的不同（字體/視窗已變），而 `c728efa`/`bd3a5f1` 兩筆 commit 正是在實機測試當晚補「page-number shift 不跳 view」「不重裝同一位置」——說明測試中已出現此類現象，屬補丁式修法，未收斂。

**證據 E：換頁被兩套機制並存驅動。**

8/5 最後狀態同時存在：`onChapterReady` 換頁（acdfd57 直接呼叫）＋ SELF-HEAL 每 2 秒掃描換頁 ＋ refreshInPlace 原地重繪（6c1c80d）。三條路都可以寫 UIPageViewController，沒有共同 token 判斷「這次換頁對應使用者哪次意圖」——這就是兩份報告一致的診斷：**多個局部正確、沒有共同交易邊界的控制器**。

### 3.3 哪些是「沒問題的」部分

- Phase 1 供應層（`81873f3`–`29892fe`：WebView 池超時/取消、ChapterSupply watchdog）**與顯示層改動無關，且有獨立測試**（ChapterSupplyTests）。它沒有被實機報告點名，合理推測它不是失敗來源——但它被連帶 reset 掉了。
- `8a0aec0` 的「`.ready` 必帶 layout」概念本身與兩份報告的 `ContentRevision`/`LayoutCommit` 方向一致。

## 4. 路線 B（兩份研究報告）摘要

報告 1 與報告 2 的核心主張一致，可合併為：

1. **建立唯一交易邊界**：`ReaderTransaction`/`NavigationIntentID` 貫穿 fetch → document → layout → cache → visible commit；只有 renderer 成功 commit 且 ack，交易才完成。
2. **`(spineIndex, charOffset)` 是唯一位置身份**；`globalPage` 降級為 display projection，不得反向決定章節或持久化。
3. **placeholder 從 UIViewController 身分改為 `PageSlot` 狀態**（loading/ready/failed），建頁不得觸發資料工作。
4. **`CoreTextPageEngine` 拆層**：LayoutEngine（不可變 snapshot）/ PageIndex / PageCache（revision key）/ Prefetch / Renderer。
5. **兩秒 SELF-HEAL 降級**為一次性、綁定 transaction 的 watchdog，不永久輪詢。
6. 遷移順序：先做「線上＋paged」垂直切片，再擴 TXT/EPUB/scroll。

報告 2 的一個**過時誤判**已在 8/6 驗證：它稱「refresh transaction API 尚未落地到主實作」，但 `EPUBPageRenderer.refresh(request:)`＋`beginRefreshTransaction`＋`finishVisibleRefresh`＋三個 revision 已實作（EPUBPageRenderer.swift:602-744），且有 `ReaderRenderRefreshTests` 覆蓋。報告基於過舊快照。

## 5. 路線對照

### 5.1 共同點（兩邊都同意，先做這些無爭議）

| 主張 | 路線 A | 路線 B |
|---|---|---|
| `(spineIndex, charOffset)` 是穩定位置 | ✅（bd3a5f1） | ✅ |
| `.ready` 必須同時帶內容與版面 | ✅（8a0aec0） | ✅（LayoutCommit） |
| 畫面不自行推導、不二次驗證 | ✅（遷移計劃不變量 5） | ✅ |
| 取消只作用於自己請求的章 | ✅ | ✅ |
| 卡死必須是可測試的紅燈 | ✅（不變量 6） | ✅（fuzz + oracle） |

### 5.2 分歧點

| 面向 | 路線 A（三槽純函數） | 路線 B（transaction 邊界） |
|---|---|---|
| refresh transactions | **刪除**（Step D，57 處） | **強化/取代**為統一交易管線 |
| 章節保留 | 三槽，視窗外**即時丟棄** | 不可變 snapshot，revision-keyed LRU cache |
| 換頁驅動 | onChapterReady / refreshInPlace / SELF-HEAL 三路並存（8/5 實況） | 唯一 coordinator 驗證 revision 後要求 renderer commit |
| placeholder | 同 VC 自繪（loading→正文）或佔位 VC | `PageSlot` 純狀態，工作由 coordinator 啟動 |
| 失敗處理 | watchdog 強制 `.failed(載入逾時)` | reducer 顯式 `.failed(transaction, error)`＋retry token |
| 遷移成本 | 高（動 `_layouts` 50 個引用、刪顯示層補橋） | 高（新 ReaderStore/Coordinator/Repository 系統） |
| 實機風險 | 已驗證：卡死＋跳頁 | 未驗證；報告自承「renderer ack 需 adapter 補丁」 |

### 5.3 關鍵張力

- 路線 A 的失敗證據（§3.2）指向**三槽即時丟棄**與**多寫入者並存**，而不是「刪 refresh transactions」本身。刪 transaction 系統是它的手段，不是它失敗的根因。
- 路線 B 的核心（transaction + revision gate + 唯一寫入者）恰好能補路線 A 失敗鏈的缺口：SELF-HEAL 的無 revision 檢查（證據 B）、三路換頁無共同 token（證據 E）。
- 路線 B 的成本與風險（全新抽象層、UIKit ack adapter）在單人專案裡是實質負擔；且它報告 2 對現況有一處誤判（§4），會讓「按報告照做」的人誤刪/重做已存在的機制。

## 6. 決定路線所需的真機 A/B 案例

以下案例應在**同一本書、同一來源、同一裝置**上，分別在 df6c392（現狀）與候選實作上各跑一遍，記錄：

- 是否出現載入中卡死（>5 秒）
- 翻一頁後可見章節/字元是否與意圖一致
- 快速連點 10 次後的落點

| # | 案例 | 診斷目標 |
|---|---|---|
| 1 | 跳遠章（第 5 → 第 120），立即連點下一頁 | 3.2 三槽重排 vs 現狀 totalPages 估算 |
| 2 | 慢網（飛航模式開關）下連續跨章 10 章 | 3.1 卡死鏈（onChapterReady 是否到達） |
| 3 | 快速連點 10 次下一頁，停住後等 5 秒 | SELF-HEAL 是否存在、是否跳頁（證據 B） |
| 4 | 旋轉＋換字體後翻頁 | global page 重投影是否跳章 |
| 5 | 熄屏聽書跨 5 章（TTS 走 preload 直路，不過 refresh 系統） | 供應層 watchdog 是否生效（8/5 Phase 1 的驗證點） |

## 7. 建議（供決策，不定案）

1. **先救回 8/5 的 Phase 1 供應層**（`81873f3`–`29892fe` 四筆 commit，含獨立測試）——它獨立、低風險、治「無限加載」的一條已知根因（WebView 池無界等待），且是兩條路線都需要的底層。
2. **路線 A 的失敗根因按 §3 逐條驗證**（案例 2/3 直接對應證據 A/B），而不是把整輪標記為「方向錯」。
3. **若驗證證實 §3，則採「A 的骨架 + B 的閘門」融合**：保留三槽語意（或 windowRadius 2-3），但換頁只允許一個寫入者；SELF-HEAL 必須帶 intent/revision 檢查（報告 1 的 `PlaceholderTicket` 條件）；不刪 refresh transactions（它們已是 revision/latest-wins 的落地，報告 2 誤判未落地）。
4. **下一輪任何路線的第一次 commit 都必須是可獨立 revert 的**，並保留上一輪的「症狀對照表」逐項打勾。

## 8. 開放問題（需要使用者補充）

- [ ] 8/5 實機測試時，卡死/跳頁是發生在 **no placeholder VC（6c1c80d）之前還是之後**？——決定證據 A 是否為主要根因。
- [ ] 是否還記得當時的復現步驟（哪本書、哪個來源、哪個模式）？——決定案例 1-5 的書庫準備。
- [ ] 8/5 那輪的真機測試是在幾台裝置、什麼網路條件下做的？——決定「慢網」案例是否是真兇。
- [ ] App Store 目前上線版本是否包含 8/5 的 refresh transaction 系統？（決定「刪 refresh」是否真的被使用者碰到過）
