# 直排正式入口與多本匯入修復（發布前驗收快照）

> 後續更新：套件已發布 0.4.0，Reader 正常 project 已更新依賴。以下保留發布前的本機 workspace 驗收紀錄；目前遠端接線與建置結果以 [0.4.0 發布報告](extraction/release-0.4.0.md) 為準。

工作目錄為原本的 `Yuedu-reader` 與相鄰 `YueduCoreText` checkout，未建立副本、commit、push 或 tag。Reader 起點為 `4dc1d9f58cfcd866a518285de0d96e0e82dbe471`，套件起點為 `12bb1b29c64b552740cf322b132924ace4727826`。原有文件、TTS 與 AI 的同時修改保留。

## 正式路由

`EPUBPageRenderer.load` 仍建立同一個 BrowserAuto，供翻頁與 `CoreTextScrollEngine.browserAutoEngine` 使用。這次 `BrowserLayoutPageEngine` 將 Reader 的 writingMode 傳入套件的 capability scanner 和 layout configuration，移除捲動入口原本無條件排除直排的 guard。

`ReaderScrollItem` 保留真正 writingMode，直排連續文件沿 x 軸由右至左建立繪製視窗；捲動的內容尺寸、文字點選、章節位置查詢與 cell 的上下邊距跟著使用物理直排座標。沒有把連續捲動拼成分頁截圖。直排圖片、float 等套件不支援的章節，以及固定版面 EPUB，仍走原有專用／legacy 路徑。

開發中的套件尚未發布。請以根目錄 `Yuedu-Engine.xcworkspace` 連接相鄰 `../YueduCoreText`；原本遠端 0.3.0 不包含這次 scanner API 與直排實作，單獨 remote resolve 不代表已取得本輪修復。沒有修改 Package.resolved 指向不存在的 ref。

## 匯入與書架

- Files picker 使用 `allowsMultipleSelection: true`，選完直接由 `LocalBookImportService.importBooks` 逐本匯入。移除第二次書籍資訊確認與其暫存生命週期。
- 沿用現有 TXT、Markdown、JSON、EPUB、PDF、漫畫、ZIP 音訊及單一音訊 importer；每本保留 security-scoped access 到持久副本建立。失敗按檔名列出，其他選項繼續；取消保留已完成的書。
- 每次 shared import 成功立即保存書架，不再只有指定 title/author 的匯入才立即保存。
- 找到可移除整張新書卡的同步競態：iCloud／Firestore 先讀取舊書架，等待遠端合併時若新書加入或進度更新，原本仍會以舊結果覆蓋整份書架。BookStore 現在有 mutationRevision，兩個同步呼叫者攜帶取得快照時的版本；過期結果不套用，下一次同步再納入現有修改。未修改雲端資料或以關閉同步掩蓋問題。
- 使用者轉述的日文 href 解碼修復已存在，保留原本 `readiumURLs` 及 fallbackTitle 行為。

同步競態由本機確定性測試驗證；沒有使用使用者當次的真機同步紀錄，不能斷言當次消失一定只由此路徑造成。模擬器正式書架開《草枕》、退出後，書卡仍實際可見。

## 驗證

工具鏈：`/Applications/Xcode-beta.app/Contents/Developer`；destination：`id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`（iPhone 17 Pro／iOS 27 Simulator）。

共同命令：

```sh
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
xcodebuild test -workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader \
  -destination "$(bash scripts/sim.sh dest)" -parallel-testing-enabled NO \
  '-only-testing:yuedu appTests/BrowserVerticalReaderRouteTests' \
  '-only-testing:yuedu appTests/JapaneseVerticalRubyTests' \
  '-only-testing:yuedu appTests/LocalBookImportServiceTests' \
  '-only-testing:yuedu appTests/BookStoreMetadataWriteBudgetTests' \
  '-only-testing:yuedu appTests/BrowserScrollTileCellTests' \
  '-only-testing:yuedu appTests/BrowserLayoutPageEngineTests'
```

- 修改直排前 `CoreTextWritingModeTests`：25 項通過，`/tmp/yuedu-vertical-entry/baseline.xcresult`。
- 最後只調整匯入 Form 的主題 surface 後，重跑 `LocalBookImportServiceTests`：5 項通過、exit 0，`/tmp/yuedu-vertical-entry/import-final.xcresult`。其他相關程式未再變更，沿用下列較廣證據。
- 上列 6 類：33 項通過，exit 0，`/tmp/yuedu-vertical-entry/production-regression2.xcresult` 與同名 `.log`。
- 包含《草枕》13 章的原有 package corpus，以及新增的真正 `EPUBPageRenderer.load` → BrowserAuto／scroll engine 驗收。原書不加入 repo。
- 匯入測試覆蓋多本／中間壞檔／立即重讀書架／開書更新進度／同步過期快照／取消及有效同步仍可套用。
- 編譯期間遇到其他並行 TTS 修改的測試介面不一致，兩個 Browser 測試改接 `ReaderPlaybackHighlight`；新 AICharacterCardStore 缺少 Combine import，補上 import 後才完成上列驗證。沒有改寫那些功能的邏輯。
- 本輪沒有真機驗證。最後 Mac 鎖定，未能完成 Files 多選介面與格狀書架的手動驗收；不以 service 測試冒充這兩項 UI 已完成。
- 三語字串檢查與 diff whitespace 檢查通過。既有其他頁面的標題規範命中未混入本輪修復。
