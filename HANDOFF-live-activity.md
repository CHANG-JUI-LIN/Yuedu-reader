# 交接：離線下載 Live Activity（靈動島）

## 專案

`/Users/zhangruilin/Desktop/Yuedu-reader` — iOS SwiftUI + CoreText 小說閱讀器（EPUB / TXT / 網路小說）。
Swift 6、iOS 17.0+、Xcode 16。HEAD = `bed7d21`，**所有相關改動都還沒 commit**。
專案慣例寫在 `CLAUDE.md`，請先讀，尤其是「工程紀律」那節（禁止亂加兜底、禁止 sleep 等待、一件事只留一條實現路徑）。

## 這一輪在做什麼

使用者要三件事，前兩件已完成，第三件卡住：

1. **修「移除下載後全書章節載入失敗，只有換源才好」** — 已完成。
2. **修「切後台幾分鐘回來，下載全部消失」** — 已完成。
3. **離線下載加靈動島（Live Activity），版面照 Safari 下載那樣：左邊書封面、書名、進度、右邊圓形暫停鍵** — **未完成，見下方。**

1 與 2 的根因分析與不變量寫在 `Technotes/OfflineDownloadContract.md`，請直接讀那份，不要重新分析。

---

## 未解決的問題（你的任務）

### 主問題：暫停後靈動島畫面不更新

使用者實測回報：**按靈動島上的暫停鍵，下載真的暫停了，但島上的畫面完全沒變**（圖示沒從 pause 變成 play，文字也沒變）。

已排除的：
- 命令鏈是通的 —— 下載確實會暫停，所以 Intent 有執行、`OfflineDownloadManager.pause()` 有跑到。
- `pause()` → `task.setPaused(true)` → `BookStore.replaceOfflineDownloadTask(isRunning: false)` → 該函式尾端會呼叫 `DownloadLiveActivityController.refresh(books:)`。這條鏈在程式碼上是完整的。
- `derivedState(isRunning: false)` 在 `isPaused == true` 且 `pendingIndices` 非空時回傳 `.paused`，而 `contentState` 的過濾條件是 `.downloading || .paused`，所以書**不會**被過濾掉。
- 圖示邏輯是對的：`book.isPaused ? "play.fill" : "pause.fill"`。

**還沒查到的**：為什麼 `Activity.update` 沒有讓畫面改變。最可疑的地方是
`Modules/Services/Offline/DownloadLiveActivityController.swift` 的 `schedule(_:)` 節流（`minimumUpdateInterval = 1.5` 秒）。

關鍵風險點：**暫停之後不會再有任何章節完成，所以那一次推送是最後一次機會**。如果它被節流吃掉、被 `flushTask` 的競態吃掉，或 `pendingState` 被覆蓋，畫面就永遠停在舊狀態，而且沒有第二次機會來修正。請重點檢查 `schedule()` 裡 `flushTask` 的指派時機與 `pendingState` 的讀寫順序。

### 次問題：靈動島展開態的版面沒被驗證過

使用者給過兩張實機截圖，兩次版面都不對（第一次內容散開、第二次整個被壓到下緣）。目前這一版**沒有人看過實機效果**。

**已查證的關鍵幾何**（別再猜，這是我繞了三圈才確認的）：

| 區域 | 實際位置 |
|---|---|
| `.leading` | 貼在 TrueDepth 相機**左側**，多餘內容往下折 |
| `.trailing` | 貼在相機**右側**，多餘內容往下折 |
| `.center` | 在相機**下方** |
| `.bottom` | 在前三者**全部之下** |

推論：
- 只用 `.bottom` → 上面會空出 leading/trailing/center 的位置＋相機帶，內容被壓到下緣（第二張截圖的成因）。
- 拆成 leading(封面)/center(文字)/trailing(按鈕) → 封面在相機旁、文字在相機下方，**兩者永遠不在同一行**（第一張截圖的成因）。
- 目前版本：整列放 `.center`。**未驗證。**
- 要用到相機那一帶，只能靠 `.leading` / `.trailing`。

來源：[Apple — DynamicIslandExpandedRegionPosition](https://developer.apple.com/documentation/swiftui/dynamicislandexpandedregionposition)、[Swift with Majid](https://swiftwithmajid.com/2022/09/28/mastering-dynamic-island-in-swiftui/)

---

## 怎麼重現與驗證（重要，省你很多時間）

已經做好一個 DEBUG 專用的觸發器，**不需要真的下載一本書**就能讓 Live Activity 出現：

`Modules/Services/Offline/DownloadActivityDebugHarness.swift`（整檔包在 `#if DEBUG` 裡，不會出貨）

```bash
# 模擬器 UDID（iPhone 17 Pro Max / iOS 26.5，這台是為了測試才建的）
SIM=D787D0F2-DD88-475A-9BC2-D4484B706011

xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "id=$SIM" build
APP=$(find ~/Library/Developer/Xcode/DerivedData/Yuedu-Reader-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "*.app" | head -1)
xcrun simctl install "$SIM" "$APP"
xcrun simctl terminate "$SIM" com.zhangruilin.yuedureader
xcrun simctl launch "$SIM" com.zhangruilin.yuedureader -debugDownloadActivity
```

啟動參數：
- `-debugDownloadActivity` — 啟一個假的 Live Activity（1 本書、第 4/50 章）
- `-debugDownloadActivityPaused` — 直接以暫停狀態啟動
- `-debugDownloadActivityMultiple` — 3 本書
- `-debugDownloadActivityToggle` — 6 秒後翻轉暫停狀態，**這個是用來驗主問題的**（考的是 `Activity.update`，不是啟動）

截圖：`xcrun simctl io "$SIM" screenshot --type=png out.png`

**實測過的注意事項：**
- 第一次跑會跳「Allow Live Activities from 閱讀?」，要在**鎖屏**上按 Allow。
- **`simctl launch` 對已經在前景的 App 不會重跑 `.onAppear`**，所以每次都要先 `terminate`。
- **靈動島在這台模擬器的主畫面上根本沒被畫出來**（連黑色切口都沒有），所以島的版面在這裡驗不了；**鎖屏可以**，而且鎖屏與島的展開態共用同一個 `DownloadRow` view，所以鎖屏至少能驗內容與狀態切換。
- `-debugDownloadActivityToggle` 的 6 秒 Task 在 App 被鎖屏暫停時**不會執行**，要讓它在前景跑完再鎖屏。

**已經驗證過的**：Live Activity 會正常啟動（log `⟐ download Live Activity started`），鎖屏版面正確 —— 封面、書名、`第 4 章，共 50 章`、進度條、右側暫停鍵，與參考圖一致。

---

## 相關檔案

**App 端**（`Modules/Services/Offline/`）
- `DownloadLiveActivityController.swift` — 啟動／更新／結束活動，含 1.5 秒節流。**主問題最可疑的地方。**
- `DownloadActivityAttributes.swift` — ActivityAttributes 與 ContentState
- `DownloadActivityIntent.swift` — 暫停按鈕的 App Intent ＋ 命令佇列
- `DownloadActivityCommandApplier.swift` — 在 App 端套用佇列裡的請求
- `DownloadActivityCoverStore.swift` — 把書封面縮圖寫進 app group
- `DownloadActivityDebugHarness.swift` — 上面說的測試觸發器

**Widget 端**（`Widget/`）
- `DownloadLiveActivityWidget.swift` — 版面本體（`DownloadRow` 是鎖屏與島共用的那一列）
- `DownloadActivityAttributes.swift`、`DownloadActivityIntent.swift` — **與 App 端那兩份是刻意的重複檔**

資料來源接點：`BookStore.replaceOfflineDownloadTask`（進度漏斗）與 `clearOnlineDownload`。

### 為什麼有重複檔（別「順手」合併掉）

Widget target 與 App target 的檔案群組不重疊，而這個專案用 Xcode 16 的 file-system-synchronized groups，一個檔案不改 `.pbxproj` 就沒辦法同時屬於兩個 target。ActivityAttributes 本來就會被編進兩個模組、由 ActivityKit 靠型別名稱配對，所以複製是可行的 —— **但兩份的名稱與編碼結構必須完全一致**，改一份就要改另一份。目前用 `diff` 驗過是逐字相同的。

另外查到：**同一個 `LiveActivityIntent` 同時存在於 App 與 Widget 時，只有 App 那一份會被執行**（[Apple Developer Forums](https://developer.apple.com/forums/thread/764329)）。這代表目前那套「Intent 寫進 app group 佇列 → Darwin 通知 → App 端套用」其實是多餘的，App 那份 Intent 可以直接呼叫 `OfflineDownloadManager`。**這是一個值得做的簡化**，可以砍掉 `DownloadActivityCommandApplier`、命令佇列與對應測試 —— 而且它也可能就是主問題的成因（那段間接讓狀態更新晚了一步）。建議優先查這裡。

---

## 地雷（都是踩過的）

1. **不要用 `-derivedDataPath` 另開 DerivedData。** 使用者磁碟吃緊，一份 7.3G。用預設的就好。他的 DerivedData 如果壞了（`module file not found: ....pcm`），跟他講一聲讓他自己修，不要繞過去。
2. **測試指令一律用 `id=$SIM` 指定裝置**，不要用 `name=`。這台機器上原本一台 iPhone 模擬器都沒有（只有 iPad），那台是建出來的。
3. **背景測試超過 5 分鐘沒動靜要主動查。** log 停在 `Run script` 而沒有 `Testing started` 就是卡在執行階段。
4. **不要同時跑兩個 `xcodebuild test` 打同一台模擬器**，會互搶。
5. `FBSOpenApplicationServiceErrorDomain Code=1 RequestDenied` 是 CoreSimulator 的暫時狀態，不是設定問題，`xcrun simctl shutdown all` 可清。
6. **測試不要依賴 app group 的 UserDefaults 單例** —— 同一個 suite 會被跑兩次且並行，互相 drain。已經把 `DownloadActivityCommandQueue` 的 `defaults` 改成可注入，測試各自建唯一 suite。

## 不要碰的東西

工作區裡有**使用者自己並行在改**的檔案，跟這個任務無關，請不要動也不要 commit：

```
Modules/Core/ReaderCore/BrowserLayout/*   （含新增的 CSSFrontend.swift、FloatContext.swift）
Modules/Core/ReaderCore/Customization/ReaderOverlayLayout.swift
Modules/Features/Reader/ReaderSettingsView.swift
Tests/iOS/yuedu appTests/ReaderLayoutPresetImporterTests.swift
Tests/iOS/yuedu appTests/BrowserLayoutFloatLayoutTests.swift
```

## 目前測試狀態

最後一次跑（涵蓋離線下載與 Live Activity 相關）：**76 passed / 0 failed**，`** TEST SUCCEEDED **`。
App target 與 Widget target 都編得過。

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "id=$SIM" \
  -only-testing:'yuedu appTests/DownloadLiveActivityStateTests' \
  -only-testing:'yuedu appTests/DownloadActivityCommandQueueTests' \
  -only-testing:'yuedu appTests/OfflineDownloadManagerTests' \
  -only-testing:'yuedu appTests/OfflineChapterStoreTests' \
  -only-testing:'yuedu appTests/OnlineTOCCommitPolicyTests' \
  -only-testing:'yuedu appTests/StaleTOCSuspicionTests'
```

## 交接完還沒做的事

- 主問題（暫停後島不更新）未修。
- 島的展開態版面未經實機／模擬器驗證。
- `DownloadActivityDebugHarness.swift` 是測試用的，問題解決後可以留（DEBUG only）也可以刪，看你。
- 這些改動**都還沒 commit**，使用者還沒決定要不要 commit。
