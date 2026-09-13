# YueduCoreText 0.4.0 發布與正常 project 接線

2026-09-12 發布，跨日完成 Reader 驗證。本報告接續 [直排入口的發布前驗收快照](../vertical-entry-import-2026-09-12.md)。

## 根因與修正

Reader 呼叫了 `BrowserScrollDocument.documentPoint(forCharOffset:)` 等直排 API，但正常 `.xcodeproj` 仍解析 0.3.0；這些 API 只存在於相鄰 checkout 的未發布修改。先前僅驗證本機 override workspace，沒有完成正常 project 交付。

現在套件已發布 [0.4.0](https://github.com/CHANG-JUI-LIN/YueduCoreText/releases/tag/0.4.0)，commit 為 `4a49d3183f5f5c0cc44ff3e68c1a01113d255438`。Reader 的最低版本改為 0.4.0、限制在 0.4.x，並由 Xcode 實際解析、產生 Package.resolved。其他依賴的版本與 revision 均與修改前一致。

- Package 原始 checkout：`/Users/zhangruilin/Desktop/YueduCoreText`，main；起始 HEAD `12bb1b29c64b552740cf322b132924ace4727826`。既有直排修改與三語文件已納入上述發布 commit。
- Reader 原始 checkout：`/Users/zhangruilin/Desktop/Yuedu-reader`，main；起始 HEAD `4dc1d9f58cfcd866a518285de0d96e0e82dbe471`。原有 TTS、AI、匯入與其他同時修改保留；本次 Reader 接線修改留在工作目錄，未替其他工作提交或推送。
- `Yuedu-Reader.xcodeproj/project.pbxproj`：同一個遠端 package reference，`upToNextMinorVersion(0.4.0)`，沒有新增重複 product／local dependency。
- `Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`：鎖定真實 0.4.0 tag 對應 revision。
- `CoreTextScrollEngine.chunkIndex(forChapter:charOffset:)` 可使用新版 `documentPoint` 還原直排位置；正常 project 編譯套件來源位於 Xcode 的遠端 `SourcePackages/checkouts/YueduCoreText`，沒有使用相鄰 checkout override 或修改快取原始碼。

## 套件驗證

- 本機：Xcode 27 beta（27A5252f）／iPhone 17 Pro、iOS 27 Simulator，destination `id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`。
- 134 項套件測試通過（123 core + 11 Typography）：`/tmp/yuedu-coretext-0.4.0/package.xcresult`。
- 6 項獨立 public API consumer 測試通過：`/tmp/yuedu-coretext-0.4.0/consumer.xcresult`。含直排分頁／繪製、ruby/source/selection geometry 與 `documentPoint`，不引用 Reader。
- 同一發布 commit 的 [GitHub CI](https://github.com/CHANG-JUI-LIN/YueduCoreText/actions/runs/34703062923) 使用 Xcode 16.4，也通過 134 + 6 項測試；`.xcresult` 由 workflow 保存。完整日誌另存 `/tmp/yuedu-coretext-0.4.0/ci.log`。
- 這是編譯／功能驗證，不宣稱真機效能或耗電改善。

套件命令（分別在套件根目錄與 `Examples/StandaloneConsumer` 執行）：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild test -scheme YueduCoreText-Package \
  -destination 'id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400' \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/yuedu-coretext-0.4.0/package.xcresult
xcodebuild test -scheme YueduCoreTextConsumer \
  -destination 'id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400' \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/yuedu-coretext-0.4.0/consumer.xcresult
```

## Reader 正常 project 驗證

以下全部使用 `.xcodeproj`，沒有使用 `Yuedu-Engine.xcworkspace`。

```sh
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
xcodebuild -resolvePackageDependencies -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400' \
  -parallel-testing-enabled NO \
  '-only-testing:yuedu appTests/BrowserVerticalReaderRouteTests' \
  '-only-testing:yuedu appTests/JapaneseVerticalRubyTests' \
  '-only-testing:yuedu appTests/BrowserScrollTileCellTests' \
  '-only-testing:yuedu appTests/BrowserLayoutPageEngineTests' \
  -resultBundlePath /tmp/yuedu-coretext-0.4.0/reader-remote.xcresult
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'id=00008140-00023C392E90801C' \
  -resultBundlePath /tmp/yuedu-coretext-0.4.0/reader-device.xcresult
```

- 正常 project 回歸：25 項測試／4 suites 全數通過，`TEST SUCCEEDED`、exit 0，產物 `/tmp/yuedu-coretext-0.4.0/reader-remote.xcresult` 與同名 `.log`。包含《草枕》正式 Reader 入口與 corpus、直排捲動、來源位置恢復及 BrowserAuto／fallback 代表案例。
- 連接的「張瑞麟的 iPhone」（iPhone 16 Pro Max）destination 建置：`BUILD SUCCEEDED`、exit 0，產物 `/tmp/yuedu-coretext-0.4.0/reader-device.xcresult` 與同名 `.log`。使用正常簽署設定，沒有關閉 code signing。這證明真機目標可建置，不代表本次已安裝／操作真機閱讀器。
- 遠端實際 checkout HEAD 核對為 `4a49d3183f5f5c0cc44ff3e68c1a01113d255438`。正常 project 不再需要本機 override，也不再缺少 `documentPoint`。
- 套件正式 ref 與 release 已存在；Reader 的依賴設定及既有直排 adapter 仍是本機未提交修改，因此未宣稱 Reader GitHub main 已同步本機全部修改。

不取得 Yuedu Reader 原始碼，只取得 YueduCoreText 及其正式宣告的依賴，可以從 HTML + CSS 獨立完成排版、分頁與繪製；同一發布 commit 的 GitHub consumer 6/6 通過為直接證據。
