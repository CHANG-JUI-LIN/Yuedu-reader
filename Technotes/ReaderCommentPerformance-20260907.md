# 閱讀器氣泡效能量測（2026-09-07～08）

## 驗收狀態

已補齊的 EPUB 功能及回歸見 [BrowserEngineParityGaps.md](BrowserEngineParityGaps.md)。本文件只記錄線上閱讀器相關效能證據，不把 EPUB 回歸當成線上書評的效能證明。

- 神魔小說書源已透過 `BookSourceStore.importFromData` 匯入乾淨的 Profiling Simulator，並等待正式儲存佇列完成。
- 江湖俠客主題已透過 `QiThemeImportService.load/apply(includeOverlayLayout: true)` 匯入；包括閱讀背景、版面配置、章節標題、8 張封面及 Huiwen-mincho 字型。設定為仿真翻頁。乾淨 Simulator 使用專案 `Configuration/YueduPro.storekit` 與 Apple `SKTestSession` 本機測試交易提供 App Pro 測試權限；未進行真實付款，也未更動正式授權判斷。
- 使用者已自行完成有效登入；已從探索月票榜第一名進入辰東《夜無疆》，取得 819 個章節，成功顯示正文、段評及本章說。登入資訊只保留本機安全儲存。
- 已執行超過十分鐘的正文／段評閱讀操作，包含真實仿真動畫、評論捲動、返回正文及連續翻頁。追加高壓測試後，重現並修正跨章跳轉的無限重建；最終四組各完成 50 次有效連續仿真翻頁，共 200 次，並有反向跳章。
- 已完成全部預設／完整江湖主題 × 書源氣泡關／開的四組比較。段評、熱評、本章說三個旗標皆由書源登入頁切換；未用主題的氣泡樣式切換冒充来源 OFF。修正前、後 App 均保留本機快照。

## 已包含全部修正的四組高壓結果

每組均先冷載第 10 章，確認正文與前後各兩章的正式快取完整提交，再連續作 50 次真實仿真翻頁。四組各自跨 4／4／5／4 章；200/200 次頁碼轉換有效，與快照修正前的逐步章節／頁碼全部一致，另完成反向跳章與完全未快取的第 20 章遠跳。四個 XCTest UI 結果均 1/1 通過、零 runtime warnings。

| 設定 | Reader CPU | Reader RSS 峰值 | 第 10 章冷載至真實頁面 |
|---|---:|---:|---:|
| 全預設、氣泡關 | 9.86% | 662.5 MiB | 0.719 s |
| 全預設、氣泡開 | 19.49% | 763.5 MiB | 8.727 s |
| 完整江湖、氣泡關 | 27.78% | 790.2 MiB | 0.643 s |
| 完整江湖、氣泡開 | 40.40% | 888.3 MiB | 35.058 s |

四組的重複中間頁快照由 176 次降到 0，實際快照繪製 352→192 次。CPU 相對最後一次快照修改前為 9.47→9.86、19.44→19.49、29.56→27.78、40.05→40.40%；只有江湖 OFF 此次觀察到小幅下降，其餘大致持平，不能宣稱整個 App CPU 減半。每種設定僅單輪，沒有統計顯著性結論。RSS 未隨快照重用出現本輪可見的持續無界增長，但這些短窗口不足以排除長期洩漏。

江湖 ON 的 35.058 秒不能藏掉：target network 1908 ms、parse 28381 ms（其中 jsNet 28204 ms），正文 render 1758 ms（imageLoad 1645.4 ms）。與前次 8.718 秒冷載相比，差異主要落在所記錄的書源 JS 網路階段，正文 render 前次 1771 ms 與本次接近；不能把 parse 當 JS CPU，也不能僅憑這些 span 斷言全為遠端伺服器耗時。

最新書評以連續 driver 的 tap 起點到實際「樓層」資料出現計時：全預設 ON 6.177 秒、江湖 ON 6.207 秒，各有六次實際捲動。此數字含命令、sheet、WebView 和觀察成本，不是純 XHR；不拿舊人工觀察空檔計算虛假加速倍數。

最新第 20 章遠跳前確認 spine22 正式快取不存在；從 loading 到首個真實頁面 15.267 秒（network 6855 ms、parse 6407 ms，其中 jsNet 6296 ms、正文 render 236 ms）。滿五槽快取插入目的章後仍保留 22，僅建一次，頁數 9。這確證修正後可以在重主題與全部氣泡下完成真正網路冷跳，沒有原先立刻逐出目的章的循環。

原基線前三組均在初始預載完成後開始；舊江湖 ON 最後一章快取提交晚於起跑 0.944 秒，該 CPU 比較仍有這項限制。另保留一組首屏後立即翻頁的額外壓測：它混入初始四章預取而 CPU 達 33.57%，不放入上述同口徑主表。

完整明細：[最終四組比較](../docs/performance/20260907-comment-bubbles/snapshot-after-live-matrix.md)、[可重算數據](../docs/performance/20260907-comment-bubbles/snapshot-after-matrix.metrics.json)、[未快取远跳](../docs/performance/20260907-comment-bubbles/snapshot-final-cold-jump20.png)。

## 閒置負載的追加核對

最後四組之後，有一次江湖 ON 的書評關閉後 193.260 秒窗口，Reader 平均 CPU 為 6.469%，其間没有新的 SourcePerf、章節 preload 或 snapshot 工作；評論 WebContent 已消失，其餘 WebContent／GPU／Networking 累計 CPU 增量為零。這與較早約 0.94% 的閒置不同，因此另做同 App、同章的對照，不把它刪除。

追加對照在同一個 PID87765、第 10 章、相關章節正式快取皆完整的條件下執行：開書評前 sample 30 秒，開啟第一段、等實際評論、六次捲動、關閉，再 sample 40 秒。按 sample 起點至後續快照的實際程序採樣，前為 0.743%（RSS 峰 825.516 MiB），後為 1.594%（RSS 峰 799.047 MiB）。這輪未重現 6.47%。主執行緒等待樣本占比為 98.55%／98.05%（不是 CPU 百分比），兩段都未見 CoreTextPageEngine、氣泡繪製或 BookSourceSession 熱路徑；部分 JPEG 影像準備樣本不足以證明持續重讀。沒有新的可確證根因，不作猜測式改碼，也不宣稱所有裝置、所有時長的耗電問題已消失。

證據：[閒置原始程序數據](../docs/performance/20260907-comment-bubbles/snapshot-idle-diagnosis-process-samples.csv)、[書評前堆疊](../docs/performance/20260907-comment-bubbles/snapshot-idle-diagnosis2-before.sample.txt)、[關閉後堆疊](../docs/performance/20260907-comment-bubbles/snapshot-idle-diagnosis2-after.sample.txt)。

## 可重現的渲染基準

同一 Simulator、串行測試、120 個相同正文段落，使用 120 個不同 review link 與數字。以 `SourcePerfTrace` 和 `ReaderDocumentTrace` 記錄第一次繪製及後續重用的耗時。矩陣包含無氣泡、跟隨來源 SVG、沒有自訂選取的內建氣泡、保留自訂選取的內建氣泡、自訂氣泡。來源 SVG 情境使用固定 SVG 測資，不是神魔小說的線上正文。

「保留自訂選取的內建氣泡」是使用者匯入主題後切換內建氣泡的情境，並非全部預設。此矩陣的 `realJianghu` 使用真實主題的氣泡素材；不代表整套主題、正文 CSS、翻頁及書評網路的總成本。

回歸同時驗證正文、120 個 review link、120 個 attachment 與裁切後像素不變，避免用刪除氣泡換取較快數字。

## 已確認根因

1. 每次氣泡快取未命中，都對已選取的自訂 SVG 做 `lowercased().contains(...)`，即使當前使用的是內建氣泡。真實素材每章 120 個氣泡在這個步驟累計約 302–306 ms，合成的大型素材約 369–379 ms。改成只檢查本次實際使用的 SVG、實際支援的 `${color}`／`${Color}` token；日夜、普通及強調色仍使用原有流程。
2. 未被原生辨識的文字大小 SVG，在輸出診斷訊息時先掃描整張圖片裁透明像素，實際渲染又裁一次。基準中的診斷掃描累計 576.2 ms，真正裁切 573.5 ms。改成僅裁一次，診斷讀取實際裁切結果。

上述修改沒有新增快取、替代解析或重試，也沒有停用來源氣泡、書評連結或大型主題素材。這兩項量測不能單獨解釋所有多秒延遲及持續發熱，仍需完整線上流程驗證。

## 前後數值

以下為同一 120 段固定內容的毫秒數；首次繪製與快取重用分開，不混成一個平均。

| 情境 | 修正前 ms | 修正後 ms | 解讀 |
|---|---:|---:|---|
| 無氣泡，兩次暖機平均（合成 fixture） | 7.66 | 8.74 | 低基準；不宣稱改善 |
| 原書源氣泡，首次（合成 fixture） | 85.67 | 89.07 | 原有來源路徑，非本次 token 修正對象 |
| 無自訂選取的內建氣泡，首次（合成 fixture） | 162.24 | 159.89 | 原先不掃大型自訂素材 |
| 保留江湖素材選取的內建氣泡，首次 | 433.39 | 157.27 | 約減少 64%，兩邊均實際繪製 120 次 |
| 江湖自訂氣泡，首次 | 486.76 | 235.52 | 約減少 52%，兩邊均實際繪製 120 次 |
| 未辨識 SVG 圖片載入／裁切 fixture | 1176.57 | 708.66 | 約減少 40%；診斷用的額外 120 次裁切消失 |

江湖自訂氣泡的模板符號檢查由 302.5 ms 降至 9.1 ms／120 次；內建氣泡保留江湖選取的檢查由 306.4 ms 降至 0.1 ms。最後採有長度邊界的 UTF-8 精確搜尋，保留兩種支援 token，避免對 base64 圖片內容做 Unicode 正規化／編碼轉換。

江湖自訂氣泡的快取重用前兩次為 18.64／18.92 ms，修正後為 20.15／18.99 ms；改善集中於第一次產生圖片，不能把首次數字套用到每一次翻頁。`realJianghu builtinClean` 在兩輪已重用前一矩陣的內建快取，故上表改用確實各繪製 120 次的合成 fixture 作內建首次比較。

原始證據：[修正前](../docs/performance/20260907-comment-bubbles/before.txt)、[修正後](../docs/performance/20260907-comment-bubbles/after.txt)。前後測試包：`/tmp/YueduCommentPerf-baseline2-20260907.xcresult`、`/tmp/YueduCommentPerf-after3-20260907.xcresult`。這是單機診斷數據，沒有統計信賴區間或實機耗電結論。

直接回歸：`CommentBubblePerformanceTests` 5、`CommentBubbleSVGRecognizerTests` 12、`CommentBubbleRecognitionModeTests` 6、`ParagraphReviewRenderingTests` 1，共 24/24 通過，各輪 xcodebuild 結束碼 0，無 runtime warning。顏色回歸實際比對兩種 token 的日／夜、普通／強調共八種 RGBA 結果。

## 已執行的 Simulator 流程

- 來源匯入：1/1 通過，`/tmp/ReaderScenario-source-before.xcresult`。
- 主題匯入：1/1 通過，`/tmp/ReaderScenario-theme-before.xcresult`。
- 本機 UI 驅動以 XCTest 真實點擊、拖曳操作；正常閱讀、月票榜、目錄、正文、段評／本章說以及四組連續跨章均已實際操作。原始登入擷取只留私有本機目錄，不納入報告或版本庫。
- 實際 UI 切換至預設外觀，確認全局字型回到系統字體；再切回江湖俠客，確認主題選中、Huiwen-mincho 與背景圖恢復。StoreKit／主題切換 UI 測試 1/1 通過、0 runtime warnings（`/tmp/ReaderUI-theme-activated2.xcresult`）。這是外觀切換驗證，不冒充「全部閱讀設定重設」或完整閱讀效能比較。畫面：[預設外觀](../docs/performance/20260907-comment-bubbles/appearance-default.png)、[江湖外觀](../docs/performance/20260907-comment-bubbles/appearance-jianghu.png)。
- 登入模式切換曾出現背景發布 SwiftUI 狀態警告。定位到 ExploreHomeView 收到 JS 背景執行緒的登入／來源變數通知後直接 reload；改在 UI 訂閱邊界 `receive(on: DispatchQueue.main)`。重走相同登入模式切換，確認 `reLoginView FIRED`、UI 更新及測試通過，runtime warning 由 1 降至 0（`/tmp/ReaderUI-mainqueue-after.xcresult`）。
- 每秒採集 CPU 累計時間與 RSS，只納入指定 Simulator 的 Reader 及 WebKit 子程序。依操作事件的 monotonic 起終點分段，排除設定、冷啟動與等待操作的空檔；書評另列。
- Simulator 不提供本輪實機電池與機身溫度結論；CPU 百分比以單核心為 100%，RSS 也不是實機的精確耗電指標。

## 主題匯入的相容性結果

正式匯入器另列出無對應設定：部分書架版型與標籤、獨立夜間強調色、卡片內距與圓角、連續字重、可變首行縮排／對齊、段落空白行、氣泡固定尺寸／圓角／透明度、部分章節標題規則。主題的氣泡依原作者設定隱藏數字；不擅自改成顯示。章節標題的日夜圖層數與畫布高度不同，正式相容層使用明示的匯入規則處理。這些匯入提示與六項 EPUB 功能缺口是不同範圍，不能宣稱所有外部主題欄位均一比一套用。

## 線上高壓測試根因與修正

跳到第 10 章後，目的章節已排版完成，卻被容量五章的 LayoutCache 立即淘汰。原因是淘汰中心仍停在舊章節；完成事件再要求顯示佔位頁並預載，形成反覆重建。不是單純伺服器慢：紀錄中可見約每 10ms 完成／重開同章排版。

同一 Reader 程序的 CPU 累計時間差量：正常第 2 章靜止 47.24 秒平均 0.72%；卡住第 10 章的 118.08 秒平均 105.22%（單核心 100%）。卡住時 sample 主執行緒 2853 個樣本中 2160 個落在 preload 工作，與 log 的循環一致。這兩段是狀態診斷，尚非完整四組主題與氣泡比較。RSS 分別最高 901.45／576.39 MiB，不能用 RSS 較低否定 CPU 異常，也不能推導實機溫度。

另外確認：

- 空 nextContentUrl 規則仍先排隊取得共享 session 鎖，讓已完成的章節等其他預載網路請求。空規則應在進鎖前直接結束。
- 普通內容 ready 通知會取消已在進行的同章 document，造成成功前的影像載入失敗與重建；明確重新抓取才應失效舊內容。
- 線上章節 HTML 的 base64 圖片 bytes 被當作正文大小估頁，導致淘汰後全書估頁膨脹。估算應使用既有可見文字轉換流程。
- chapter.parse 包含 session 排隊，不能將它減去 chapter.jsNet 就當成 JS CPU。

線上原始耗時：[SourcePerfTrace](../docs/performance/20260907-comment-bubbles/online-before-sourceperf.txt)；[CPU 分段數據](../docs/performance/20260907-comment-bubbles/online-before-cpu.json)；[卡住畫面](../docs/performance/20260907-comment-bubbles/stuck-chapter10-before.png)。仿真、段評與本章說截圖亦保留在同目錄。


已修正上述四條生產路徑：在預載前同步穩定 `(spineIndex, charOffset)` 閱讀錨點及淘汰中心；區分普通 available 與真正 replaced；空規則進鎖前返回；可見文字大小沿用既有轉換入口。此外修正純文字標題混入原始 SVG 設定字串、以及非可見章節 ready 擴張預載視窗搶占來源鎖的觸發點。沒有新增平行快取、重試或延遲路徑。

修正後四組每秒最多完成一次 preload，完成後目的章節缺失皆為零；修正前同一秒曾完成 95 次並全部逐出目的章節。這是對已重現的無限重建根因的 before/after 證據，不表示所有網路與主題耗時都已消除。

## 快照去重前的四組基線與冷載

每組重新啟動 App、備份並清除本書的完整章節快取、清除書源持久 `qd_title_svg`（保留登入與三個旗標），從第 10 章第 1 頁開始。全預設移除整套閱讀／外觀覆寫；唯一共同指定是使用者要求的仿真翻書。江湖組恢復完整匯入設定，包含字型、背景、標題、版面與氣泡。

| 指標 | 全預設・氣泡關 | 全預設・氣泡開 | 江湖・氣泡關 | 江湖・氣泡開 |
|---|---:|---:|---:|---:|
| 有效連續翻頁 | 50/50 | 50/50 | 50/50 | 50/50 |
| 實際跨章 | 4 | 4 | 5 | 4 |
| Reader 平均 CPU | 9.47% | 19.44% | 29.56% | 40.05% |
| Reader RSS 峰值 MiB | 661.578 | 761.141 | 802.094 | 890.594 |
| 第 10 章冷載至首個真實頁面 | 0.737 s | 11.205 s | 0.725 s | 8.718 s |
| 翻頁窗口正文 renderLeaves 合計 | 45 ms | 1375 ms | 83 ms | 1536 ms |
| 翻頁窗口 chapter.network 合計 | 2115 ms | 2346 ms | 2502 ms | 1753 ms |
| 翻頁窗口 chapter.parse 合計 | 73 ms | 12694 ms | 86 ms | 12386 ms |
| 目標快取立即被逐出 | 0 | 0 | 0 | 0 |

每組 50 次真實 tap 約 77～80 秒，約每 1.5～1.6 秒翻一頁，CPU 用同窗口首尾累積 CPU 秒差除以實際採樣跨度（100% 為一核心）。每頁由可及性頁碼逐一驗證連續變化，章界由 Reader trace 再交叉核對。相同 tap 數因圖片占位與字型而跨越不同頁數／章數，不是相同文字量的渲染 microbenchmark。

冷載計時從目標章節 `loading` 到首個 `pageVC REAL`，不把 XCTest 啟動算入。開氣泡時預設／江湖的初章來源 `jsNet` 分別 5.910／3.667 秒，網路波動不能解讀成江湖更快。`chapter.parse` 包含來源鎖排隊與 JS 網路，不是 CPU 時間；各 trace 可能內含或重疊，不能相加當端到端。預設 ON 有一筆預載 parse 在翻頁窗口結束後才完成，表中只計窗口內完成者。

在這次操作窗口中，整套江湖相對全預設多約 20 個 CPU 百分點；氣泡 ON 相對 OFF 再多約 10 個百分點。這包含全部主題繪製、來源 API、圖片與排版，不能全歸到氣泡畫圖或 CSS 解析。高壓操作的 40.05% 也不能直接和原先卡住時的 105.22% 算同情境降幅。

畫面：[全預設關](../docs/performance/20260907-comment-bubbles/default-off-chapter10.png)、[全預設開](../docs/performance/20260907-comment-bubbles/default-on-chapter10.png)、[江湖關](../docs/performance/20260907-comment-bubbles/jianghu-off-chapter10.png)、[江湖開](../docs/performance/20260907-comment-bubbles/jianghu-on-chapter10.png)。


## 快照去重前的書評與關閉後閒置

兩個來源 ON 組均點第 10 章第一段的氣泡，再作六次真實捲動；江湖組確認顯示 80 條段評，捲動至第 2/4 頁。書評成本與正文翻頁窗口分開。

| 窗口 | 全預設 ON | 江湖 ON |
|---|---:|---:|
| 六次捲動 Reader CPU | 8.96% | 8.32% |
| 活躍評論 WebContent CPU | 13.04% | 12.68% |
| 評論 WebContent RSS 峰 MiB | 443.922 | 463.469 |
| 關閉後正文觀察跨度 | 81.579 s | 109.276 s |
| 關閉後 Reader CPU | 0.99% | 0.935% |
| 關閉後原評論程序 | 已退出 | 已退出 |
| 關閉後其餘 WebContent／GPU CPU | 0% | 0% |

兩次都以 sheet 把手下拉關閉；沒有把來源 HTML 關閉按鈕的行為算成已修。江湖關閉後 5 秒 sample 的主執行緒 3149/3174 樣本位於 mach_msg 等待，未觀察到持續背景熱循環。程序消失由同一 Simulator 其他程序仍持續每秒採樣核對，並非採樣停止。

書評骨架的「关闭」按鈕會先出現，不能當作評論資料載入完成。全預設點擊後至觀察資料的約 119 秒、江湖連續 wait 後至下次操作看到資料的間隔，都包含工具／操作空檔，不能當網路延遲；本輪未取得能可靠單獨對應該書評 XHR 的 span，因此不虛報書評資料載入秒數。正文冷載計時則有 loading→REAL trace，已列上表。

## 回歸與證據

所有程式碼修改後均實際執行直接相關測試，未以 diff 檢查替代。原生氣泡 24/24；線上核心第一輪 7 類 83/83，最後新增標題分支的 OnlineReaderPipelineUnificationTests 27 tests / 29 runs 以及 ReaderChapterPresentationTests 12/12 通過。後兩輪與前面的類別有重疊，不相加為獨立測試總數。

六項 EPUB 缺口另有 typography 35 tests、media/ruby 29 與 13、selection 5 通過。media/ruby 兩輪各記錄一筆 AVAudioSession 主執行緒啟用警告，不能宣稱整個專案沒有 runtime warning；氣泡、線上核心與最終四組 UI 結果另逐包核对。

可重算資料：[各輪實際回歸結果](../docs/performance/20260907-comment-bubbles/regression-results.json)、[修正後 SourcePerfTrace](../docs/performance/20260907-comment-bubbles/online-after-sourceperf.txt)、[四組逐秒程序數據](../docs/performance/20260907-comment-bubbles/final-continuous-process-samples.csv)、[冷載階段](../docs/performance/20260907-comment-bubbles/final-cold-loads.json)。快照去重前明細與逐次頁碼另見同目錄 final-live-matrix.md / final-matrix.metrics.json；快照去重後的最終四組另列於本文末。

最終保留 Simulator 的已登入書源、完整江湖主題、三種來源氣泡 ON 與仿真翻書。未對使用者實機安裝、未做真實 StoreKit 付款，也不從 Simulator 推論實機電池／溫度。仍可觀察到完整主題与來源 API 的額外成本；本輪確認並消除了自我逐出／取消重建造成的異常持續工作，以及原生氣泡首次產圖的冗餘處理。


## 追加：仿真背面快照重複繪製與修正
四組測試後再作30次翻頁及40秒stack sample，19個不同的中間頁各有2次renderSnapshot render，分別來自transitionViewControllerStack與pageViewControllerAfter。現有snapshot只快取首／末頁，中間頁於同次curl重畫兩次；同窗無章節preload done，已與前述章節無限循環區分。此表保留為快照去重前基線，新的最終四組在下節另列。不能把全部約20pp主題差都归因此處。


快照修正已沿用既有 NSCache 的装置分級容量（16/32/64–128 MiB）與張數（4/6/12），把中間頁也納入，鍵使用已安裝 layout 的 revision、spine、localPage。內容、尺寸、外觀、記憶體警告使舊鍵失效；背景產圖返回時也須通過相同 revision 檢查，避免把失效前的圖片重新塞回快取。

固定 CJK fixture 24 頁各請求兩次、共三輪：中位數 189.221→102.307 ms（−45.93%）；144 次請求的實際畫圖 144→71，cache 命中 0→73。每對第二次皆重用；另有一次跨輪保留命中。外觀首中末頁 PNG 變色、refetch 正文像素、resize 新尺寸與過期非同步結果拒收均實際回歸；4 項快照 + 13 項供應 + 11 項刷新 + 17 項呈現契約，共 45/45 通過，零 runtime warnings。微基準含前後 SourcePerfTrace，不能當成整個 App CPU 的降幅。

證據：[快照修正前](../docs/performance/20260907-comment-bubbles/snapshot-before.txt)、[修正後](../docs/performance/20260907-comment-bubbles/snapshot-after.txt)、[數字 JSON](../docs/performance/20260907-comment-bubbles/snapshot-comparison.json)。
