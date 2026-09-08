# 執行紀錄

## 2026-09-07
- 已讀專案規約、功能差異報告、yuedu-tour、yuedu-ios-design、檔案規劃與平行問題分工技能。
- 使用者已明確授權補齊所有報告缺口及指定書源/主題登入與閱讀測試；沿既有行為補齊，不另開產品設計批准流程。
- 建立本轮驗收計畫，未將登入資訊寫入文件。

## 本輪驗證進度
- BrowserTextInteractionTests：5/5 passed（/tmp/ReaderSelection-20260907-3.xcresult）。實測發現emoji右半選字誤用caret insertion index，已修；含RTL幾何、annotation overlays、note markers回歸。
- 根據使用者要求新增全部預設/完整主題與氣泡OFF/ON/打開書評比較矩陣。
- 建立乾淨的 Yuedu Reader Profiling Simulator（尚未boot，以免干擾串行回歸）。
- 排版7類相關回歸正在串行；之後bubble baseline再media/TTS。
- 真正10分鐘UI閱讀尚未開始，不得提前宣稱已完成。

- Typography：35方法/37次執行全過（/tmp/BrowserTypography-20260907-8.xcresult）。包括原先真CJK粗體fallback Regular問題修復。
- 氣泡baseline：CommentBubblePerformanceTests 4/4 passed（/tmp/YueduCommentPerf-baseline-20260907.xcresult）；保留 /tmp/yuedu-reader-perf-baseline.app。詳 /tmp/yuedu-comment-perf-baseline-metrics.txt。此輪builtin保留selected custom template，下一輪將分builtinClean/RetainedCustom。
- 媒體/TTS在串行回歸中，第一輪結果待agent讀取；其後perf加精確template instrumentation baseline。
- Root已新增opt-in LocalReaderScenarioTests（共享服務匯入source/theme）與 LocalReaderProfilingUITests（真正XCTest點擊/拖曳/secure input，/tmp指令，非產品入口），用於稍後乾淨Simulator全流程。
- CPU sampler草稿 /tmp/yuedu-reader-profiling/sample_processes.py，僅採指定Simulator的Reader/WebKit程序，每秒紀錄CPU累計和RSS，尚未啟動。

- 乾淨 Profiling Simulator 已boot，Source與Theme正式服務匯入各1測試passed（/tmp/ReaderScenario-source-before.xcresult、/tmp/ReaderScenario-theme-before.xcresult）。主題含font、cover、overlay、chaptertitle；不支援項目由正式匯入結果列出 /tmp/yuedu-reader-profiling/theme-import-result.txt。
- UI Driver完成15條真實指令、來源登入帳密欄位與提交，UI測試正常結束；HTTP401（App與獨立相同端點）導致未登入、排行榜未取得。已詢問使用者有效登入資料，不擅自替換書籍或聲稱完成10分鐘。
- baseline2矩陣4/4通過；active-template掃描約302–379ms/120氣泡，builtin保留custom時同樣承受；修正準備進入after回歸。

- 最終氣泡修正after3及相關24/24全部passed，root以xcresulttool重讀四結果確認0failed/0runtimeWarnings。冷繪製120個：江湖custom486.76→235.52ms、retained builtin433.39→157.27ms，diagnosticTrim1176.57→708.66ms；原始資料已存docs/performance/20260907-comment-bubbles/。
- ExploreHomeView兩個source通知訂閱已receive(on: DispatchQueue.main)，正在build並準備重走實際UI模式切換。

- 最後Explore UI回歸 /tmp/ReaderUI-mainqueue-after.xcresult 1/1 passed、0runtimeWarnings，確認相同reLoginView事件。首次編譯缺少Combine import已補齊並重建成功。
- 乾淨Simulator未有Pro導致UI以預設配色呈現；使用既有Configuration/YueduPro.storekit與SKTestSession本機測試交易（無真實付款、無正式授權改動），確認江湖主題選中，預設/江湖切換字型正確恢復。中間一次driver沿用舊label而失敗，改正指令後 /tmp/ReaderUI-theme-activated2.xcresult 1/1 passed、0runtimeWarnings。
- 最終App保存 /tmp/yuedu-reader-perf-after-final.app；原生測量after快照與before-instrumented保留。已停採樣/log stream並移除UI opt-in enabled檔，避免日常測試等待本機命令。
- 整體任务未完成：仍待有效來源登入資料，月票榜第一名、全部預設/整套主題的閱讀CPU/RSS矩陣與10分鐘仿真/書評尚未執行。


2026-09-07 continuation: User login succeeded; live monthly rank #1 夜无疆 loaded819 chapters; >10min reading/review UI then requested stress. Far jump chapter10 reproduced cache immediate self-eviction loop;118.08s avg105.22% readerCPU vs47.24s idle0.72%. Perf agent fixing stable position/cache anchor, availability vs replacement, empty nextContent queue, text-size estimate. Four-way real UI matrix remains pending.


### 2026-09-08 最終四組連續跨章
使用者登入已成功，月票榜首《夜無疆》與完整江湖主題已使用。四組固定第10章第1頁、冷章cache及乾淨持久標題、各50次真實curl：全預設OFF/ON CPU9.47%/19.44%，江湖OFF/ON29.56%/40.05%；RSS峰661.578/761.141/802.094/890.594 MiB。200/200連續頁碼有效，跨章4/4/5/4次，最大preload done1/sec、完成後缺目的layout0。以前105.22%卡死根因已修，不把操作CPU與idle直接算降幅。全預設ON書評關閉後81秒Reader0.99%，評論PID已退出，其餘WebKit/GPU0。細項與口徑見Technotes/ReaderCommentPerformance-20260907.md。


### 2026-09-08 最終完成與界線
快照已沿用同一有界NSCache按layout revision/spine/localPage去重，144fixture請求render144→71、中位189.221→102.307ms；4+13+11+17共45項直接回歸通過。後續正式settled四組各50次全部有效，CPU9.86/19.49/27.78/40.40%，RSS峰662.5/763.5/790.2/888.3MiB，快照重畫176→0；未以fixture降幅冒充整App CPU降幅。追加未cache第20章遠跳15.267秒僅建一次保留目標；江湖ON第10章一次35.058秒含28.204秒jsNet，不隱藏。書評真資料約6.18/6.21秒；一段193秒idle6.469%未在同App同章前後sample重現（0.743→1.594%），保留限制且不猜根因。詳細原始證據與最終報告Technotes/ReaderCommentPerformance-20260907.md；采樣/logstream停止，來源登入與江湖/氣泡ON保留，無commit。
