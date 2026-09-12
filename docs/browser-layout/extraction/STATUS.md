# BrowserLayout 引擎抽取驗收 — 2026-09-12

> 此頁保留發布前驗收快照。後續 0.3.0 發布、遠端接線與 CI 已知問題請見 [發布驗證](release-0.3.0.md)。

本機引擎抽取、獨立 consumer、Reader 翻頁／橫排捲動整合已完成；尚未發布套件 ref，不能把本機整合稱為乾淨遠端建置已完成。本報告只涵蓋 BrowserLayout，並非整個 Reader SDK。

## 1. 基線與工作目錄

| Repo | 實際 checkout | 起始 branch / HEAD | 起始狀態 |
|---|---|---|---|
| Reader | `/Users/zhangruilin/Desktop/Yuedu-reader` | main / `5e18b6aa5e39bfff802911cbdc14dc82ebc05843` | clean |
| CoreText | `/Users/zhangruilin/Desktop/YueduCoreText` | main / `18253ed6e142cb416af0826f5a62d1737c5e833b` | clean |

兩邊改動均保留為未提交 diff；本 task 沒有 commit、push、tag、release、stash 或 reset。執行期間其他工作在 Reader 增加 navigation/back-swipe 等變更，已保留，不能將全部工作樹 diff 都歸於本次抽取。

實際工具鏈為 Xcode 27.0 beta (`27A5252f`)、Swift 6.4 (`swiftlang-6.4.0.33.1`)、iOS Simulator 27.0 SDK。測試 destination 為 `platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6`，裝置名稱 Yuedu Baseline Attribution，iPhone 17 Pro Max / iOS 27.0。套件仍宣告 Swift tools 6.0 / iOS 17，未提高最低要求；Xcode 16 的最低版本相容性本次未另行執行。

起始 App remote package 為 YueduCoreText 0.2.1（上述 package SHA）；SwiftSoup 為 2.13.7 / `8d6ad267714cac3ae747cefdd21f7a6665006e1f`。App 的 project references 與既有 Package.resolved 沒有改成虛構版本。

## 2. 依責任抽取的對照

完整逐檔清單見 [files.json](files.json)，整合後單一定義檢查見 [boundary-audit.json](boundary-audit.json)。

| 分類 | 移入套件的實作 | App 留存／薄轉接 |
|---|---|---|
| A：frontend | CSSFrontend、CurrentCSSFrontend、CSSFrontendModels、ComputedStyle/TreeBuilder、SwiftSoupHTMLSemanticAdapter、HTMLPresentationalHintExtractor | EPUBStylesheetIngestion、Readium 章節資源與既有 @import／字型準備 |
| A：核心排版 | BoxTreeBuilder、LayoutBoxTree、BlockLayout、InlineLayout、InlineFormattingContext、CoreTextLineBreaker、FloatContext、RubyInlineLayout、HorizontalRubySupport、HorizontalTextIndentSupport | 沒有 BrowserLayout 的第二份 block/inline/float/ruby 演算法 |
| A：分頁／連續 | BrowserLayoutDocument、BrowserLayoutSession、PageFragmentation/PageWalker、BrowserScrollDocument | BrowserLayoutPageEngine 管理章節、generation、首屏發布、頁碼整合、fallback、快取與宿主 |
| A/B：繪製／互動 | DisplayList/Builder、DisplayListDrawer、BrowserTextGeometry、BrowserPageGeometry、LogicalGeometry、LinkAnchorInfo/LinkInteractionRegionSet、來源映射與語意描述 | DisplayListRenderer 包裝 Reader snapshot／頁眉頁腳；ReaderDisplayListDrawer 只加入 Reader regex 裝飾；LinkResolver 管理 publication 導航 |
| B：混合檔拆分 | 從 HTMLAttributedStringBuilder 拆出原有 CSSRule/CSSSelector/CSSParser；ReaderFontCascade、FontTraits、CSSLength/CSSTextIndent、ReaderWritingMode、media/pronunciation 描述 | legacy HTML builder 使用相同 parser／中立型別；UserReaderFontResolver 保留使用者字型政策；TTS 字典與播放器、EPUB 容器留在 App |
| C：產品政策 | 套件輸出 capability facts / 詳細錯誤 | BrowserAuto 的整章 fallback、browserForced 診斷、settings 轉換、FootnoteStore、TTS／notes／選字 UI、書架與付費均留 App |
| D：實驗 | 沒有引入 Lexbor production dependency | 既有 Lexbor frontend/owner/adapters 移到 Reader 測試 target 的 ExperimentalFrontend，保留實驗與測試，不強迫成為 public API |

原本 App 的核心實作檔已刪除；不是把同一份演算法複製到套件後繼續在 App 使用舊版本。CSS parser/cascade、斷行、float/ruby、fragmentation 沒有藉本輪重寫。

## 3. 實際 public API 與 consumer

正式入口是 `HTMLLayoutDocument`，接受 HTML/CSS 字串或帶順序／來源／失敗資訊的 `CSSFrontendInput`，以及 `BrowserLayoutConfig`、預載圖片／imageLoader／fontResolver。呼叫者不需要先建立 StyledAST、ComputedStyle 或 box tree。

```swift
let document = HTMLLayoutDocument(
    html: "<p id='intro'><a href='#intro'>Hello 世界 🌕</a></p>",
    css: ["p { margin: 12px; border: 1px solid blue; }"],
    configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 480)
)
let session = try document.makePageSession() // MainActor
if let page = try await session.layoutNextPage() {
    let list = DisplayListBuilder.build(for: page, sourceText: session.sourceText)
    list.draw(in: context) // caller-owned CGContext, top-left / y-down
    _ = list.selectionRects(for: NSRange(location: 0, length: 5))
}
let continuous = try document.prepareContinuous().makeDocument()
_ = continuous.contentSize
```

完整、實際編譯的範例在套件 `Examples/StandaloneConsumer/Sources/Consumer/Example.swift`，public-only 驗收在 `Examples/StandaloneConsumer/Tests/ConsumerTests/ConsumerTests.swift`。該 consumer 有自己的 Package.swift，只依賴 YueduCoreText；不引用 Reader project/source，不使用 @testable。

獨立驗證目錄為 `/tmp/yuedu-engine-extraction/independent/YueduCoreText`，只放套件 source、manifest、LICENSE/notices 與 consumer，沒有 Reader 原始碼。使用 Xcode 自己的正常 DerivedData，不修改 SourcePackages/checkouts。實際被驗證的來源 SHA-256 清單見 [independent-source-sha256.json](independent-source-sha256.json)。

consumer 驗證 HTML/CSS → 分頁／連續 → bitmap、圖片／背景／邊框像素、UTF-16 文字範圍、anchor/link/selection/hit geometry、改 viewport／字級的 reflow、unsupported table、缺失圖片／stylesheet，以及取消和 session 釋放。

## 4. App 真正接線

- `EPUBPageRenderer.load(publicationSession:...)` 建立 CoreTextPageEngine delegate，再建立 `.browserAuto` 的 BrowserLayoutPageEngine，將同一 adapter 指派給 `scrollEngine.browserAutoEngine`。
- `BrowserLayoutPageEngine.layoutBrowserChapter` 使用套件的 `BrowserLayoutSession`；`layoutNextPage` 的實作與 PageWalker 只存在套件。首次頁面仍增量發布，不等待整章結束。
- `BrowserChapterLayout.displayList` 呼叫套件 `DisplayListBuilder.build`；page ranges、offset→page、selection rects 呼叫 `BrowserPageGeometry`。
- `BrowserLayoutPageEngine.makeScrollChapter` 呼叫套件 `HTMLLayoutDocument.prepareContinuous` 與 `BrowserContinuousLayout.makeDocument`；連續文件使用真正的 continuous geometry，沒有拼接分頁截圖。
- 頁面與捲動 cell 的內容繪製經 ReaderDisplayListDrawer 到套件 `DisplayList.draw(in:)`。Reader closure 只畫產品 regex overlay，套件自行繪製文字、圖片、背景、邊框與 CSS 裝飾。

CoreTextPageEngine 的 legacy orchestration／不同演算法、固定版面 EPUB、legacy 直排、TXT／線上內容維持原路徑。Auto 與 forced 的政策留 App；套件沒有反向呼叫 legacy fallback。

## 5. 依賴、資源與所有權

```text
Yuedu Reader → YueduCoreText → YueduCoreTextTypography
                            → SwiftSoup 2.13.7
                            → UIKit / CoreText / CoreGraphics / Foundation
StandaloneConsumer → YueduCoreText（同上，沒有 Reader）
```

不形成循環，也沒有反向 App dependency、Readium/Firebase/WebKit import、App settings/storage singleton。套件邊界測試允許本輪正式增加的 UIKit/SwiftSoup；對 WebKit、Readium、Firebase、App 儲存與隱私的禁止仍在。

App 的 chapter-scoped resource adapter 保留 stylesheet order、@import、相對路徑、嵌入字型與 SVG image wrapper 行為。Consumer 明確準備資源，不自動連網／掃檔／預載整本書；同步 layout 不等待 async callback。缺失的必需圖片、載入失敗的 stylesheet 在高階 API 回報 resourceFailure；既有低階 session/resource adapter 行為保留。

`BrowserLayoutSession` 保留 MainActor confinement；連續文件在呼叫端的 serial executor 同步排版。CTLine/CTFrame/CTFramesetter 由該排版操作／結果持有，建立、讀取、繪製、釋放遵守同一 ownership；結果刻意不是 Sendable。沒有新增 detached task、全域 shared engine 或整個引擎 @unchecked Sendable。

`cancel()` 釋放未完成 pipeline/walker，後續取頁回報取消，已發出的結果由 consumer 持有。App 原有 generation gate 仍防止舊工作覆蓋新章節／設定。繪製使用既有 CTLine/display items，不重新解析或排版。

頁面結果使用 page canvas coordinates；continuous display list 使用 document coordinates，取 tile 時由套件轉成 tile-local。view/window 轉換由宿主負責。所有來源範圍是折疊後 sourceText 的 UTF-16，不是 raw HTML index；ruby、空白與 shaping mapping 未重做。

## 6. 測試與可重現命令

完整實際命令見 [commands.md](commands.md)，結果由 xcresulttool 讀取，見 [verification.json](verification.json)。所有測試皆帶 `-parallel-testing-enabled NO`，同一上述 iOS Simulator destination。

| 驗證 | 結果 | 產物（位於 /tmp/yuedu-engine-extraction/） |
|---|---|---|
| 抽取前核心 5 suites | 45/45 | baseline-core-rerun.xcresult |
| 抽取前擴充、ruby／裝飾／能力／效能 | 57/57 | baseline-extended.xcresult |
| 抽取前 package 原公開 API | 58/58 | baseline-package-core.xcresult |
| 抽取前精確 geometry fingerprint | 8/8 | baseline-geometry.xcresult |
| 抽取前《紅樓夢》翻頁／捲動 | 2/2 | baseline-corpus.xcresult |
| 套件完整測試（含 Typography、工具 API、抽取核心、boundary） | 128/128 | package-verified.xcresult |
| 乾淨目錄 public-only consumer，含 bitmap 像素 | 5/5 | consumer-clean-render.xcresult |
| App 核心與相同 geometry fingerprint | 110/110 | app-core-after.xcresult |
| App fallback、設定／模式、選字、語意、字型與 legacy 直排等 | 137/137 | app-integration-tests.xcresult |
| App 真實 EPUB：《紅樓夢》2 項、《詭秘之主》內嵌 glyph 1 項 | 3/3 | app-corpus-after.xcresult |

App `build-for-testing` 完成編譯與連結，見 app-integration-build13.log；後續 app-integration-tests 與 app-repeated-after 亦完成 test action。兩邊各重複 3 輪的 5 個 perf/corpus 測試全部通過，詳細命令與 xcresult 見附件。不是只做語法解析，也不是在 macOS 使用 swift test 代替 iOS 驗證。

中間失敗未隱藏：App 跨模組 import/可見性編譯錯誤已修正；package-final 曾有 2 個文件測試失敗（4 個 assertions），補足依賴／scope 說明後重跑完整 128 項通過。最早的 0-test 呼叫與模擬器啟動失敗不列入通過數。《詭秘之主》一度因雲端佔位檔卡在 Archive 開檔，116 秒後完成讀取並通過，最終 xcresult 為成功。

## 7. 抽取前後差異與效能

八組精確 fingerprint 同時在未修改基線執行檔與 App 套件版本通過：正文、multi-run link、ruby、inline image、左右 float、分頁與 source ranges、selection/link hit geometry、重複排版。指紋以 CGFloat 的 IEEE-754 bits 與 SHA-256 建立，不使用 process-randomized Hash。沒有放寬 geometry 容差或改 golden。

《紅樓夢》正式 BrowserAuto 扉頁、畫冊分頁與正常 scroll cell 三張 PNG 逐位元相同；routing.json 也完全相同：Browser、1 頁、15em=255pt、左右 margin 45.04pt、top 89.67pt。[比較清單](corpus-comparison.json)。

初次 legacy 對照圖的標題區域有差異；未修改基線執行檔重跑後與抽取後 legacy PNG 完全相同，差異在基線本身即可重現。[獨立歸因證據](legacy-baseline-attribution.json)。本輪沒有修 legacy 或覆蓋歷史 golden。

效能使用既有 BrowserLayoutPerfTests 的同一 40 段 synthetic chapter、同 SDK／viewport／字型／設定與 Simulator Debug，比較 cssCollect/cssParse/styleTree/boxTree/layout/fragment 的既有 instrumentation；[重複量測原始數據](performance.json)：各 9 個觀測值，中位數由 16.045ms 到 15.311ms（−4.58%），baseline 範圍 15.458–20.699ms、抽取後 14.761–35.307ms；分布重疊且新版本有一次較高啟動樣本，不能宣稱效能改善。首屏未等待完整章節與取消後 generation 不覆蓋結果，由原 session／adapter 回歸檢查。這不是手機 Release、耗電或優化成果宣告。

## 8. 本機整合與待發布項目

相鄰 checkout 擺放後，開啟 `Yuedu-reader/Yuedu-Engine.xcworkspace`。workspace 只用 `group:../YueduCoreText` 相對路徑 override 同一 package identity，不同時向 target 加入兩個同名套件。可在任意共同父目錄重現，沒有把 /Users 絕對路徑寫入可提交的 Xcode 設定。

本機跨 repo 建置與測試已驗證。遠端仍是已發布的 0.2.1 工具包，不含本次引擎；只有遠端 Reader project 的乾淨 checkout 目前不能建置這份新接線。後續需使用者另行授權發布實際套件 ref，再把 App requirement 更新到該真實 ref、正常 resolve 並驗證乾淨遠端建置。此次沒有虛構已發布版本。

## 9. 限制與未驗證範圍

- 只抽取 BrowserLayout 已有橫排子集，沒有新增 table、vertical HTML、flex/grid、完整 CSS／EPUB 或 DTCoreText 對等能力。
- 真實 corpus 是代表案例，不是整本 EPUB 全頁掃描；歷史全書 golden 的已知差異仍保留。
- 沒有真機 Release／耗電驗證，也沒有宣稱效能改善；最低 Xcode 16 工具鏈未另跑。
- CTLine 結果不能任意跨 concurrent executors；資源由 consumer 明確擁有。
- 遠端依賴發布尚待授權；不屬於已完成的 remote resolve 驗收。

**驗收答案：是，不取得 Yuedu Reader 原始碼，只取得 YueduCoreText 與正式宣告的依賴，已能從 HTML + CSS 獨立完成排版、分頁與繪製；證據是乾淨目錄 consumer-clean-render.xcresult 的 5/5 public-only iOS Simulator 測試。**
