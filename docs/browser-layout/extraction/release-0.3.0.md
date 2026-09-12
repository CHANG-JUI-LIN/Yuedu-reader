# YueduCoreText 0.3.0 發布與遠端接線 — 2026-09-12

本報告接續 [抽取驗收快照](STATUS.md)。使用者後續授權發布；0.3.0 已發布，Reader 的正常 `.xcodeproj` 已改成直接解析 GitHub 套件，不需要相鄰 checkout。

## 已發布套件

- Release：https://github.com/CHANG-JUI-LIN/YueduCoreText/releases/tag/0.3.0
- Tag：`0.3.0`；commit：`e8b87225cd8b2cc7b1b558de9b382fab2ce6be1d`。
- Reader 的 Xcode package requirement 為 `upToNextMajorVersion(0.3.0)`，Xcode 自行產生的 Package.resolved 鎖定上述真實 commit。
- 其他已鎖定依賴沒有更新。SwiftSoup 仍是 `2.13.7 / 8d6ad267714cac3ae747cefdd21f7a6665006e1f`。
- `Yuedu-Engine.xcworkspace` 只提供可選的相鄰 checkout 開發 override；本輪遠端驗收使用 `-project Yuedu-Reader.xcodeproj`，沒有使用該 workspace。
- 原始 Reader checkout 工作樹完成遠端建置；沒有另外 clone 或複製 Reader。這證明當前來源可解析已發布套件，但沒有另外執行一份全新 App clone 的所有 CI／執行流程。

## 實際驗證

工具鏈：Xcode 27.0 beta / iOS Simulator 27.0；destination：`platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6`。所有測試使用 `-parallel-testing-enabled NO`。

| 驗證 | 通過／失敗／跳過 | 結果產物 |
|---|---|---|
| 發布前套件完整回歸 | 128 / 0 / 0 | `/tmp/yuedu-engine-release/package-final.xcresult` |
| Reader 遠端依賴建置及 focused regression | 58 / 0 / 0 | `/tmp/yuedu-engine-release/app-remote.xcresult` |
| 正式 GitHub 0.3.0 獨立 consumer | 5 / 0 / 0 | `/tmp/yuedu-engine-release/consumer-remote.xcresult` |

Reader 回歸涵蓋 BrowserLayoutPageEngine、BrowserScrollDocument、精確 geometry parity、增量 session、Reader parity、文字互動、EPUB Auto route、原公開 API、返回手勢與真實 SwiftUI navigation stack。其他既有導航改動一併提交；其五種翻頁／捲動 UI 操作證據見 [NavigationBackSwipeReservation](../../../Technotes/NavigationBackSwipeReservation.md)。此處沒有把那些較早的 UI 執行列入本輪 58 項。

遠端 consumer 目錄為 `/tmp/yuedu-engine-release/RemoteConsumer`，只包含已發布 example 的 Sources、Tests 與以下 dependency：

```swift
.package(url: "https://github.com/CHANG-JUI-LIN/YueduCoreText", exact: "0.3.0")
```

它沒有套件引擎副本、相鄰 path dependency 或 Reader 原始碼；Package.resolved 只含 YueduCoreText 0.3.0 與 SwiftSoup 2.13.7。五項 public-only 測試涵蓋 HTML/CSS → 分頁與連續排版 → bitmap、圖片／背景／邊框像素、UTF-16/source/link/selection geometry、reflow、unsupported、資源失敗及取消生命週期。

## CI 已知失敗

GitHub Actions 使用 Xcode 16.4。0.3.0 能編譯，但 Typography 的 `punctuationStillCompressesWhenSafe` 在該 SDK 得到 `kern == -20`，不符合原測試的 `kern > -20`；因此不能宣稱 CI 全綠。0.2.1 原有 CI 已出現完全相同的測試與數值，本輪未修改標點演算法或放寬 assertion。

- [0.3.0 CI](https://github.com/CHANG-JUI-LIN/YueduCoreText/actions/runs/34691996249)
- [0.2.1 原有失敗](https://github.com/CHANG-JUI-LIN/YueduCoreText/actions/runs/30687257480)

本機 128 項通過不等於 Xcode 16.4 全部通過。此差異已寫入 GitHub Release notes，後續需獨立處理；本輪不宣稱真機 Release 效能、耗電或所有 CSS/EPUB 能力。

## 執行命令

以下從實際 log 擷取；摘要見 [release-0.3.0-verification.json](release-0.3.0-verification.json)。Consumer 命令在上述 RemoteConsumer 目錄執行，其餘在對應正式 checkout 執行。

### package-final

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -scheme YueduCoreText-Package -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO -resultBundlePath /tmp/yuedu-engine-release/package-final.xcresult test
```

### app-remote

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutPageEngineTests" "-only-testing:yuedu appTests/BrowserScrollDocumentTests" "-only-testing:yuedu appTests/BrowserLayoutInlineFormattingContextParityTests" "-only-testing:yuedu appTests/BrowserLayoutSessionTests" "-only-testing:yuedu appTests/BrowserReaderParityTests" "-only-testing:yuedu appTests/BrowserTextInteractionTests" "-only-testing:yuedu appTests/EPUBAutoRoutingTests" "-only-testing:yuedu appTests/YueduCoreTextMigrationTests" "-only-testing:yuedu appTests/NavigationBackSwipeReservationTests" "-only-testing:yuedu appTests/DetailReaderStackTests" -resultBundlePath /tmp/yuedu-engine-release/app-remote.xcresult test
```

### consumer-remote-build

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -scheme YueduCoreTextConsumer -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO build-for-testing
```

### consumer-remote

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -scheme YueduCoreTextConsumer -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO -resultBundlePath /tmp/yuedu-engine-release/consumer-remote.xcresult test-without-building
```

不取得 Yuedu Reader 原始碼，只取得已發布 YueduCoreText 及其正式依賴，可以從 HTML + CSS 獨立完成排版、分頁與繪製；遠端 consumer 的 5/5 測試為本次直接證據。
