# YueduCoreText 0.5.0 發布與 Reader 正常建置

2026-09-13，補齊英文 EPUB 修正的跨 repo 發布與整合。

- 引擎修正 commit：`339b6ff`。
- 發布文件與 tag 指向：`1bbe08accd9342cfdd68cc27c26bcb9f79c6a89b`。
- [正式 Release 0.5.0](https://github.com/CHANG-JUI-LIN/YueduCoreText/releases/tag/0.5.0)。繁中、簡中、英文 README 已更新安裝版本與支援說明，CHANGELOG / migration notes 已更新。
- [GitHub CI](https://github.com/CHANG-JUI-LIN/YueduCoreText/actions/runs/34752718752) success；套件與獨立 consumer 都通過。
- Reader `XCRemoteSwiftPackageReference` 改為 `upToNextMinorVersion / 0.5.0`。由正常 Xcode 解析生成 `Package.resolved`，只有 YueduCoreText pin 從0.4.0升到0.5.0及上述 SHA；其他依賴未升級。

## 正常專案驗證

使用 `Yuedu-Reader.xcodeproj`，不使用本機 engine workspace。log 明確記錄 `YueduCoreText: https://github.com/CHANG-JUI-LIN/YueduCoreText @ 0.5.0`。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export YUEDU_DEST=id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination "$YUEDU_DEST" \
  -resultBundlePath /tmp/yuedu-english-typography/released-normal-build.xcresult build
bash scripts/xctest.sh -l /tmp/yuedu-english-typography/released-normal-corpus.log -- \
  -resultBundlePath /tmp/yuedu-english-typography/released-normal-corpus.xcresult \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests'
```

工具鏈為 Xcode 27 beta / iOS Simulator 27.0 / iPhone 17 Pro。build exit 0，`BUILD SUCCEEDED`。完整紀錄：`/tmp/yuedu-english-typography/released-normal-build.log`。

原書回歸通過：1項參數化測試、2本原書案例，`TEST SUCCEEDED`，wrapper exit 0。測試直接經 Reader 正常 `EPUBPageRenderer.load`，驗證兩書指定章節的 Browser 翻頁與連續捲動入口，沒有用 demo 代替 App 接線。

初次正常建置的0.4.0錯誤仍保存於 `normal-project-build.log/.xcresult`，本次是發布相容 API 與升級真實依賴後通過，沒有撤掉新 scanner 呼叫或改用 legacy 掩蓋。
