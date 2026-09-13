# Ruby 二次開書回退修復 — 2026-09-13

## 證據與根因

從連接 iPhone 的現有診斷紀錄確認，同一本《草枕》第一次翻頁的宿主是 BrowserLayoutPageViewController；第二次恢復到 `(spineIndex: 1, charOffset: 2725)` 後，宿主變成 CoreTextPageViewController。第二次開書期間同時出現 refreshTransaction 取消預載及 `layoutUnavailable(1)`。原始真機日誌只保留於本機 `/tmp/yuedu-ruby-reopen/device-current.jsonl`，不納入 repo。

1. BrowserLayoutPageEngine 的取消未淘汰 generation。資源準備在取消後返回時，仍能建立 session；取消拋出的錯誤被一般 catch 當成 layout failure，將 chapter choice 改成 legacyEngineFailure。後續預載重用這個錯誤決策，ruby 因而換成 legacy 繪製。
2. EPUBPageRenderer 的重排只對 CoreTextPageEngine 傳遞 ensuringSpine；Browser 重排只涵蓋已決策／已排版章節。第二次開書要恢復的章節尚未準備時，交易回報 layoutUnavailable。

## 修改

- Browser 的 cancelPendingWork 淘汰 generation 並取消尚未完成的 session；已完成章節的繪製結果仍保留。
- 預載、能力掃描、資源準備、分頁完成及錯誤處理均驗證 generation 與取消狀態，舊工作不能發布 fallback、清掉新工作的 task，或重新觸發 ready callback。
- CancellationError／HTMLLayoutError.cancelled 不再屬於整章 fallback；真正 unsupported／resource／layout failure 保留既有政策。
- Browser invalidateLayout 可接收 ensuringSpine，EPUBPageRenderer 的 refresh transaction 明確傳入目標章節。
- public 引擎與 ruby 排字演算法沒有修改；這是 Reader adapter 的生命週期與重排責任修正，不需要發布新的 YueduCoreText 版本。現有 0.4.0 遠端依賴保留。

## 回歸

- BrowserVerticalReaderRouteTests 新增以 continuation 控制資源準備的取消案例，沒有 sleep 或延遲重試。覆蓋舊工作先完成、替代工作已開始後舊工作才完成兩種順序；下一次預載仍須使用 Browser 並繪出 ruby。
- JapaneseVerticalRubyTests 擴充正式匯入案例：同一 render-cache identity、書架資料重新讀取、PublicationSession 再次開啟，透過真正 refresh transaction 恢復到 `(1,2725)`，確認 Browser 宿主、相同 sourceText、直排 ruby 以及捲動的 Browser chunks。
- 兩組新增斷言均在修正前重現失敗；當時 CoreTextWritingModeTests 的 25 項斷言通過。失敗測試結束後 Xcode 未退出，已中止該兩次命令；不把它們記為成功 run。基線日誌：`baseline.log`、`reopen-baseline.log`，位於 `/tmp/yuedu-ruby-reopen`。
- 修正後 BrowserVerticalReaderRouteTests、JapaneseVerticalRubyTests、BrowserLayoutPageEngineTests、ReaderRenderRefreshTests：32 tests／4 suites 通過，exit 0；`/tmp/yuedu-ruby-reopen/regression.xcresult` 與同名 `.log`。
- 最後擴充取消測試的交錯順序後，BrowserVerticalReaderRouteTests 2 tests（取消測試包含兩組參數）通過，exit 0；`/tmp/yuedu-ruby-reopen/cancellation-verified.xcresult` 與同名 `.log`。先前 32 項結果覆蓋相同的最終 production 修改。
- iPhone 在取得原始日誌後離線，指定 UDID 的建置 exit 70（destination unavailable），沒有冒充成功。改用 `generic/platform=iOS` 的正常簽署建置：BUILD SUCCEEDED、exit 0；`/tmp/yuedu-ruby-reopen/device-build.xcresult` 與同名 `.log`。未關閉 code signing。
- 最終修復尚未安裝到離線的 iPhone，也未在該真機手動重開書驗證；二次開書的修正後證據來自上列 Simulator 正式 Reader 路徑測試。

驗證工具鏈為 Xcode 27 beta（`/Applications/Xcode-beta.app/Contents/Developer`），Simulator destination `id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`。全部測試使用 `-project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -parallel-testing-enabled NO`。

另一個 task 佔用預設 build.db，導致 `cancellation-final` 建置被拒絕（未執行測試）。後續改用另一個既有 DerivedData 目錄，沒有複製 checkout 或修改套件快取原始碼：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Yuedu-Engine-fcbkzrduqdvupqgtvadviyzijvjd \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/Yuedu-Reader-fuvxksffedishjcrnsaqrmtosczt/SourcePackages \
  -destination 'id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400' \
  -parallel-testing-enabled NO \
  '-only-testing:yuedu appTests/BrowserVerticalReaderRouteTests' \
  -resultBundlePath /tmp/yuedu-ruby-reopen/cancellation-verified.xcresult
```

本輪沒有更改匯入 UI、閱讀位置格式或使用者資料，也沒有替其他並行工作提交／推送。

一般 iOS 裝置建置命令：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'generic/platform=iOS' \
  -resultBundlePath /tmp/yuedu-ruby-reopen/device-build.xcresult
```
