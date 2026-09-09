# Phase 5A Task 5–7：長屬性映射驗收

日期：2026-09-08。起點：`b06801ded952625cb33c57274765327603476abb`。

## 本輪範圍與決策

使用者確認：先完成可驗證的長屬性映射，shorthand 明確列為 production 切換阻擋，維持原架構邊界。

Task 7 是部分完成；本報告不宣告完整 5A 或 production cutover。產品 layout engine 仍為 Legacy，BrowserLayout 的既有 frontend 仍為 Current；沒有新增預設切換，也沒有新增 Table／Vertical／Flex 排版能力。

## 已交付

- Task 5：區分載入失敗與合法空 stylesheet。失敗 entry 保留來源／診斷，排除於 active author list；沿用原有資源載入與快取路徑。
- Task 6：DOM 與 CSS snapshot 保留混合文字／元素順序、完整 semantic path、namespace、屬性、真正勝出的 declaration、selector／stylesheet source identity。Document 在每次 snapshot 內建立與釋放，結果只持有 Swift 值。
- C bridge：HTML parse 後才初始化 styles，inline attribute 只處理一次，embedded style 只從 ingestion 接入。使用 Lexbor selector/cascade primitive 並傳回錯誤，避免既有高階 helper 吞錯；沒有重做 selector 或 cascade。
- Task 7：新增唯一 `LexborComputedStyleAdapter`，以依賴順序套用 font-size／color／background image 等長屬性，再用既有 line-height／border finalization。覆蓋表代表每個 property 有處理分支或明確 gap，並非所有 CSS value 都已支援。
- ComputedStyle tree 保留 link、anchor、footnote、SVG raster wrapper、reader config 與 HTML presentational hints；繼續使用原有 hint extractor／UA 規則。raw DOM preorder 與 layout-facing postorder 身分分開保留。
- `CSSFrontendResult` 新增 value-only capability facts／diagnostics／winning source。直接將不完整 Lexbor 結果注入 `BrowserLayoutDocument` 會在 layout 前拒絕；完整 scanner／shared evaluation 接線仍屬 Task 8。

## 實際找到的缺陷

| 缺陷 | 修正／處置 |
|---|---|
| 載入失敗 stylesheet 仍在 active list | `loadFailed` 與合法空內容分離；原有失敗案例及新增空內容案例驗證 |
| Lexbor style walk 包含非 winner 的 weak declarations | bridge 明確過濾 weak，來源身分跟隨真正 winner |
| snapshot 文字缺 parent，path 只有單層 | callback 帶 parent ID；混合順序由同一 preorder 還原；path 保留祖先與 id |
| 既有 parse/apply 路徑重複處理 inline、部分 helper 吞錯 | inline 初始化一次，使用可檢查回傳值的 Lexbor primitive |
| parser-rejected declaration 被當作普通 winner | 不加入 cascade；保留 unparsed 計數供後續分類與切換阻擋 |
| 未支援 at-rule／nested rule 被略過而假綠 | 保留 unsupported rule 計數並產生 CSS diagnostic |
| `em` 的 explicit／text-indent 自然繼承誤用子字級 | 繼承時計算父層長度；百分比仍保留 symbolic |
| 無 background image 時 CSS-wide component 遺失 | 明確記錄模型無法保存的 gap |
| CSS border 初始值與舊 model convenience defaults 不同 | Lexbor frontend 使用 medium／none；none 的 computed width 歸零 |
| Lexbor 3.0.0 `clear` parser 漏收合法 `both` | 已確認 vendored parser 分支缺項；診斷及拒絕進入 layout 的回歸案例保留此 upstream 阻擋，未改 generated source |
| html／body 根節點隱藏無法由現有 root layout entry 表示 | `hiddenRoot` 明確阻擋，避免 visible body 假結果 |

## 驗證紀錄

- 初始三類 focused tests：8 passed／1 failed；失敗為 active list 納入載入失敗的 stylesheet。
- 第一輪映射整合：32 個測試方法，含參數化共 60 次執行，0 failed。
- C package 最終：19／19 passed；主代理親自執行 `swift test --package-path Packages/CLexbor --scratch-path /tmp/yuedu-clexbor-task6-build`。
- 擴大回歸：72 passed／2 failed（測試方法），含參數化為 102 passed／2 failed。失敗為真實 EPUB 圖片寬度及紅樓夢斷行基線。
- 同機、同模擬器的未修改 HEAD 對照：兩項測試均失敗，與修改後的完整 failure text **逐字一致**。紅樓夢有 271 章差異；證據只證明本次未新增這批差異，尚未替這些差異完成根因歸因。
- 圖片案例已查閱原 EPUB：body 左右各 1% margin，BrowserLayout 應為 `418 × 0.98 × 0.15 = 61.446`；原 62.7 預期未扣 authored margin。已更正 Browser 測試預期，Legacy 的 62.7 驗證保留。
- 新增實際序列化測試曾抓到 `clear: both` 未獲 Lexbor 接受（74 methods passed／1 failed）；定位為上游 parser 缺項後，將其獨立列為拒絕進入 layout 的 blocker 測試，其他可接受長屬性仍驗證正常映射。
- 最後 9 類 focused 重跑：76 個測試方法，含參數化共 106 次執行，0 failed／0 skipped（`final-focused-2.xcresult`）。涵蓋 ingestion、snapshot、lifetime、mapping、Current parity、float、text-indent、真實 EPUB 圖片與既有 style resolver performance 測試；不代表已完成 Lexbor 效能 gate。
- 實作已帶回主工作目錄，整合起點為 `3016d1d36f03062761b1eca96eacec5f95f74e87`；該新增提交的閱讀位置修改與本輪檔案不重疊。主目錄三類回歸（Lexbor synthetic、Current parity、真實 EPUB 圖片）16／16 passed，0 skipped，`main-integration.xcresult`。
- `verify_vendored_lexbor.sh` 通過；沒有改 generated source 或 line-break golden。

[機器可讀驗證摘要](task5-7-verification.json) 記錄裝置、起點、測試範圍及本機 xcresult 路徑。控制組測試完成後，Xcode 額外的 `simctl diagnose` 收集停滯；僅終止該診斷子程序，測試結果仍完整保存在 xcresult，後續執行使用 `-collect-test-diagnostics never`。

**驗收狀態：未結案。** 紅樓夢既有 golden gate 仍未通過，因此未 commit，也不宣稱整體修復完成。

## 尚未解除的切換阻擋

1. Lexbor 3.0.0 未提供本計畫假設的 shorthand-to-longhand cascade 展開。`margin`／`padding`／`border`／`font`／`background` 等保留 `ADAPTER_GAP`；本輪不在 Swift 重播優先序。
2. parser-rejected 語法（包含本機驗證的 `var()` 與合法的 `clear: both`）與未處理 at-rule／CSS nesting 會保守阻擋。診斷計數不等於已判定每一筆 CSS 非法，必須另行分類；即使某 selector 未匹配，也不宣稱已完整評估。
3. 既有 model 缺欄位或 value subset：min-width／min-height／max-height、多背景、每邊獨立 border color、多半徑、部分 named color／HSL、visibility hidden 的子元素復活等。單值 border-color／border-radius 可表示，其餘保留來源與 gap。
4. 根節點隱藏、多數非既有 layout capability、資源／media 診斷仍會阻擋。
5. Task 8–13 的 scanner 接線、DEBUG 切換、完整 synthetic／23 書 style/layout differential、ASan／效能／build matrix／真機 acceptance 與正式 cutover 決策尚未完成。

下一步：先對既有紅樓夢基線差異建立歸因與處理決策，不能直接重錄 golden；Task 8 的共用 evaluation／scanner 接線仍未啟動。Shorthand 亦為獨立未解 gate，不能由長屬性測試通過推定可以切 production。

## 規範與證據入口

- [既有 Phase 5A 設計](../../superpowers/specs/2026-09-04-lexbor-css-frontend-production-migration-design.md)
- [既有 Phase 5A 計畫](../../superpowers/plans/2026-09-04-lexbor-css-frontend-production-migration.md)
- [目前狀態](../STATUS.md)
- [CSS Cascade：shorthand](https://www.w3.org/TR/css-cascade-5/#shorthand) 與 [inheritance／defaulting](https://www.w3.org/TR/css-cascade-5/#defaulting)

本輪未產生 commit；實作與測試結果以本報告記錄的起點與變更檔案為範圍。
