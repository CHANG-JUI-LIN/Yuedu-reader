# 章節供給契約：線上書的內容如何抵達畫面

> 日期：2026-08-19　起因：使用者回報三個長期缺陷——「無限加載中」、「莫名其妙章節載入失敗」、「鎖屏聽書突然停止」

## 為什麼需要這份文件

這三個症狀被當成三個 bug 修了很多輪，每輪都在上一輪的補丁上再補一層。它們其實是**兩個架構缺陷的六種投影**：

1. 章節到貨被當成「最新者勝」的 refresh transaction，於是相鄰章節的到貨會互相取消。
2. 「請求被取消」與「章節讀不到」在型別上無法區分，於是取消被畫成失敗、被朗讀當成終止。

修法不是攔截症狀，是把這兩件事在型別與所有權上分開。

---

## 三條不變量

### 1　安裝版面與宣告版面是同一個動作

`layouts` 的每一個消費者——分頁資料源、TTS 取文、進度——都只透過 `onChapterReady` 得知某章變成可渲染。**默默落地的版面，對所有人都不存在。**

唯一入口是 `CoreTextPageEngine.installLayout(_:for:)`。它做四件事，不可拆開：寫入 `_layouts`、產生快照、重建頁偏移、發 `onChapterReady`。

改動前有三個出口會安裝版面，其中**兩個沒有宣告**：

| 出口 | 舊行為 |
|---|---|
| 部分排版（首頁先出） | 有發 |
| 分頁器快取命中 | **裝了就 `return`** |
| 完整排版 | **裝了就結束** |

後兩者由 `schedulePreloadChapter` 這類射後不理的呼叫觸發時，沒有人在 await，通知就永久遺失——畫面上的佔位頁因此停在那裡。這正是舊 `startVisibleVCLog` 自愈輪詢偵測到的狀態（版面在、畫面是佔位頁）。那個輪詢已在一次 rebase 中從 `main` 消失，不要加回來。

### 2　章節到貨是 per-chapter 的資料事件，不得走 refresh transaction

`EPUBPageRenderer.beginRefreshTransaction` 是最新者勝：它取消前一筆的 preparation task，並呼叫 `engine.cancelPendingWork()`（generation++，砍掉所有 preload task）。

因此**供給不得發生在 transaction 內部**。`notifyChapterDataChanged` 的第一件事是 `_layouts[i] = nil`；被砍在中間的受害者會落得沒有版面、沒有宣告、也沒有任何東西會再問一次。開一本線上書必然觸發：N、N-1、N+1 同時到貨，各送一筆 refresh 互砍。

現在的分工：

- `ReaderView.submitChapterContentRefresh` 先直接餵引擎 `notifyChapterDataChanged(at:)`——per-chapter、冪等、在所有 transaction 之外。
- 只有**畫面上那一章**才接著送一筆 refresh，而且那筆 refresh 只負責把可見頁換到新版面。
- `RefreshPreparation.preparePaged` 的 `.chapterContent` 分支**不再取得內容**，與 `prepareScroll` 同形。

捲動引擎早在更早就修成這樣，註釋還在（`strand it on its placeholder forever`）；當時只改了捲動那一半。

### 3　「被取消」不是「失敗」，也不是「沒問過」

`ChapterLoadState.cancelled` 存在，是因為取消原本會塌進另外兩個狀態，兩邊都錯：

- 塌進 `.failed` → 畫面出現「章節載入失敗」，但內容其實抓得到（所以「刷新一下就好了」），而且 `handleTTSChapterWaitStateChange` 會直接**終止聽書**。
- 塌進 `.idle` → `overlayState` 畫成載入中，而沒有任何東西會再抓一次 → 第二種「無限加載中」，且不留痕跡。

判準集中在兩個 `isCancellation(_:)`（`ReaderViewModel`、`ChapterFetchManager`）：`CancellationError` 與 `URLError.cancelled`（-999，URLSession 或 WKWebView navigation 被拆掉時的形狀）。

配套：

- **共用在飛請求的呼叫者不得繼承別人的取消。** `ChapterFetchManager.fetchChapter` 共用分支若收到取消，會自己重開一筆，而不是把別人的錯誤丟給自己的呼叫者。
- **`.jump` 不再搶佔同書其他抓取。** 那段「以釋放 WKWebView slot」的程式碼是這條管線裡取消的主要製造者。`WebViewFetcher.acquireWebView` 本來就有等待佇列，額度是 `webViewPoolSize × webViewPoolOverflowMultiplier`；章節抓取數量很少（可見章加鄰章），排隊才是正確的表達方式。**不要把搶佔加回來。**
- `.cancelled` 由 `reissueCancelledChapterFetch` 重新請求，且只針對有人在等的章節（可見章、朗讀阻塞章）。沒人到得了的預抓被取消就該留在被取消狀態。

---

## TTS 分段音訊

與上面無關的獨立缺陷，但同樣是「型別上分不出好壞」造成的。

`AVAudioFile(forReading:)` 對非音訊位元組會丟 `kAudioFileError_InvalidFile`（四字元碼 `'dta?'`，OSStatus **1685348671**）。連續三段失敗會結束朗讀，使用者看到的是「朗讀失敗：第 N 段語音無法下載」。

根因：`responseLooksLikeTextPayload` 原本只在來源帶 `loginCheckJs` 時才檢查。大多數語音源沒有它，於是 HTTP 200 的限流頁／配額 JSON 直接被當成音訊快取起來，幾分鐘後才在播放時炸。

現在 `TTSAudioPayload` 是唯一判準，抓取端與播放端共用：

- `looksLikeAudioContainer(_:)`——magic bytes 認得出容器才收。認不出就是 provider 失敗，走既有的重試 → 跳段 → 三次才停。
- `diagnosticHead(of:)`——解碼失敗時把前 32 bytes 的 hex 與可列印字元寫進 log。錯誤頁、配額 JSON、截斷的 body 在解碼錯誤裡長得一模一樣；這是真機上唯一能分辨的證據。**不要包 `#if DEBUG`。**

---

## 護欄

- `Tests/iOS/yuedu appTests/ReaderChapterSupplyTests.swift` — 完整排版必須宣告；接手被作廢的排版必須重排而非回報假成功；內容真的沒有時不得重試成迴圈。
- `Tests/iOS/yuedu appTests/ReaderViewModelChapterStateTests.swift` — 取消不得變成 `.failed`；`.cancelled` 再次請求時回到 `.loading`。
- `Tests/iOS/yuedu appTests/ReaderChapterPresentationTests.swift` — `.cancelled` 畫載入中，不畫失敗。
- `Tests/iOS/yuedu appTests/TTSAudioPayloadTests.swift` — 錯誤頁／JSON／截斷 body 一律拒收。

## 日誌判準（Release Console 可見）

- `[FlipTrace] preload retry superseded spine=…` — 不變量 1／2 的救援真的發生了。
- `[FlipTrace] pageVC placeholder unresolved spine=…` — 佔位頁這一輪沒被換掉。抓取還沒回來時是正常的；反覆出現就是卡住了。
- `⟐ chapter fetch cancelled, re-requesting ch=…` — 不變量 3 在運作。
- `⟐ chapterFetch shared task cancelled, restarting` — 有人差點繼承別人的取消。
- `[TTS][Provider] rejected non-audio payload` / `rejected unrecognised audio container` — 語音源回了非音訊。
- `[TTS][HTTPEngine] player init failed … payload=bytes=… hex=… ascii=…` — 有東西繞過了上面的檢查；這行說得出是什麼。

## 已知的未竟項

- `WebViewFetcher` 的等待佇列是 FIFO，`.jump` 不會插隊。移除搶佔後這只是延遲問題，不是正確性問題（最多 6 個並行租約，章節抓取遠少於此）。要做優先序插隊必須把 priority 一路穿過 `acquireWebView` 的所有呼叫點，這輪沒做。
- `ReaderView.isChapterContentAvailable`（探快取）與 `ReaderViewModel.isChapterContentAvailable`（查 `availableChapterIndexes`）仍是同一問題的兩份實作，會在極短的時間窗內給出不同答案。這輪沒有統一。
- 「鎖屏聽書為什麼特別容易中斷」尚未定案。上面的 payload 檢查修掉了確定的缺陷，`diagnosticHead` 是用來定案的證據；還會發生就看那行 log。
