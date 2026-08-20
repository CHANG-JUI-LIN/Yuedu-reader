# 離線下載契約：什麼是真相、誰有權刪東西

> 日期：2026-08-19　起因：使用者回報「移除下載後全書章節載入失敗，只有換源才好」與「切後台幾分鐘回來，下載全部消失」

## 為什麼需要這份文件

兩個症狀看起來無關，其實共用同一個源頭：**這個 App 把「目錄」與「已下載」都存成了可以跟現實分歧的獨立狀態**，而 legado 沒有。對照過的三個版本（上游、`Luoyacheng/legado-E`、`HapeLee/legado-with-MD3`）在這三件事上完全一致：

- 下載佇列**只存在記憶體**（`ConcurrentHashMap`），不持久化。
- 「這章下載了沒」**一律看磁碟**：`BookHelp.hasContent()` → `book_cache/{book}/{chapter}` 檔案在不在。
- **移除下載只刪內容資料夾**（`BookHelp.clearCache`）；章節 URL 與書源綁定在資料庫，動都不動。
- 失敗只記在記憶體 `errorDownloadMap`，每章 3 次，**不寫磁碟**。

---

## 四條不變量

### 1　目錄為空是「抓取失敗」，不是「這本書沒有章節」

`BookSourceFetcher.fetchTOCPackage` 在規則抓不到東西時**回傳空包而不是拋錯**——Cloudflare 頁、登入牆、恢復時 WebView 停在挑戰頁、站方改版。提交那個空包會連鎖：

`onlineChapters = []` → `reconcileBook(oldRefs: 全部, newRefs: [])` **刪光該書所有快取章節** → `offlineDownloadTask = nil`、狀態 `.none` → `saveMetaImmediately()` 立刻落盤。

換源那條路早就有守衛，自動刷新那條沒有。而自動刷新**每次回前景都跑**（節流 `AppConfig.autoRefreshMinInterval = 300` 秒），所以「切出去幾分鐘再回來」正好是它的觸發窗口。

唯一入口是 [`OnlineTOCCommitPolicy`](../Modules/Services/LibraryStore/OnlineTOCCommitPolicy.swift)。**任何寫 `onlineChapters` 的地方都必須先問它。**

### 2　刷新問的是章節「清單」，不是要丟掉章節「位元組」

`reconcileBook` 現在收 `OfflineContentDisposition`：

| 動作 | disposition | 理由 |
|---|---|---|
| 換源 | `.deleteMismatched` | 使用者確認過的重新綁定，舊源的位元組確實無用 |
| 移除下載 | 整個目錄刪除 | 使用者明確要求 |
| 目錄刷新（自動或手動） | `.preserveContent` | 沒人要求刪東西 |

`.preserveContent` 下仍然會 `cachedFilename = nil` 並把該索引標記為待重抓（`reconcileOfflineTaskMetadata`），所以那些章節照樣會重抓；差別只是**檔案不再被背著使用者刪掉**。代價是磁碟上可能留下孤兒檔，交給快取管理清。

同一條線上的兩個坑：

- `onFirstPageReady` 只帶**目錄第一頁**。用它整份取代 `onlineChapters` 會把 3000 章截成 50 章，而任何併發的 `saveMetaImmediately()`（每完成一章下載就有一次）會把截斷版寫進磁碟。→ 漸進提交一律 `preservingExistingTail: true`。
- `reconcileInterruptedDownloads` 對空目錄會把每個索引都當成「已消失」而清空任務，`derivedState` 於是回 `.none`。→ **空目錄直接跳過整本書。** 對帳只驗證，不摧毀。

### 3　磁碟是「已下載」的唯一真相

`ChapterFetchManager.states` 曾經在移除下載後仍宣稱 `.cached`（移除只刪檔案，沒人通知這張表），而 `prefetchChapters` 會跳過任何非 `.missing`/`.failed` 的章節——結果整本書的預抓死掉，直到重開 App。

`chapterState(bookId:chapterIndex:)` 先探磁碟；探不到時，**存著的 `.cached` 視為 `.missing`**。這就是 `BookHelp.hasContent` 的規則。

### 4　失敗只留在記憶體

`handleFetchFailure` 以前會 `saveFailureMarker`，而那個函式**第一件事是 `createDirectory(withIntermediateDirectories:)`**——所以移除下載之後任何一個遲到的失敗都會把剛刪掉的目錄重建回來並填進假封包。

標記本身也沒買到任何東西：`loadChapterPackageSync` 把它變成一個 `isReusableCachedPackage` 會拒絕的封包，跟「根本沒有中繼資料」的處理完全相同。**現在失敗只讓該章快取失效，不寫任何東西**，跟 legado 的 `errorDownloadMap` 一致。

配套：`bookFailureCounts` 累積 5 次會把整本書 `.quarantined` 並持久化，而它**只有成功才歸零**。取消一次下載會一口氣取消很多章。現在移除下載、換源、使用者主動重試都會清掉這個預算與自動隔離（`BookStore.clearAutomaticQuarantine` 只清 `.quarantined`，不碰使用者自己選的 `.forcedLegacy`/`.forcedWeb`）。

---

## 目錄／書籍資訊快取

鍵是 `sha256(sourceId|normalizedURL)`——**綁書源，不綁書**。它因此活得比書久：刪掉書再從發現頁加回來，拿到的是同一份章節 URL，而且 App 裡沒有任何地方能清它（快取管理的 `CacheCategory` 根本沒有這個分類）。

這就是「移除下載後全書失敗、只有換源才好」的主因。移除下載之前，每一章都從 `online_cache/<bookId>/` 讀，從來沒有真的用過那些可能已經過期的 URL；刪掉目錄之後全書第一次回到網路，於是一起失敗。換源改變了 `sourceId`，鍵才變。

三道修法：

- `AppConfig.tocCacheTTL`（目前 6 小時）——快取命中路徑會檢查年齡。「檢查更新」那條路本來就傳 `forceRefresh: true`，不受影響。
- `clearOnlineDownload` 會清掉該書的目錄與書籍資訊快取條目（`BookSourceFetcher.clearTOCAndBookInfoCache`）。移除下載＝「我手上的東西全沒了，重新來過」，那就不該再用一份不知道多舊的目錄重新來過。
- **閱讀器在證據夠時自己去驗證目錄**（[`StaleTOCSuspicion`](../Modules/Services/LibraryStore/OnlineTOCCommitPolicy.swift)）。前兩道是時間與事件驅動的，都可能來不及：TTL 沒到期、使用者也沒移除下載，但站方已經改了 URL。

### 為什麼需要第三道

「重試」原本只重抓**單章**，而且沿用同一個 `ref.url`——所以目錄過期時，重試永遠好不了，使用者只能靠換源。

判準是**不同章節的失敗數**，不是任何單一失敗：章節是一章一章壞的（付費牆、限流、解析跟不上改版），目錄過期則是**每一章都壞**，因為每一章的 URL 都是那份清單給的。沒有任何單一失敗帶得了這個資訊。

達到 `AppConfig.staleTOCSuspicionThreshold`（3，刻意低於隔離門檻 5，否則書會為了同一批失敗先被隔離）就重抓一次目錄、清掉失敗預算、重置那些章節再試。

**每個閱讀工作階段只做一次。** 重抓後仍然失敗，就是真的失敗，失敗畫面是誠實的答案；在那之後還retry 就是這個倉庫一再要刪掉的重試雪崩。任何一章成功都會清空計數——成功證明那些 URL 是好的。

---

## 背景執行：能做到什麼、做不到什麼

iOS **沒有** Android foreground service 的對應物（legado 的 `CacheBookService` 靠它一直跑）。

`OfflineDownloadBackgroundTask` 拿的是一個 `UIApplication` 背景任務斷言。它買到的是**乾淨地停下來**，不是背景下載：到期時把執行中的書標記為暫停並落盤，回前景由 `reconcileInterruptedDownloads` 續傳。沒有它的話，任務會被凍在原地，記錄進度的那次寫入可能永遠不會發生。

**為什麼沒用 `URLSessionConfiguration.background`**（第二階段的前提）：

1. 一章不是「下載一個檔案」，是 `抓取 → 解析(SwiftSoup/JS) → 寫快取 → 驗證 → 提交`。背景 session 只把檔案丟回來、給幾秒喚醒時間，解析必須擠進那個窗口。
2. 傳輸方式是**每個章節 URL 各自決定**的（`ruleContent.webJs` 非空、URL 帶 `{"webView": true}`），而且失敗時會**中途翻成 WebView**。WebKit 在 App 被暫停時不會跑。
3. Cloudflare 挑戰需要前景 UI。
4. 每源節流（`concurrentRate`）與重試退避讓總時長不可預測，超過任何 BGTask 預算。

要做第二階段，得先把「純 HTTP 可抓」的書源分類出來，並把下載迴圈改寫成 delegate 驅動。

---

## 靈動島（Live Activity）

版面照系統自己的下載活動：**封面、一行「在下載什麼」、一行進度、尾端一顆圓形控制**。

### 封面怎麼過去

活動的 UI 跑在 **widget extension** 裡，它讀不到 `Application Support/Covers`（那是 App 自己的容器），而 `ContentState` 也塞不下圖片——整包只有幾 KB 預算。

所以 App 把每本下載中的書的封面**降採樣成一張 180px JPEG 寫進 app group 共享容器**（`DownloadActivityCoverStore`），狀態只帶檔名。編碼是 decode + JPEG write，**絕不能跑在下載的進度路徑上**：`refresh` 只做一次 `fileExists` 檢查，真正的編碼丟到 detached utility task，由下一次 refresh 撿起來（進度至少每章刷一次，所以封面幾乎立刻出現）。

讀原始封面一律走 `BookCoverLoader.localImage`——`Covers` 與 `CustomCovers` 的路由只有那一個地方知道。（原本 `AudiobookPlayer` 與 `HomeView` 各有一份三行的複製品，已收斂。）

### 主展哪一本

下載器同時跑多本，但系統只會顯示一個活動。緊湊態只夠一個圖示加一組數字，展開／鎖屏則**主展一本＋「另有 N 本」**。

排序規則：**未暫停的優先，其餘照書架順序**。不是「進度最多的優先」——那會在章節落地時不斷重排，主展位置跳來跳去。

### 暫停按鈕

尾端那顆是**暫停／繼續**，不是取消：鎖屏誤觸不該把一個快下載完的任務丟掉，而 Live Activity 沒有確認對話可用。

`ToggleDownloadPauseIntent` 是**第二個刻意複製的檔案**（第一個是 `DownloadActivityAttributes`），原因相同：兩個 target 用檔案系統同步資料夾，一個檔案不改專案結構就無法同時屬於兩邊。（`xcode-project-setup` skill 只做 SPM 安裝，而且明文禁止手改 pbxproj。）

**兩份必須完全一致**，而這只有在 `perform()` 不碰下載器時才做得到——widget target 沒有 `OfflineDownloadManager`。所以它把請求寫進 app group 佇列並發 Darwin 通知，由 `DownloadActivityCommandApplier` 套用。這個間接不只是為了讓程式碼能編譯：`LiveActivityIntent` 雖然文件說在 App 的 process 執行，但萬一請求在 App 沒跑時落地，它是被下次啟動撿起來而不是掉掉。

佇列是**陣列不是單一欄位**：連按兩下若被併成一次，按鈕與下載器就會對「到底暫停了沒」產生分歧。

### 更新優先級

章節完成數可以用 `minimumUpdateInterval` 合併；**控制狀態不能**。任何書籍的
`isPaused` 改變，或活動中的書籍 ID／主展順序改變，都會改到標題、進度條色彩、
按鈕圖示或按鈕所控制的 `bookId`，必須立即繞過節流。暫停尤其是最後一次寫入：
暫停後不再有章節完成事件能修正一個漏掉的狀態。

同一個 flush 必須持有所有權直到 `Activity.update` 返回。等待節流時遇到控制更新，
取消等待並立刻重啟；已經跨程序更新時遇到新狀態，只替換 `pendingState`，由原本的
flush 返回後依序送出。若在 `await activity.update` 前就把 `flushTask` 清成 `nil`，
兩個更新可能並發並以舊進度覆蓋新控制狀態。

Live Activity 的壽命可以長過 App process。控制器初始化時必須從
`Activity<DownloadActivityAttributes>.activities` 接回既有活動；否則重啟後第一次
狀態變更會另開一個活動，使用者正在看的舊活動永遠收不到暫停狀態。

## 護欄

- `Tests/iOS/yuedu appTests/OnlineTOCCommitPolicyTests.swift` — 空目錄不得提交；目錄過期的判準是「不同章節的失敗數」且只做一次。
- `Tests/iOS/yuedu appTests/OfflineChapterStoreTests.swift` — `.preserveContent` 不刪檔、`.deleteMismatched` 照刪；失效一章不得重建書籍目錄。
- `Tests/iOS/yuedu appTests/OfflineDownloadManagerTests.swift` — 既有的移除／對帳護欄。
- `Tests/iOS/yuedu appTests/DownloadLiveActivityStateTests.swift` — 主展的書不得是暫停中的；排序不得隨進度重排；封面只帶檔名。
- `Tests/iOS/yuedu appTests/DownloadActivityCommandQueueTests.swift` — 按鈕請求恰好送達一次，連按兩下不得併成一次。

## 日誌判準（Release Console 可見）

- `⟐ TOC refresh came back empty, keeping existing chapters` / `⟐ TOC first page came back empty` — 不變量 1 擋下了一次。
- `⟐ several chapters failed, revalidating TOC` — 閱讀器認定目錄過期，正在重抓；後面該跟著章節恢復。同一個工作階段只會出現一次。
- `⟐ reconcile skipped, empty TOC` — 不變量 2 擋下了一次。
- `⟐ offline download background task started` / `ended` / `⟐ offline download background time expired` / `⟐ pausing offline downloads for background expiry` — 背景斷言的生命週期。
