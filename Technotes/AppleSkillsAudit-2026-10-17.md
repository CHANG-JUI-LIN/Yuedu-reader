# Apple 官方 skill 全域掃描（2026-10-17，commit 270c7a33）

來源：`xcrun agent skills export` 導出的 10 個 skill，已裝到 `~/.agents/skills/`，`~/.claude/skills/` 放 symlink。
方法：7 個唯讀掃描員各負責一組 skill，逐條讀完 SKILL.md 與 references 後掃 `Modules/ Targets/ Widget/ ShareExtension/ Tests/ Packages/`。未跑 xcodebuild、未開模擬器、未改任何檔。
可信度標記：【已核對】= 我自己讀過原始碼或 pbxproj 確認；【報告】= 掃描員的結論，尚未逐條核對；【待實測】= 需要模擬器／Instruments／真機。

## 一、先修（有實質後果）

1. 【已核對】Swift 語言模式是 5，且 `xcconfig/Yuedu-reader_common.xcconfig` 是死設定。
   `project.pbxproj` 10 處（5 個 target × Debug/Release）都是 `SWIFT_VERSION = 5.0`；`Yuedu-reader_common.xcconfig`（寫著 `SWIFT_VERSION = 6.0`、`ENABLE_MODULE_VERIFIER = YES`）從未被 pbxproj 引用，只有 `version.xcconfig` 是 base configuration。
   CLAUDE.md 的「Swift 6.0」可以讀成工具鏈版本，所以我不說它寫錯，只說明實際的語言模式是 5；是否要在 CLAUDE.md／AGENTS.md 加註，由你決定（我沒改）。
   不要把 common.xcconfig 直接接上：會把全專案切到 Swift 6 語言模式。要嘛刪掉，要嘛改寫。
   【報告】併發債：755 個 `@MainActor`、65 個 `@unchecked Sendable`；app 沒設 `SWIFT_STRICT_CONCURRENCY`。

2. 【已核對】`INFOPLIST_KEY_UIRequiresFullScreen = YES`（pbxproj:837、891，Debug＋Release），沒有 `UIRequiresFullScreenIgnoredStartingWithVersion`。
   app-resizability skill 原文（`SKILL.md:70`）：「iOS 27 ignores it and resizes the scene anyway」，是以 OS 版本陳述，沒有說明是否與建置用的 SDK 有關。本專案以 27.1 SDK 建置，保守地當作 iOS 27 裝置上已經生效。
   skill 的護欄（`SKILL.md:72`）：不要刪除 `UIRequiresFullScreen`（刪除會立刻變成可縮放，版面可能還沒準備好）；不要自己加 `…IgnoredStartingWithVersion`（它的值決定哪些版本保留舊行為，是開發者的決定）；要等 app 處理好縮放並實際縮放驗證後才拿掉。
   閱讀器尺寸訊號有三處根因：
   - 【已核對】`ReaderView.swift:154`、`EPUBPageRenderer.swift:382` 以 `UIScreen.main.bounds.size` 當初值；【報告】這讓 `width > 0` 的延後啟動路徑永遠走不到。
   - 【已核對】`ReaderView.swift:2049` 重新取尺寸只由 `UIDevice.orientationDidChangeNotification` 觸發；視窗拖曳、Split View、摺疊都不會發這個通知。
   - 【報告】TXT／Markdown 欄寬取自螢幕（`TXTLazyAttributedStringBuilder.swift:116,177`）；漫畫／PDF 目標寬度安裝時凍結（`FixedPageReaderViewController.swift:226`）；捲動模式圖片高度取螢幕（`CoreTextScrollEngine.swift:937`）。
   - 【報告】單視窗外殼：`yuedu_appApp.swift` 的 `.onAppear` 每開一個視窗跑一次；`ReaderOrientationController.shared` 是全程序單例；多處 `connectedScenes.first`。
   結論：目前不具備摺疊 iPhone／視窗化 iPad 的就緒度。修法方向是由閱讀器自己的 view 回報尺寸（`viewDidLayoutSubviews`／`onGeometryChange`），不是換成 `effectiveGeometry.interfaceOrientation`。

3. 【已核對】Widget 的畫面文字與 VoiceOver 文字全寫死繁體中文（`Widget/DownloadLiveActivityWidget.swift:146` "繼續下載"／"暫停下載"、`:171` spokenSummary、`YueduWidget.swift:91` "尚無閱讀記錄"）。`Widget/` 目錄沒有任何 `.lproj`，`ShareExtension/` 有五個。【報告】檔內註解稱 Widget 無法取得 `Resources/*.lproj`，但同步資料夾機制可直接收 `Widget/<lang>.lproj`。違反 CLAUDE.md 本地化規則，且 en/ja/ko 的視障使用者聽到中文。

4. 【已核對】測試在 fixture 不存在時靜默通過：`yuedu_appTests.swift:357` 起的 `guard hasBookSourceFixture else { return }`（我用單一 pattern 數到 11 行；掃描員用較寬的 pattern 報 27 行／6 檔）。沒有 fixture 的機器上這些測試顯示為通過。應改 `.enabled(if:)` 或 `Test.cancel`。【報告】另有 42 個檔寫死 `/Users/zhangruilin` 路徑。

5. 【形狀已核對，影響待量測】閱讀器目錄搜尋：`ReaderTOCViews.swift:399` 每一列都呼叫 `filteredChapters.first?.id`，而 `filteredChapters`（`:223`）是計算屬性，每列重跑全章過濾，成本形狀是 可見列數 × 章節數。尚無毫秒數；依專案規則，改之前先用 `SourcePerfTrace` 量搜尋輸入的前後時間。修法方向：`body` 開頭算一次，把 `firstID` 當參數傳入。

6. RSS／OPML 匯出（【報告】，尚未逐條核對）：
   - 規則／正確性問題（可直接修）：
     - `RSSListView.swift:1312` `(try? export(...)) ?? Data()` 靜默匯出空檔；兩個匯出器收尾都是 `{ _ in }`。違反「不吞錯誤」。
     - OPML 以 `.xml` 型別匯出但檔名 `.opml`，匯入端用 `org.opml.opml`（`RSSOPMLDocument.swift:6`、`RSSListView.swift:266` vs `:1046`）。
   - 效能疑點（先量測再改）：`RSSListView.swift:265,277`、`ReaderCommentBubbleSettingsView.swift:114` 的 FileDocument 在 modifier 引數內建構，每次 body 重算都重新排序並整份重新編碼（包含進度條每次更新）。範本：`AIStatusView.swift:11,108`。

7. 【報告】Info.plist 有 `CFBundleTypeName` 與 9 條 `UTTypeDescription` 在五個 `InfoPlist.strings` 都沒有 key；`scripts/check_localizations.rb` 不檢查這部分，intent 內的字面量也逃過它。`CFBundleDocumentTypes` 單一 dict 全為 `LSHandlerRank=Alternate`，連自己匯出的 `app.yuedu.reader-style` 也是。

8. 【已核對】文件漂移：CLAUDE.md:36 的方法層級範例 `-only-testing:'yuedu appTests/CoreTextWritingModeTests/testVerticalRTLPagination'` 已失效。`CoreTextWritingModeTests` 這個 suite 存在，但 `testVerticalRTLPagination` 在 `Tests/` 裡找不到（該 suite 已是 Swift Testing，方法名不再帶 `test` 前綴）。過期的範例會誤導之後的 session。我沒改 CLAUDE.md。

## 二、值得做（有量測再動手）

- 【已核對形狀】書架 `List`／`LazyVGrid` 的列是多視圖：`HomeView.swift:1088` `ForEach { Group { switch } }`、`:1200` 格狀裸 `switch`。修法要連動 `.tag`、`.moveDisabled`、`.selectionDisabled`，並重驗原生多選與兩指拖曳多選。
- 【已核對】3 個 `@Entry` 存閉包（`CoverTint.swift:157`、`BookshelfCoverArtwork.swift:199`、`LibraryHomePageView.swift:136`）；【報告】最新 build log 對這三處都有 "may invalidate dependents on every update" 警告。另有 `openPublicLibraryBooks`、`PublicLibrarySheetContext`。repo 內正確範本：`BookDetailCardChrome`、`searchTabNavigation`。先用 SwiftUI Instruments 量，再改。
- 【報告】`TTSSettingsView.swift:874-905`（`TTSSourceLoginView`）：`@State … = [:]` 與 init 內 `_fieldValues = State(initialValue:)` 並存。我確認了程式碼形狀；27.1 編得過，執行期是否仍顯示已存的 loginInfo 【待實測】。修法：刪掉 `:882`、`:885` 的預設值，iOS 17 安全。
- 【已核對】`RSSListView.swift` 的 `.swipeActions`（`:420,496,506`）所在的容器是 `ScrollView`（`:86`），不是 `List`，在 iOS 17–26 為死碼。【報告】iOS 27 可用 `.swipeActionsContainer()`；需維護者決定是否讓 27 與 17–26 行為分歧。
- 【報告】`AudiobookView.swift:455` 章節列表 `@ObservedObject` 整個播放器，`currentTime` 每拍發佈就重建整份列表。
- 【報告】`EPUBPageRenderer` 有 11 個 `@Published`，任一個發佈都讓 `ReaderView.buildBody()` 重跑；`buildBody() -> AnyView` 約 1200 行。均為【待實測】，先量 body 次數與毫秒。遷 `@Observable` 會弄壞測試中約 8 個檔的 `$isCoreTextReady.values` 與兩處 `$scrollEngine` sink。
- 【報告】`DownloadActivityIntent`：toggle 語意遇到過期的 Live Activity 會兩次點擊抵銷，建議改成帶目標狀態的 `setPaused: Bool`；`guard let defaults else { return }` 會在 App Group 不可用時回報成功。不可改型別名。App 與 Widget 兩份 intent 檔相同但無防漂移機制。
- 【報告】安全設定採用順序（零風險到有風險）：A. 處理死 xcconfig；B. app 設 `SWIFT_STRICT_CONCURRENCY=targeted` 只量測；C. `ENABLE_ENHANCED_SECURITY=YES` + app 的 4 個 entitlement；`ENABLE_POINTER_AUTHENTICATION` 必須明設 NO（9 個 Firebase 二進位 xcframework 只有 arm64）；D. `platform-restrictions-string` 單獨一步並先在實機驗 Crashlytics；E. 硬體記憶體標記。`ENABLE_USER_SCRIPT_SANDBOXING=NO` 維持，並記為刻意。
- 【報告】測試：已 99.3% 是 Swift Testing（5,298 個 `@Test`，37 個單元 XCTest 方法）。剩餘可機械遷移的只有 `ReaderAIPresentationTests`、`FixedPageReaderBarAppearanceTests` 等少數；價值更高的是修已遷測試的寫法（29 處 `#expect(x != nil)` 後接 `x!` 應改 `try #require`；4 處 catch 內 `Issue.record`；參數化重複測試約 24 組）。XCTAttachment 的對應與 `.timeLimit` 最小 1 分鐘都需先驗證。

## 三、不要照做（與專案規則或平台底線衝突）

- 不採用 iOS 27 的 `Document` 協定：僅 iOS 27、本 app 只做一次性匯出，雙路徑違反「一件事一條路徑」。
- 不整批替換 `.foregroundColor`（341）、`.cornerRadius`（10）、`navigationBarLeading/Trailing`（22）等軟棄用 API：`.agents/skills/yuedu-swift/references/swiftui.md:84` 規定只在改到那一行時順手換。`NavigationView` 與單參數 `onChange` 均為 0。
- 不把 `Array(x.enumerated())` 的 `Array` 拿掉：`EnumeratedSequence: Collection` 是 iOS 26+。
- 不把 `localized("Key")` 改成 `Text("key")`／`LocalizedStringResource`：專案慣例；intent 內的字面量用 zh-Hant 原文且要補五語 key，並擴充 `check_localizations.rb`。
- 不把 `.tabItem`／`TabView(selection:content:)` 換成 `Tab`，不動 `stableSlotsTabView`（iOS 17 底線＋專案規則）。
- 不為 `-fbounds-safety` 動 `Packages/CLexbor`：63k 行供應商生成碼、單一編譯單元、被 SHA-256 鎖定；且 production 程式沒有任何 import（僅 4 個測試檔）。
- 不用 `AsyncImage(request:)`／`asyncImageURLSession` 取代 `BookCoverLoader`：會產生第二條圖片路徑。【報告】唯一要留意的是頭像：`AccountAvatarImage.swift:118` 的 Storage 物件 URL 不變，AsyncImage 預設快取後第二台裝置可能在 Cache-Control 到期前看到舊頭像【待實測】。
- 不把 `AppThemesKey` 改成 `@Entry`（`UITraitBridgedEnvironmentKey`）。
- 不採用 SwiftUI 27 參考文件中的 `toolbarMinimizeBehavior`：SDK 27.1 實名是 `toolbarMinimizationBehavior`，`RootTabTitle.swift:153` 已用對。
- 14 處 `List.onMove` 改 `reorderable()`、約 30 處 `confirmationDialog`／`alert` 的 item 版本：沒有使用者可見收益，逐處加 gating 只會多出分支。

## 四、機會（要維護者決定）

1. 「繼續閱讀」App Shortcut（無參數 `AppIntent`，Siri／Spotlight／動作按鈕）。【報告】估 2–3 天；`BookStore` 是 `@StateObject`、非 Sendable，不能當 `@Dependency`，需用 Sendable 持有者；須套用 `TestFlightAccessController.allowsUse` 閘門。對視障／語音控制使用者價值最高。
2. 探索首頁編輯卡片排序改 `.reorderable()`（`HomeEditor.swift:106-113`，iOS 27 分支）。
3. 書架格狀視圖目前任何 OS 都不能手動排序，而預設排序是手動；iOS 27 可用 `reorderable()`，`BookStore.moveBooks(ids:before:)` 可直接對應。資料夾因 `ShelfEntry` 非 Transferable 會彈回。

## 五、掃描限制

- 全是 regex／grep 加讀碼，沒有執行期驗證；所有「影響大小」來自讀碼，沒有毫秒數。
- 未涵蓋：`Packages/` 除 CLexbor 外、`.worktrees`、`legado-*`、外部 `YueduCoreText` 套件、伺服器端（`firestore.rules`、`functions/`、`gateway/`）、網路／ATS／簽署。
- `device-interaction` 為工作流程類 skill，依賴 Xcode 的 `DeviceInteraction*` 工具，此 session 沒有這組工具；其「重試一次、稍後再抓」的建議也與專案「不准計時等待」規則有張力，使用時以專案規則為準。
- 79 處 `ignoresSafeArea`、25 處 `GeometryReader` 未逐一檢視。
- 安裝位置：這 10 個 skill 裝在 `~/.agents/skills/`（Claude Code 經 `~/.claude/skills/` 的 symlink 讀取）。Codex 有自己獨立的 `~/.codex/skills/`（目前是 codex-primary-runtime、gh-*、imagegen、pdf、playwright 等），沒有指向 `~/.agents/skills/`，所以 Codex 不一定讀得到這 10 個；我沒動它。
