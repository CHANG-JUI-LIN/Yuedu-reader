# Swift 6 語言模式遷移計畫（2026-10-17，草案，未開始）

背景：`project.pbxproj` 5 個 target × Debug/Release 共 10 處都是 `SWIFT_VERSION = 5.0`；`xcconfig/Yuedu-reader_common.xcconfig`（寫著 6.0）沒被引用，是死設定。詳見 `Technotes/AppleSkillsAudit-2026-10-17.md` 第 1 項。使用者於 2026-10-17 選擇「規劃 Swift 6 遷移」。

## 合約

- 目標：app target 最終 `SWIFT_VERSION = 6.0` 且 0 個 data-race 錯誤；每一階段能獨立合併、能單獨回退。
- 限制：
  - 不改行為（書源相容、CoreText 排版、翻頁與開書時間）。
  - 不新增快取層或第二條路徑。
  - 不用 sleep／重試去繞競態。
  - `@unchecked Sendable`（現 65 處）與 `nonisolated(unsafe)`（現 22 處）的總數只能減不能增；新增任何一個都要在註解寫明擋的是什麼、何時可刪。
  - 不一次改全專案。
- 驗收證據：每階段前後的警告／錯誤數（附指令與 resultBundle）；最小相關測試綠（`CoreTextWritingModeTests`、書源解析相關）；翻頁與開書的既有計時（`SourcePerfTrace`）無退步，附毫秒數。

## 關鍵限制：遷移單位不是目錄

Swift 語言模式以 module（target）為單位。本專案 `Modules/` 與 `Targets/` 全部編進同一個 `yuedu app` target，所以不能「Core 先 6、Features 後 6」。可行的漸進路徑是官方做法：先用 `SWIFT_STRICT_CONCURRENCY` 把診斷逐級調高，再把各 upcoming feature 旗標逐一打開（5 模式下是警告，6 模式下變錯誤），最後才翻 `SWIFT_VERSION`。目錄只用來排修復順序，不是遷移邊界。

## 現況數據（行數，grep，未建置）

| 項目 | Core | Services | Features | SharedUI | Targets |
|---|---|---|---|---|---|
| Swift 檔 | 348 | 265 | 345 | 36 | 22 |
| `@unchecked Sendable` | 36 | 23 | 5 | 0 | 1 |
| `nonisolated(unsafe)` | 17 | 2 | 0 | 3 | 0 |
| `@preconcurrency` | 4 | 3 | 2 | 0 | 0 |
| `DispatchQueue` | 57 | 26 | 43 | 0 | 3 |
| `static var` | 51 | 78 | 36 | 31 | 7 |
| `ObservableObject` 類別 | 14 | 55 | 28 | 3 | 1 |
| 鎖（Semaphore／NSLock／unfair lock） | 65 | 26 | 5 | 0 | 0 |

Core 內最大的是 `ReaderCore` 161 檔、`RuleEngine` 48、`BookSource` 31、`AI` 30、`TTS` 25。Widget 4 檔、ShareExtension 1 檔。另外，appTests／appUITests 已開 `SWIFT_APPROACHABLE_CONCURRENCY = YES`，app 本身沒有，測試與 app 的並發模式現在就不一致。

## 階段

0. （可獨立、零風險）決定死掉的 `common.xcconfig`：刪除或改寫，並在 CLAUDE.md／AGENTS.md 註明實際語言模式。需使用者點頭才改。
1. 量測，不改檔：以命令列覆寫 `SWIFT_STRICT_CONCURRENCY=targeted`、再 `complete` 各建置一次（`scripts/sim.sh` 解析工具鏈與目的地、`-resultBundlePath` 留診斷、不用 `-derivedDataPath`）。產出：警告總數、依診斷類別與依檔案的分布、前 20 個熱點檔。這一步決定後面的順序，沒有它不要動手。
2. 用 `swiftc` 列出本工具鏈支援的 upcoming feature 名稱（以 Xcode 27.1 實際輸出為準，不憑記憶），依風險由低到高逐一打開；每打開一個就清到 0 再開下一個。會改變語意的旗標（例如影響 `nonisolated async` 執行位置的）放最後並單獨驗證。
3. 依診斷類別而不是目錄修復，優先順序暫定：
   - `static var` 全域可變狀態（現 203 處）：能改 `let` 就改，其次 actor／`@MainActor`，最後才考慮 `nonisolated(unsafe)` 並依上面規定登記。
   - 鎖（現 96 處）：集中成幾個 Sendable 包裝（`OSAllocatedUnfairLock` 等），不要在各處臨時補。
   - `ObservableObject` 類別（現 101 個）：標 `@MainActor`；`GlobalSettings`（`@Observable`，無 `@MainActor`）被 CoreText 排版程式碼直接讀，是否有背景執行緒讀取要先查證再決定（掃描員的推測，尚未確認）。
   - `DispatchQueue`（現 129 處）：逐處判斷能否換成 actor／async，熱路徑（`ReaderCore`）先量再動。
   - 第三方 SDK 的 Sendable 缺口：目前已有 9 處 `@preconcurrency import`，新增前先查是否有 SDK 更新。
4. 先翻 Widget（4 檔）與 ShareExtension（1 檔）為 `SWIFT_VERSION = 6.0` 當先導；注意 Widget 目前有另一個 session 在改本地化，等它結束。
5. 翻 appTests／appUITests（已開 approachable concurrency），最後翻 `yuedu app`。完成後更新 CLAUDE.md 的說法。

## 風險

- `ReaderCore`（161 檔、65 處鎖）是 CoreText 熱路徑，錯誤的隔離會拖慢翻頁；任何改動都要有前後毫秒數。
- 書源 JS bridge（`BookSourceSession`、每源一個 `JSContext`）是單執行緒物件，隔離要設計，不能用 `@unchecked Sendable` 蓋過。
- 測試套件假設共享狀態、`-parallel-testing-enabled NO` 循序執行；並發模式變動可能暴露目前被循序掩蓋的問題。
- 警告量可能很大（第 1 階段才知道）；若超過可管理範圍，先決定是否分多個 PR。

## 排程限制

目前有三個修復 session 會用到共用的 DerivedData 與模擬器。第 1 階段要等它們結束，或在獨立 worktree 跑；不要在它們建置時硬跑。
