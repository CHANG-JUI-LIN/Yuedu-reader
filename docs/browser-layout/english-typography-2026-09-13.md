# 英文 EPUB 出版排版修復（2026-09-13，本機未發布）

## 基線與接線

| Repo | 原始 checkout | 起始 branch / HEAD | 開始時狀態 |
|---|---|---|---|
| Reader | `/Users/zhangruilin/Desktop/Yuedu-reader` | main / `f7e472a558ba59dd7a4dd45823bc223b451f76f2` | 已有 AI、Reader、資源與測試修改，全部保留 |
| YueduCoreText | `/Users/zhangruilin/Desktop/YueduCoreText` | main / `4a49d3183f5f5c0cc44ff3e68c1a01113d255438` | 乾淨，對應 0.4.0 |

本次未 commit、push、打 tag 或發布，也沒有修改匯入介面、書架、設定、Lexbor 入口或使用者資料。套件仍為 iOS 17 / Swift tools 6，SwiftSoup 2.13.7。

Reader 的 `Package.resolved` 仍固定到 0.4.0；開發驗證使用既有、被 Git 忽略的 `Yuedu-Engine.xcworkspace`，引用 `group:Yuedu-Reader.xcodeproj` 與 `group:../YueduCoreText`。沒有修改 Xcode 快取 checkout，也沒有另建引擎副本。

正常 `EPUBPageRenderer.load` → `BrowserLayoutPageEngine` 的 BrowserAuto 入口使用套件。此次 adapter 改用 `BrowserLayoutCapabilityScanner.scan(input:writingMode:)`，讓能力檢查與 layout 消費同一份有順序的 stylesheet input。翻頁沿用 `HTMLLayoutDocument.makePageSession`；同一個 engine 的捲動準備使用 `prepareContinuous`。legacy/fixed layout/章節 fallback 政策未改。

**新增的 `scan(input:)` 尚未在遠端 0.4.0 發布。必須用上述本機 workspace 建置本次 Reader diff；直接開原 `.xcodeproj` 解析遠端 0.4.0 不能完成這次整合。** 下一次獲准發布套件後，才更新 Reader 的最低版本與 resolved pin；本次不填不存在的版本。

## 原書與根因

本機原書來自使用者提供的 `Desktop/Test document/EPUB Format`；不把書籍或字型資源提交到公開 repo。

| 畫面 | 實際來源 | 修復 |
|---|---|---|
| Hail Mary 開頭引號與 W 沒放大 | spine 5，`text/part0005.html`；`.pcalibre:first-letter` 指定 320%、bold、灰色、float:left、line-height:.7 及負 margin | 既有 parser 解析到的首字規則沒有進 production frontend。現在建立帶來源範圍的 pseudo inline/float，沿用既有排除區域和繪製鏈；不放大整段 |
| Hail Mary 正文行距過疏 | `.calibre` line-height:1.2；`.para-p` text-indent:3.8% | 20pt 字型的 ink 高 28 原本壓過指定的 24；改以 inline half-leading / strut 算行框。3.8% 縮排保留 |
| Deal 標題後留白不對 | spine 1，`OEBPS/part0001.xhtml`；`.class_sk` min-height:12em、margin-bottom:2em | min-height 原本未採用；恢復作者要求的標題容器高度，不壓縮大空白 |
| Deal 有大字詞間距、沒有自動連字號 | `.class` justify、hyphens:auto；`xml:lang="en"` | 語言與 hyphens 進入 CTTypesetter 的候選選擇、連字號量寬、兩端對齊，再進 display presentation。修復繪製重新取原字串時丟掉生成連字號的問題 |
| Deal 引文沒有參考畫面的首行縮排 | `.class_sn`、`.class_st` **沒有**作者 text-indent；`.class_sr` 署名指定1.5em | 引文維持零縮排；署名依作者規則縮排。沒有給所有英文 p 補上2em |

Hail Mary 的普通正文沒有指定 hyphens:auto，因此不擅自套英文自動斷字。兩書的參考閱讀器設定未知，不以不同頁碼或每頁字數當成錯誤。

## 共用核心修正

- `CSSParser` / `CurrentCSSFrontend`：element sibling `+`、`~`、`:first-of-type`；跨 stylesheet 全域 source order；有完整作者清單時依 DOM 順序使用一次 inline/linked sheet，不從 HTML 重播 inline CSS。暗色規則不混進亮色 cascade。
- `ComputedStyleTreeBuilder`：html → body 繼承；signed px/pt/em/rem/% 與 indent 的 inherit/initial/unset；無效宣告不擦掉先前有效值。em/rem 繼承計算後長度，百分比保留 containing-block 基準。
- `InlineLayout` / `BlockLayout`：縮排先影響可用行宽；跨頁不重套。水平 line box 使用 half-leading、parent strut 與 inline 內容，額外 Reader lineSpacing 只加一次。vertical/ruby 的既有度量路徑保留。
- `CoreTextLineBreaker` / `DisplayList`：manual soft hyphen、明確語言的 auto 斷字、none、應急折行分開；可見連字號先量寬才對齊。生成連字號不修改 sourceText；soft hyphen 保留原 UTF-16 單位。極端大縮排與整詞 overflow 也保留尾隨空格的來源範圍。
- `text-align-last` 用於尾行與硬換行；移除按填充比例偷偷撤掉 justify 的規則。

第一字不硬編碼 W；synthetic fixture 使用引號與 Z、nested em/link。段落的 display list、selection/hit geometry 共用 shaped source mapping。套件獨立 consumer 只 import 正式 API。

可選 `BrowserLayoutConfig.onDiagnostic` 是文件本地 callback，沿相同 frontend 報告 stylesheet 身分、規則順序、unsupported/matched selector、specificity、important、computed typography、DOM path → layout node、box/line、font 與 source range。不傳送遙測。原書 trace/圖片只留本機；詳細斷字候選與逐字空格增量尚未全數輸出到此 callback，不能把這份 trace 宣稱為完整 CSS debugger。

## 受控前後對照

同一 iPhone 17 Pro Simulator、相同 SDK、390×740 viewport、20pt、lineHeightMultiple1.2、額外行距與段距0、content insets30/18/30/18。正文內容寬354，書籍 body 的5pt左右 margin 另外依法計算。字型 resolver、書檔與資源相同。

基線直接在原 checkout 暫時逆套本次 patch，完成後恢復；沒有使用 repository 副本。基線預期會在缺失放大首字的斷言失敗，並保存原始幾何與畫面。

| 指標 | 0.4.0 基線 | 修正版 |
|---|---:|---:|
| Hail Mary 開頭2個來源字元字級 | 20 | 64 |
| Hail Mary 正文行框 / 相鄰 baseline 差 | 28 | 24 |
| Hail Mary 第一普通段落首行 x（page-local） | 37.612 | 37.612 |
| Hail Mary 連續文件高度 | 26874.0666 | 23228.0666 |
| Deal 首段頂端 y（page-local） | 197.0616 | 310 |
| Deal 正文字級 / 行高 | 20 / 24 | 20 / 24 |
| Deal 連續文件高度 | 793.4616 | 906.4 |

Hail Mary 實際字型為 PingFangSC-Regular / Semibold；Deal 正文 Palatino-Roman，標題 Quicksand-Regular。這是該次固定設定的實際 resolver 結果，沒有冒充另一個閱讀器的字型。

圖片與 JSON：`/tmp/yuedu-english-typography/{before,after}/{hail-mary,deal}-paged.png`、同目錄 `.json`；after 另外有 `*-scroll.png` 與 `*-trace.txt`。畫面可見放大引號/W、Deal 的 `deli-` / `ciously` 等實際斷字。頁眉頁腳是 App overlay，這組受控 bitmap 只畫正文 display list。

三個舊 float 預期值按明確 CSS 修正：line-height:20px 的行框從22.4改20；位於y21的 float 不應碰到0...20行帶；baseline image 仍由下緣對齊 baseline，父字型 strut 的 descent 使166.6高圖片行框成172.04。保留斷言與容差，未批量重寫 golden。

## 驗證指令與產物

工具鏈：`/Applications/Xcode-beta.app/Contents/Developer`，Xcode 27 beta（27A5252f），iOS Simulator 27.0。destination `id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`。所有測試 serial，`-parallel-testing-enabled NO`。

遵循 `scripts/xctest.sh` 的 verdict wrapper。因原 wrapper 固定 App project，暫存三份僅調整 ROOT/project/scheme 的 runner 到 `/tmp/yuedu-english-typography/`；未更動使用者正在修改的 runner，也未複製 repo。共用前綴：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export YUEDU_DEST=id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400
bash /tmp/yuedu-english-typography/package-tests.sh -l /tmp/yuedu-english-typography/package-final-3.log -- -resultBundlePath /tmp/yuedu-english-typography/package-final-3.xcresult
bash /tmp/yuedu-english-typography/app-tests.sh -l /tmp/yuedu-english-typography/app-final-2.log -- -resultBundlePath /tmp/yuedu-english-typography/app-final-2.xcresult -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' -only-testing:'yuedu appTests/BrowserVerticalReaderRouteTests' -only-testing:'yuedu appTests/JapaneseVerticalRubyTests' -only-testing:'yuedu appTests/BrowserLayoutPageEngineTests' -only-testing:'yuedu appTests/CSSFirstLetterSelectorTests' -only-testing:'yuedu appTests/BrowserLayoutTextIndentTests' -only-testing:'yuedu appTests/BrowserLayoutStylesheetIngestionTests' -only-testing:'yuedu appTests/CurrentCSSFrontendNeutralDOMParityTests'
bash /tmp/yuedu-english-typography/consumer-tests.sh -l /tmp/yuedu-english-typography/consumer-final.log -- -resultBundlePath /tmp/yuedu-english-typography/consumer-final.xcresult
```

重建 runner 時以 Reader `scripts/xctest.sh` 為來源：App 使用 `-workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader`；package 在套件根目錄使用 `-scheme YueduCoreText-Package`；consumer 在套件 `Examples/StandaloneConsumer` 使用 `-scheme YueduCoreTextConsumer`。package / consumer 移除 `-project`，保留 serial 與完整 verdict 判斷。`YUEDU_ENGLISH_EPUB_DIR` 可指定本機原書目錄；不存在時測試不會偽裝通過。

| 驗證 | 結果 | log / xcresult（均在 `/tmp/yuedu-english-typography/`） |
|---|---|---|
| 修改前 focused English + vertical fixture | 8 tests / 11 issues；英文缺口預期失敗，4項 vertical 通過 | `baseline` |
| 修改前 Reader CoreTextWritingModeTests | 25 通過 | `writing-mode-baseline` |
| 原書 0.4.0 受控畫面 | 缺失首字斷言失敗，兩本基線圖片及JSON已保存 | `app-before` |
| 最終套件 | **140 core + 11 Typography = 151 通過**，完整 TEST SUCCEEDED | `package-final-3` |
| 最終 Reader | **60 tests / 8 suites 通過**，包含兩本原書參數案例、日本直排/ruby、取消路由、縮排和CSS ingestion | `app-final-2` |
| 獨立 consumer | **7 通過**，正式 public API，未引用 Reader source/target；含新英文排版繪製測試 | `consumer-final` |

測試會編譯變更後的 package、App 與 consumer，不以 diff review 或語法解析代替測試。中途編譯錯誤與測試失敗保留在其他 log，均不算通過；`app-final` 曾有3項失敗（pt測試預期、過時直排拒絕測試、overflow尾隨空格遺失），在 `app-final-2` 全部解除。`regression-2` 與 `app-final` 在已輸出失敗結果後尚未完成 runner 收尾時終止自身 xcodebuild，不當作成功；`diagnose-break` 選錯 test filter、執行0項，不算驗證。

## 已知邊界

沒有新做完整 font shorthand、hanging/each-line、任意 shrink-to-fit float、跨 block/replaced/ruby 邊界的進階 first-letter、indefinite containing block 的百分比 min-height 或完整 word-break:keep-all。未知內容語言不猜 en。未使用 WebKit 逐像素 golden；沒有真機 Release 效能、能耗或全書全章人工驗收，也不宣稱 CSS 全相容。既有 perf instrumentation 未作同條件正式前後效能量測，因此本文不宣稱速度改善。
