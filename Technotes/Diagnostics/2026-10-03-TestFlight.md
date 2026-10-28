# Xcode TestFlight 崩潰逐項處理（2026-10-03）

來源：直接操作 Xcode Organizer → Crashes；Last Year / All Versions / All Products / All Destinations / TestFlight，包含已解與未解分類，共 65 個。逐項選取下載原始 crash，核對 faulting thread、Last Exception Backtrace，並讀取有附加資訊的 Feedback。

Xcode 每分類下載的例子可能同時含 App Store；不能把所有本機 sample 都算成 TestFlight，也不能把分類標題當成根因。此次未按 Mark As Resolved。修復程式碼與模擬器回歸通過，不等於舊二進位或全部現場崩潰已消失。

目前統計：18 類列為本次修復或本次＋既有修復、22 類既有修復、4 類既有防護、1 類舊路徑退役、17 類未解、3 類部分處理。新修改涵蓋 10 條問題路徑；「部分處理」亦可能包含本次修復，但不把整個分類計為已解。每項的驗證限制以逐項台帳為準。

本機原始來源：`~/Library/Developer/Xcode/Products/com.zhangruilin.yuedureader/Crashes/Points/`。逐筆擷取 inventory 與測試 log：`/tmp/yuedu-tf-crashes-20261003/`。報告僅保留分類識別碼，不複製測試者身分或裝置識別資訊。

## 變更與限制

- [x] 新增 Swift Testing 回歸涵蓋 EPUB 真實 ZIP/spine、scalar JSON、JS bytes、正則輸出、UIKit diffable rows、並行 diagnostics、MainActor 匯入、curl 邊界與 AI 整理舊控制項。
- [x] 唯一新增章節內容回退：regex 輸出超過 `max(原文 UTF-16 長度, 8 Mi UTF-16 units)` 時，不套用該條規則、保留原文並記錄錯誤；正常規則維持 Foundation replacement semantics。此界線避免單次擴張耗盡記憶體，並未宣稱解決所有 regex CPU 或其他 OOM。
- [x] AI 整理的控制項在 proposal 移除後仍可能被 UIKit 讀取；以已呈現快照回應讀取、忽略遲到寫入。此行為僅限 group/move ID 已不存在時，保留在控制項生命週期能保證早於 proposal 結束前。
- [x] 無效或過大的 JS byte 陣列回傳失敗並留下 lastError；有效 Java signed bytes 與 base64 行為保留。
- Organizer Archives 起初顯示 No Archives。後由 Xcode Report Navigator → Cloud → main → build 107 → Archive - iOS → Artifacts 下載封存，dwarfdump 確認 UUID `9DBD5FAD-1359-36D1-9DD0-E6B908D32822` 完全吻合；atos 還原為 `JSCoreEngine.extractBytes` → `evaluateBytes`，納入本次 byte decoder 修復。build 90 尚缺精確 dSYM；Xcode Cloud main 清單可見最近 20 筆（112...93），navigator 搜尋 90 無結果。未用其他版本 offset 猜測。

## 驗證

Xcode 27.0 (27A266a)、Swift 6.4、iPhone 18 Pro Max／iOS 27.0 Simulator。所有類別各自以 `scripts/xctest.sh` 執行，`-parallel-testing-enabled NO`；正常 `Yuedu-Reader.xcodeproj` 編譯成功，共 **77 項測試通過**。最後一輪新增測試使用 `final-regression.log`，涵蓋最後的相關程式碼修改。

| 測試類別 | 測試數 | 結果 | Log（同上本機目錄） |
|---|---:|---|---|
| `TestFlightCrashRegressionTests` | 12 | ☑ 通過 | `final-regression.log` |
| `AIBookshelfOrganizerTests` | 7 | ☑ 通過 | `AIBookshelfOrganizerTests.log` |
| `ReaderPresentationContractTests` | 18 | ☑ 通過 | `ReaderPresentationContractTests.log` |
| `HostedCollectionListTests` | 3 | ☑ 通過 | `HostedCollectionListTests.log` |
| `ReaderAISourceIdentityTests` | 1 | ☑ 通過 | `ReaderAISourceIdentityTests.log` |
| `HTMLStylesheetCacheTests` | 5 | ☑ 通過 | `HTMLStylesheetCacheTests.log` |
| `ReaderDetailNavigationTests` | 11 | ☑ 通過 | `ReaderDetailNavigationTests.log` |
| `ReaderStackWriteGateTests` | 11 | ☑ 通過 | `ReaderStackWriteGateTests.log` |
| `UIColorP3ConversionTests` | 2 | ☑ 通過 | `UIColorP3ConversionTests.log` |
| `AppearanceCustomizationBundleTests` | 7 | ☑ 通過 | `AppearanceCustomizationBundleTests.log` |

- Curl 邊界的 LTR、RTL 兩個案例於修正前都失敗（`curl-before.log`），修正後兩者通過。
- 一次建置受到另一個工作占用的 `build.db` 鎖影響，執行 0 項，不列入驗證。之後以 `/tmp/Yuedu-TFCrashDerivedData` 隔離建置輸出，重用同一份 pinned SourcePackages；程式碼始終在原工作區，後續均使用同一個輸出目錄增量編譯。
- `git diff --check`、app plist 與三語 InfoPlist.strings 的 `plutil -lint` 通過；`scripts/check_localizations.rb` 通過（5 files／3251 keys）。
- 回歸驗證涵蓋各條已修程式路徑；未取得原始輸入／精確符號的項目保留未解。沒有把 Xcode 分類標成線上已解。


## 65 分類逐項台帳

勾選表示該列已列為「本次修復／補修」或「既有修復」的程式碼處理完成；驗證範圍與限制仍以該列說明為準。未解、部分處理、僅有防護及證據不足的分類保留未勾選，不代表在 Xcode 標記線上已解。

| # | 已修 | Xcode classification ID / title | 下載樣本中的 TF 版本 | 狀態與根因 |
|---|:---:|---|---|---|
| 1 | ☐ | `Cp7q1xgqRsQ0Jd3xmmgR1-`<br>`AnimationKit: 0x1b4fa9000 + 234748` | 2.0.2 (70) | **未解**：記憶體損毀／無效指標在 allocator、Crashlytics 檔案或 CFNetwork timer 被發現；堆疊無法指出第一次破壞記憶體的寫入者。同份報告另有 SwiftSoup Attributes.ensureMaterialized／query-index 執行緒，與舊共用 DOM 競爭相符，但仍需 sanitizer 或相同輸入證明首次破壞者，不能把偵測者當成根因。 |
| 2 | ☐ | `4J0ji5llmArIErTJaXj8e`<br>`AttributeGraph: AG::precondition_failure(char const*, ...) + 216` | 1.0.6 (1) | **未解**：AttributeGraph／SwiftUI display-list 配置失敗；缺少發生前的記憶體分配歷程，無法歸因某個 App 資料集合。 |
| 3 | ☐ | `C4wXLBpemm9lLEvJH8ZqIr`<br>`AttributeGraph: AG::precondition_failure(char const*, ...) + 228` | 2.0.6 (92) | **未解**：AttributeGraph reusable style 的 indirect attribute precondition；只有系統 layout/reuse 堆疊，尚無可重現畫面／App frame。 |
| 4 | ☑ | `5_WNNhLMzKrK21eCq5J0c`<br>`CloudKit: -[CKRecord initWithCoder:] + 1848` | 2.0.5 (84) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 5 | ☑ | `d-FfdX2NJ2Azt5qgA-NZC`<br>`CollectionViewCore: -[_UIDiffableDataSourceUpdate initWithIdentifiers:sectionIdentifiers:action:desinationIdentifier:relativePosition:destinationIsSection:] + 508` | 2.0.7 (106) | **本次修復**：HostedCollectionList 將重複 Item 當成 diffable snapshot 的相同 ID；改成 Item + occurrence，保留每一列並測試重排／縮減／清空。 |
| 6 | ☑ | `BU1UPoKf5EYL2QPXkfy6QF`<br>`CoreAutoLayout: 0x1a8f72000 + 22216` | 2.0.6 (92) | **本次修復**：主題套件匯入跨 await 後更新圖片／介面；兩個匯入入口明確隔離到 MainActor。 |
| 7 | ☑ | `Bv7m6blysCW_mfvGLM_aPN`<br>`CoreGraphics: argb32_mark_constshape + 1476` | 2.0.4 (82) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 8 | ☐ | `EfkAjyGCmkD3UJIVZJlLF`<br>`CoreServicesInternal: _FileCacheLock(__FileCache const*) + 20` | 1.10 (28) | **未解**：記憶體損毀／無效指標在 allocator、Crashlytics 檔案或 CFNetwork timer 被發現；堆疊無法指出第一次破壞記憶體的寫入者。需要可重現輸入或 sanitizer 證據，不能把偵測者當成根因。 |
| 9 | ☑ | `3JjjWeYSM0C4ke_BjJGgE`<br>`JavaScriptCore: forEachMethodInProtocol(Protocol*, bool, bool, void (objc_selector*, char const*) block_pointer) + 60` | 2.0.6 (100) | **本次修復**：java.ajaxAll 可同時改寫 lastJSNetworkExchange，導致舊 optional value 重複釋放；Sendable store 以 OSAllocatedUnfairLock 包住完整快照的讀寫／清空。 |
| 10 | ☐ | `BmbakLev1RZHs-0bxCiFMK`<br>`JavaScriptCore: scavenger_thread_main + 1632` | 2.0.2 (70) | **部分處理**：TF 的 SwiftSoup Attributes 競爭已有 thread-local JsoupDocumentCache 修復（197dc070）；同分類的 App Store 樣本另含 SelectorQueryStats allocation failure，不能合併結案。 |
| 11 | ☐ | `r4yAIoO9Yxkc6qmSjWhJh`<br>`QuartzCore: CA::Render::Encoder::receive_reply(unsigned int) + 60` | 2.0.4 (82) | **未解**：實際在 CoreText GetGlyphs／justification／CTFramesetterCreateFrame 讀取失效資料。缺觸發 EPUB 與輸入 attributed string；不能僅因已有 CTRunDelegate 修復便宣稱同因。 |
| 12 | ☑ | `1qRrlrb_O2Ktwzn_8gsOl`<br>`SwiftUI: 0x1a6a30000 + 24726200` | 2.0.6 (100)、2.0.7 (101) | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 13 | ☑ | `7Dj5Z_9N-IjdV3f2TtpSA`<br>`SwiftUI: GraphHost.isValid.getter + 28` | 2.0.6 (100) | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 14 | ☐ | `DwOyEIvSbZORwsb8_YWJCE`<br>`SwiftUI: specialized _ArrayBuffer._consumeAndCreateNew(bufferIsUnique:minimumCapacity:growForAppend:) + 104` | 1.10 (28) | **未解**：AttributeGraph／SwiftUI display-list 配置失敗；缺少發生前的記憶體分配歷程，無法歸因某個 App 資料集合。 |
| 15 | ☑ | `Bs-9qA1O-Y-bfXsUqfr6by`<br>`SwiftUICore: Binding.wrappedValue.getter + 8` | 2.0.7 (106)、2.0.7 (111)、2.0.7 (112) | **本次修復**：Xcode Feedback 明確指出「AI 整理書架後點擊套用閃退」。reset 清空 proposal，存活的 Toggle 仍讀陣列 Binding。改成 UUID group identity + ID 讀寫，測試 apply/reset/新提案後舊 Binding 的讀寫。 |
| 16 | ☑ | `CNSfRBPNS2G8hOyVy3wUJC`<br>`SwiftUICore: GraphHost.Data.invalidate() + 32` | 2.0.6 (100) | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 17 | ☑ | `C1E0VxTHf58Y_WSHEw1dB_`<br>`SwiftUICore: GraphHost.isValid.getter + 20` | 最近下載例子僅 App Store | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 18 | ☐ | `BEoDsasGHmVc-QP5JsDDeb`<br>`SwiftUICore: SDFStyle.distanceRange.getter + 104` | 2.0.6 (100)、2.0.7 (111) | **未解**：SwiftUICore SDFStyle.distanceRange Range trap，含 build 111，兩筆均 iOS 26.2 (23C55)。沒有 App frame 或參數證據；不可臆測移除 shadow/glass 元件。 |
| 19 | ☑ | `BaecaB39bF25mMSsZ73sH`<br>`SwiftUICore: specialized GraphHost.asyncTransaction<A>(_:id:invalidating:style:mayDeferUpdate:) + 24` | 最近下載例子僅 App Store | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 20 | ☑ | `D4BZ7P-uzOXi9M94B-qycZ`<br>`SwiftUICore: specialized GraphHost.asyncTransaction<A>(_:id:mutation:style:mayDeferUpdate:) + 112` | 2.0.6 (100) | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 21 | ☑ | `CladrctqjSBnoa4XJW-9my`<br>`SwiftUICore: specialized GraphHost.asyncTransaction<A>(_:id:mutation:style:mayDeferUpdate:) + 140` | 2.0.6 (100) | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 22 | ☑ | `DS-6UwTqicOaYNGzjr9mrz`<br>`SwiftUICore: specialized GraphHost.asyncTransaction<A>(_:id:mutation:style:mayDeferUpdate:) + 144` | 最近下載例子僅 App Store | **既有修復**：ReaderNavigationCoordinator 在 dismantle 期間發布 SwiftUI 狀態；目前由 owner/generation 管理拆卸後發布。回歸：ReaderDetailNavigationTests。 |
| 23 | ☑ | `CiV1v7gCu6NsFDbryQXoVS`<br>`TCC: __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__ + 172` | 2.0.6 (100) | **本次修復**：TCC 原始紀錄指出缺 NSPhotoLibraryAddUsageDescription；補 app plist 與三語 InfoPlist.strings，測試 built app 的實際 key。 |
| 24 | ☐ | `C_EkbUwmeMafpy3H9sgL-k`<br>`UIFoundation: __NSCoreTypesetterCreateBaseLineFromAttributedString + 872` | 最近下載例子僅 App Store | **未解**：UIFoundation typesetter 在 CFRelease 觸發無效物件；本機下載樣本為 App Store，尚缺可定位 App 的輸入／frame。 |
| 25 | ☐ | `BEi0_Enk3raqMzcQ0Hcxh1`<br>`UIKitCore: +[_UIBarInsertLayoutData updateLayoutParameters:overflowLayout:forAvailableHeight:] + 128` | 1.10 (28) | **未解**：iOS 17.7.2 (21H221) 的 UINavigationBar／refresh-control layout 遞迴，512 frames 重複 updateLayout → resize → observeScrollView，VM 明示 STACK GUARD（stack overflow）。沒有 App frame，Feedback 無描述；尚缺觸發頁面與操作。現有 inline title 規範不足以證明根因已排除。 |
| 26 | ☐ | `wS7kp73XfZA0BfdWki9in`<br>`UIKitCore: -[UIEventFetcher threadMain] + 408` | 1.10 (35) | **未解**：記憶體損毀／無效指標在 allocator、Crashlytics 檔案或 CFNetwork timer 被發現；堆疊無法指出第一次破壞記憶體的寫入者。需要可重現輸入或 sanitizer 證據，不能把偵測者當成根因。 |
| 27 | ☑ | `C58bWLYG9-OZZTtKR4sx8b`<br>`UIKitCore: -[UIImageView _mainQ_beginLoadingIfApplicable] + 76` | 2.0.6 (92) | **本次修復**：主題套件匯入跨 await 後更新圖片／介面；兩個匯入入口明確隔離到 MainActor。 |
| 28 | ☑ | `ate4jhw57KkkSQWlfeP5E`<br>`UIKitCore: -[UIPageViewController _validatedViewControllersForTransitionWithViewControllers:animated:] + 396` | 1.10 (28) | **本次修復**：雙面 curl 在最後一頁提供紙背，但下一個正面為 nil。先判斷目的頁存在再提供紙背；LTR/RTL 邊界測試修改前皆失敗。這修復已重現的資料來源缺口，仍需新版本線上確認所有樣本是否同因。 |
| 29 | ☑ | `BpYvVviY0AhMvwtZMlipI3`<br>`UIKitCore: -[UIPageViewController _validatedViewControllersForTransitionWithViewControllers:animated:] + 404` | 1.10 (35)、2.0.5 (84) | **本次修復**：雙面 curl 在最後一頁提供紙背，但下一個正面為 nil。先判斷目的頁存在再提供紙背；LTR/RTL 邊界測試修改前皆失敗。這修復已重現的資料來源缺口，仍需新版本線上確認所有樣本是否同因。 |
| 30 | ☑ | `Be6NTjXAy2cct65wnf-LCS`<br>`UIKitCore: -[UIPageViewController _validatedViewControllersForTransitionWithViewControllers:animated:] + 416` | 1.0.9 (20)、2.0 (38)、2.0 (39) | **本次修復**：雙面 curl 在最後一頁提供紙背，但下一個正面為 nil。先判斷目的頁存在再提供紙背；LTR/RTL 邊界測試修改前皆失敗。這修復已重現的資料來源缺口，仍需新版本線上確認所有樣本是否同因。 |
| 31 | ☐ | `DV551rhJOVNm3DF5ZbtVOt`<br>`UIKitCore: -[UIPageViewController queuingScrollView:didEndManualScroll:toRevealView:direction:animated:didFinish:didComplete:] + 804` | 1.0.9 (23) | **既有防護**：UIPageViewController scroll 完成時斷言；目前 ReaderStackWriteGate 避免 delegate unwinding 時重設 stack。回歸僅證明 gate 行為，未重現現場完整手勢。 |
| 32 | ☐ | `CU9dZahhhvp6CtSzU-WPsA`<br>`UIKitCore: 0x18e4e8000 + 12119884` | 1.0.9 (23) | **未解**：UIKitCore 只有映像位址與 offset。需 iOS 27.0 (24A5370h)、UUID 2F9B0DF4-C807-326A-9636-6E978B5AD46A 的 UIKitCore 符號；其他本機報告同 UUID 未提供這些 offset 的函式；本機 DeviceSupport 僅找到 iOS 27.2 的 UIKitCore（UUID 0042B2F3-5FB3-3E5D-A587-3F3CC33D2819），不吻合。不能用其他版本或附近分類猜為相同 curl 例外。 |
| 33 | ☑ | `NNRfOcsM_d9k8zoeRRLID`<br>`UIKitCore: 0x190b70000 + 4039160` | 2.0.5 (84) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 34 | ☑ | `DF1FHSw6BaHyeQYZQP1wN7`<br>`UIKitCore: _UIPerformVoidSelector1 + 32` | 2.0.6 (95)、2.0.7 (107) | **本次修復**：雙面 curl 在最後一頁提供紙背，但下一個正面為 nil。先判斷目的頁存在再提供紙背；LTR/RTL 邊界測試修改前皆失敗。這修復已重現的資料來源缺口，仍需新版本線上確認所有樣本是否同因。 |
| 35 | ☑ | `BqOHdSOAXf_PmyS7QWYFpy`<br>`UIKitCore: closure #1 in InProcessAnimationManager.processPostTicksDelayIfNecessary(time:) + 8` | 2.0.6 (100) | **本次修復**：AI 全書文字擷取把導航 TOC 序號當成 spine；改用固定 spine 章節集合，資源讀取明確拒絕越界。 |
| 36 | ☐ | `BAd9Wdm9RkMb61rXuHjDln`<br>`UIKitCore: static UIView.collectedViewPresentationProperties(action:) + 68` | 2.0.6 (100) | **未解**：UIKit UIView.collectedViewPresentationProperties 的 nil unwrap；沒有 App frame 或可確認的轉場參數。 |
| 37 | ☐ | `CwXST--4t6aNjjNjtNrjeb`<br>`YueduReader: <deduplicated_symbol> + 432` | 2.0.5 (90) | **未解**：ColorPicker setter 進入 App deduplicated symbol；缺 build 90 UUID 1CBD50EA-B631-3205-B922-5DBFB5A94529 的 dSYM。不能以 P3 或舊 theme binding 修復代替精確符號化。 |
| 38 | ☑ | `C1J7hrMZ1qz2vKOm4tiSR4`<br>`YueduReader: AnalyzeUrl.init(ruleUrl:key:page:speakText:speakSpeed:sourceHeader:baseUrl:source:book:chapter:jsEvaluator:) + 16` | 2.0.2 (69) | **本次修復**：AnalyzeUrl 對 scalar JSON body 呼叫 Foundation serialization，引發不可捕捉的 ObjC exception；啟用 fragmentsAllowed。 |
| 39 | ☑ | `CmhMmjxvyI0V9CPdxz_Xpk`<br>`YueduReader: AnalyzeUrl.parseOptions(_:) + 2644` | 2.0.7 (104) | **本次修復**：AnalyzeUrl 對 scalar JSON body 呼叫 Foundation serialization，引發不可捕捉的 ObjC exception；啟用 fragmentsAllowed。 |
| 40 | ☐ | `CzGIpFFNyvLH7zDnpRW3ww`<br>`YueduReader: BookSourceFetcher.fetchTOCPackage(tocUrl:source:runtimeVariables:onFirstPageReady:forceRefresh:) + 2192` | 2.0.5 (83) | **未解**：同一 TOC JSONEncoder allocation failure；現有實作雖已逐頁寫 raw HTML，但沒有該書源回應／記憶體歷程，不能證明序列化峰值已排除。 |
| 41 | ☐ | `DlPj7qKXtgur1lU_8qcSug`<br>`YueduReader: BookStore.persistPositionUpdateIfNeeded(bookId:updatedBook:force:) + 32` | 2.0.4 (82) | **未解**：BookStore.encodeBooksMetadata 的 JSONEncoder allocation failure；Feedback 提到下載書籍翻頁載入失敗，但未附書檔。需要當時書架 metadata／記憶體歷程，現有 progress write budget 僅降低頻率。 |
| 42 | ☑ | `DciAAZwTKkoYuPdcqg8OPW`<br>`YueduReader: CSSSelector.matches(element:parent:) + 20` | 2.0.4 (82) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 43 | ☐ | `BC2Gvgc0UWbHjwUQ7pvyUc`<br>`YueduReader: ChapterCacheRepository.cacheDir(for:) + 28` | 2.0 (41) | **既有防護**：舊 ReaderView.body 透過 currentChapterOverlayState 同步讀章節磁碟快取而在背景 SwiftUI stack overflow；目前 overlay 僅讀 readerViewModel 已有狀態，不再走該 I/O 路徑。未重現舊 stack overflow。 |
| 44 | ☑ | `wnEOkQWqcnkxI-SBUCTe`<br>`YueduReader: CoreTextPageView.defaultSelectionRange(around:in:) + 12` | 2.0 (37) | **既有修復**：段落前後有 emoji/non-BMP 時把 UTF-16 surrogate 強制轉 UnicodeScalar；目前 paged/shared selection 都以 guard let 停止 trim。程式碼核對，未取得原書完整手勢重現。 |
| 45 | ☑ | `aS7uEmqJMT1eywMDanCS3`<br>`YueduReader: CoverDecodeService.decodedIfRegistered(coverUrl:data:) + 1104` | 2.0.7 (104) | **本次修復**：封面 JS bytes 結果透過 toArray 遞迴 bridge 進 NSArray 時崩潰；改成逐索引有限數字解碼，拒絕稀疏／循環／非有限／超過 32 MiB 的陣列並保留診斷。 |
| 46 | ☐ | `BZV4BTFU7wMUACCII-FfG-`<br>`YueduReader: FIRCLSMachExceptionServer + 108` | 2.0.5 (83) | **未解**：同一 TOC JSONEncoder allocation failure；現有實作雖已逐頁寫 raw HTML，但沒有該書源回應／記憶體歷程，不能證明序列化峰值已排除。 |
| 47 | ☑ | `C6HO4KCS-heq5McdD7D7j5`<br>`YueduReader: HTMLStylesheetCache.parsedStylesheet(css:orderOffset:) + 312` | 2.0.5 (84) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 48 | ☐ | `Dx7ObiQ355YOx1ZVlB_nzk`<br>`YueduReader: NO_CRASH_STACK` | 2.0.6 (100)、2.0.7 (107)、2.0.7 (112) | **部分處理**：同一 NO_CRASH_STACK 同時包含：build 112/100 spine 越界（本次修）；build 100 系統 glass RingShadow Range trap（未解）；build 107 NSArray bridge 配置失敗（已用 Cloud archive 精確符號化為 JSCoreEngine.extractBytes:669，本次修）。 |
| 49 | ☑ | `FdT7PyN0gLwezCi2rs353`<br>`YueduReader: PublicationSession.chapterHTML(at:) + 1212` | 2.0.6 (100) | **本次修復**：AI 全書文字擷取把導航 TOC 序號當成 spine；改用固定 spine 章節集合，資源讀取明確拒絕越界。 |
| 50 | ☑ | `C2O6CE4YCP025-mKUULtUF`<br>`YueduReader: UIColor.rgbHex.getter + 336` | 2.0 (39) | **既有修復**：UIColor 的 extended/P3 通道直接轉 UInt32；目前轉換先限定 0...255。回歸：UIColorP3ConversionTests。 |
| 51 | ☑ | `BdoRatJHcRwkttw4YKxBO0`<br>`YueduReader: UIColor.rgbHex.getter + 348` | 2.0.2 (69) | **既有修復**：UIColor 的 extended/P3 通道直接轉 UInt32；目前轉換先限定 0...255。回歸：UIColorP3ConversionTests。 |
| 52 | ☑ | `C7oN3jQjfXYQLQNDEJZ7-o`<br>`YueduReader: UIColor.rgbHex.getter + 360` | 2.0.2 (70) | **既有修復**：UIColor 的 extended/P3 通道直接轉 UInt32；目前轉換先限定 0...255。回歸：UIColorP3ConversionTests。 |
| 53 | ☐ | `BRDjJSZ5IWrribqjr9rqkW`<br>`YueduReader: closure #2 in AppearanceThemeCustomizationView.themeBinding.getter + 212` | 2.0.6 (100) | **既有防護**：舊 AppearanceThemeCustomizationView 已由 AppearanceColorsAndFontView 取代；目前以 theme ID 查詢，找不到時讀取已呈現快照並忽略遲到寫入。未宣稱新二進位已消除現場事件。 |
| 54 | ☐ | `CdfuM4uIYeR5hav-J0CmiK`<br>`YueduReader: closure #2 in AppearanceThemeCustomizationView.themeBinding.getter + 248` | 2.0.5 (85)、2.0.6 (92) | **既有防護**：舊 AppearanceThemeCustomizationView 已由 AppearanceColorsAndFontView 取代；目前以 theme ID 查詢，找不到時讀取已呈現快照並忽略遲到寫入。未宣稱新二進位已消除現場事件。 |
| 55 | ☑ | `CjutwgVY_SGq3SfphrxXz0`<br>`YueduReader: gpr_cv_wait + 160` | 2.0.4 (82)、2.0.6 (100) | **本次及既有修復**：build 100 實際為 chapterHTML spine 越界（本次）；build 82 為 HTMLStylesheetCache 競爭（既有鎖）。分類標題 gpr_cv_wait 不是根因。 |
| 56 | ☑ | `pvlugScv_Dk9ySAG0O0Ik`<br>`YueduReader: pollset_work(grpc_pollset*, grpc_pollset_worker**, grpc_core::Timestamp) + 1408` | 2.0.4 (82)、2.0.5 (84) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 57 | ☑ | `27AZaWgUXYH2SLIMq1vrl`<br>`YueduReader: specialized Collection<>.split(separator:maxSplits:omittingEmptySubsequences:) + 36` | 2.0.4 (82) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 58 | ☑ | `BeMuGC1ayu6ah1w6pU1-KC`<br>`YueduReader: specialized Dictionary._Variant.isUniquelyReferenced() + 8` | 2.0.4 (82) | **既有修復**：實際 faulting thread 是 HTMLStylesheetCache 字典並行存取；目前查詢／寫入已有同一把鎖。回歸：HTMLStylesheetCacheTests。 |
| 59 | ☑ | `DVDYnJgC7utFCvohn1d-Wq`<br>`YueduReader: specialized JSCoreEngine.onJSQueue<A>(_:) + 120` | 最近下載例子僅 App Store | **既有修復**：JSCoreEngine.extractString 已改走 JS JSON.stringify，避免 Foundation 對不合 JSON 的物件拋 ObjC exception；下載的樣本都是 App Store。 |
| 60 | ☐ | `BTi-d24wi52VeGkBgdgANn`<br>`YueduReader: specialized UnsafeMutablePointer.moveInitialize(from:count:) + 28` | 2.0 (39) | **未解**：記憶體損毀／無效指標在 allocator、Crashlytics 檔案或 CFNetwork timer 被發現；堆疊無法指出第一次破壞記憶體的寫入者。同份報告另有 SwiftSoup Attributes.ensureMaterialized／query-index 執行緒，與舊共用 DOM 競爭相符，但仍需 sanitizer 或相同輸入證明首次破壞者，不能把偵測者當成根因。 |
| 61 | ☑ | `SgRxk1gfht2iQivLsSP-v`<br>`YueduReader: specialized static ReplaceRuleEngine.applyRegex(pattern:replacement:to:) + 980` | 2.0.7 (104) | **本次修復**：堆疊在正則取代建立輸出時發生 Foundation allocation failure，原實作無輸出上限；本次分段計算並限制新增輸出，超限保留原章節且記錄錯誤。另修正 $n 的 Foundation capture 語法，測試與 Foundation oracle 一致。未取得現場的 pattern／章節，不能據此宣稱所有 regex OOM 已排除。 |
| 62 | ☑ | `BakILpdMC7sjwM9B_GuXzV`<br>`YueduReader: static LegadoRequestParser.stringDictionary(from:) + 8` | 1.0.9 (23) | **既有修復**：LegadoRequestParser.stringDictionary 已在序列化前以 isValidJSONObject 檢查；scalar 直接轉字串。 |
| 63 | ☐ | `BNJDH0aF3AQkerBvuxMQ9Y`<br>`libdispatch.dylib: _dispatch_sema4_timedwait + 64` | 2.0.2 (64)、2.0.6 (100) | **部分處理**：TF build 64/100 是缺照片新增用途說明（本次修）；同分類另有 App Store build 27 SwiftSoup SelectorQueryStats allocation failure（未解）。 |
| 64 | ☑ | `DLNY4J5vhpD3VzSsEdKylg`<br>`libdispatch.dylib: _dispatch_thread_main_event_wait_slow + 76` | 2.0.6 (95) | **本次修復**：主題套件匯入跨 await 後更新圖片／介面；兩個匯入入口明確隔離到 MainActor。 |
| 65 | ☐ | `BccwDDCZf0vGPAfwJz_fUz`<br>`libswift_Concurrency.dylib:  + -1` | 1.0.9 (20) | **舊路徑退役**：舊 CloudflareChallengePresenter._present continuation trap；當前 Modules/Targets 已無此實作，不能重現舊路徑，也未為新版本標記線上已解。 |

## 後續：iOS 27 Liquid Glass 材質 DesignLibrary trap（Crashlytics，2026-10-29）

**判定：系統 bug，未解，App 端不修。** 與第 18 列（SDFStyle.distanceRange）、第 48 列（glass RingShadow）同屬系統 glass trap，但是不同的程式位置。依本檔規則不移除、不改 glass 元件。

- **分類**：Crashlytics `16030314022e66d79b4814fdda8f3ad9`（7 筆，4 個安裝）與 `a90eda328d5515906af06607f47906c7`（3 筆，3 個安裝），共 10 筆致命 EXC_BREAKPOINT，堆疊相同。`bf6cfa75…` 是 build 136 同一次崩潰的 MetricKit 副本。App 版本 2.0.6 (100) 到 3.0.0 (140)。前者的標題 `-[DLCAFilter temporarilySuppressingKVO:]` 是 Crashlytics 拿最近的匯出符號 +16964 硬湊出來的；真正的 `temporarilySuppressingKVO:` 只有 80 bytes（存旗標、呼叫 block、還原），裡面沒有 trap。
- **系統版本**：iOS 27.0.0（24A437）、27.0.1，以及一筆 27.2.0（build 129，10-17 的 27.2 預覽版）。「27.1 起已修好」的說法不成立：27.1／27.2 的使用者本來就少（Crashlytics 全 App 報表 10-15～10-29：約 22 人，27.0.x 約 380 人），沒看到不等於修好，而且 27.2 也崩了。
- **堆疊**：display link → `ViewGraphRootValueUpdater.render` → AttributeGraph 更新 → `GlassEffectResolvedMaterial.value.getter` → `MaterialProviderBox.resolveLayers(in:)` → DesignLibrary 內 5 層 → trap，全程沒有 App 幀。9 筆在 `com.apple.SwiftUI.AsyncRenderer`（`renderAsync` → `updateOutputsAsync`，經 `AGGraphWithMainThreadHandler`），1 筆（38b18017）在主執行緒的同步 render。27.0 的 DesignLibrary 位移是 0x3cde0 ← 0x3779c ← 0x38774 ← 0x23694 ← 0x282c0。
- **無法符號化**：DesignLibrary 是剝除過本地符號的私有框架。27.0 模擬器 runtime 和本機 27.2 DeviceSupport（24B115／24B119，UUID `1BA16405-1C14-34C1-BCE7-5260FDB90637`）都沒有函式名稱。27.2 那筆的 trap 位移 0x3c394，在正式 27.2 二進位裡是 `ldr` 而不是 `brk`，代表那台裝置跑的是另一個預覽 build，對不上。
- **場景**：10 筆中有 9 筆，breadcrumb 在崩潰前有 `open reader` 且之後沒有 `close reader`；45e2d51e 的 log 被截斷，無法判斷。9 筆是線上 html 書，1 筆是本機 EPUB（8d57c35a，27.0.1）。8d57c35a 在 `open reader` 後不到 1 秒就崩潰，正好落在 0.62 秒的開書卡片轉場內。那時工具列是隱藏的，迷你播放器也不可能已經出現。注意 `current_book` 這個 custom key 關書時不會清除（`BookReaderView.swift:141` 只有設定），所以不能單憑它認定崩潰當下閱讀器開著，要看 breadcrumb。
- **App 端可疑條件逐一排除**（依現行程式碼；build 100 當時的版面沒有逐一比對）：
  - 閱讀器的 glass 都是標準 API、固定 `Capsule()` 形狀：底欄是 `GlassEffectContainer` 內兩個 `.glassEffect(.regular, in: Capsule())`，標題膠囊是 `.regular.interactive()`，另有迷你播放器、拖曳進度預覽。沒有任何 glass 參數由進度或計時器驅動。
  - 迷你播放器的 `TimelineView(.animation)` 只旋轉膠囊裡面的封面，不改 glass 的參數或形狀。
  - 卡片轉場只對 UIKit layer 做 transform 縮放，SwiftUI 的 bounds 一直是全螢幕（`ReaderCardTransitionAnimator.swift` 約 820–830 行），所以不會把退化的幾何尺寸餵給 glass。
  - 開書時 `showBars == false`，導覽列是 `.hidden`（`ReaderView.swift:1710`），底欄沒有插入，閱讀器本身沒有掛任何 SwiftUI glass。
- **模擬器量測**（iOS 27.0 模擬器、Debug build、本機假 EPUB；用 lldb 在 `GlassEffectResolvedMaterial.value.getter` 下自動繼續斷點，計算命中次數）：
  - 工具列隱藏、閒置數分鐘：0 次。
  - 工具列顯示一次：9 次（一次性）。
  - 工具列顯示後閒置三段：0 次。

  結論是 glass 材質只在轉場時集中重算，沒有任何 App 視圖在閒置時逐幀重算。

  限制：
  - lldb 的 thread spec 沒有過濾命中計數，分不出 AsyncRenderer 和主執行緒。
  - 聽書迷你播放器、背景與前景切換這兩個狀態沒有量到：主機負載 150–490 時，模擬器輸入和 lldb resume 一再逾時，`sample` 光符號化就超過 26 分鐘。
- **重開條件**：拿到 Apple 符號化的 DesignLibrary 幀（例如回報 Feedback Assistant 後由 Apple 回覆）、能指出 App 端畫面或幾何的 sysdiagnose，或能穩定重現。下一步是附上這兩個 issue 的堆疊提交 Feedback。
- **同時段的其他問題不是同一個根因**：
  - 38b18017 那串「main thread blocked ~2 s · no instrumented span」，在崩潰前約 3.5 分鐘的 `close reader` 就停了；另外 9 筆沒有卡頓串。卡頓由另一個 session 處理。
  - d547adf7 的 MetricKit 1073 MB 寫盤（`BookStore` → `Data.write`）發生在崩潰前 15 分鐘，是另一條背景執行緒，另案處理。

## 未解項目的下一步

後續 [App Store 逐項檢查](2026-10-03-AppStore.md) 另發現 SwiftSoup 的 thread-local cache 仍可能經由長期存活的 JS wrapper 逸出原執行緒；已補上每個 JSContext 獨立持有 bridge/cache 的修正與前後回歸。這補強共用解析路徑，不代表此表中缺 first-writer 證據的記憶體損毀項目已全部結案。

逐項需要的材料已列在表中。優先取回 build 90 的精確 dSYM；其餘配置失敗須配合原書源／書架資料與 Allocations、競爭或破壞須有 Address/Thread Sanitizer 重現，系統 SwiftUI glass/layout trap 須能定位發生的畫面與 iOS 版本。缺少這些證據時保留未解，避免加入掩蓋根因的延遲、重試或任意功能刪除。

Foundation replacement 語法：[Apple NSRegularExpression 文件](https://developer.apple.com/documentation/foundation/nsregularexpression)。build 107 符號化結果：`/tmp/yuedu-tf-crashes-20261003/build107-symbolicated.txt`。
