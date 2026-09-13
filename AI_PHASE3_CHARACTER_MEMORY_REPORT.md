# AI Phase 3 人物建檔實作與驗證

## 工作區與正式入口

工作區 `/Users/zhangruilin/Desktop/Yuedu-reader`，分支 `main`，起始 HEAD `62c2656b114d64f4f5628b161d07abde949021dd`。本次不 commit、切分支或改動測試 wrapper。起始有 21 個 Phase 2 待提交路徑；本次只在其中的聊天工具列、AI 狀態、診斷與三語資源加入人物建檔接線，其餘原有待提交檔案保持起始內容。

正式入口：閱讀器 AI 面板工具列的「逐批人物建檔」，以及既有人物列表／AI 狀態頁。鏈路為 `AICharacterMemoryView` → `AICharacterMemoryService.prepare/start/resume` → `AIMemoryPlanner` → `AIMemoryExtraction.input` → 既有 `AIProviderAssembly` / `AITracedProvider` → `AIMemoryExtraction.validate` → `AICharacterMemoryStore.commit` → 有 book/source/boundary 的 `view` → 人物卡。沒有 embedding 前置工作，沒有改動 Phase 2 搜尋切塊、問答迴圈、provider transport 或 CoreText。

## 工作範圍與呼叫授權

建檔範圍可選截至目前已驗證閱讀位置，或本機可用全書正文。工作固定 source snapshot 與來源邊界；位置前進不會自動擴大。查看範圍獨立，預設目前閱讀位置，可回看較早章節；查看後文需再次確認，不因已建全書資料而自動放寬。

規劃不呼叫模型、不保存工作。確認頁列實際設定的 provider/model、範圍、主要正文 Character／UTF-16／UTF-8 bytes、批次數、可重用批次、總呼叫上限及每批輸出上限。tokens 與金額未知；不記錄 API key 或私人 endpoint，端點只取 digest 作重用身分的一部分。

預設每批 1,200 Character，優先章節／換行切分；同章之前最多 200 Character 作輔助。來源分成不超過 200 Character 的短 segment ID。輸入最多 10,000 Character／32,000 bytes，每批輸出 4,096 tokens，最多 8 筆相關早期人物背景（每筆最多 2 項早期事實），工作預設 100 次呼叫，可在 UI 明確調整。這是人物抽取設定，不修改每題問答的 4 次／1,024 輸出 token 預算。

全部可用且允許的主要區間都進計畫，包括書信、敘述及沒有對白的段落。輔助區間不計入主要覆蓋。缺失／抽取失敗／格式不支援章節保留原因，不算零字成功；UI 分列目錄目標、可分析／已分析章節、已保存單位、主要正文 UTF-16、缺失範圍。完成文案只表示本機可用範圍已分析。

## 保存、證據與人物投影

產品資料在本機 `Application Support/AICharacterMemory/<bookID>/`：active 指標、小型 job checkpoint、獨立 plan、每單位一個原子 record envelope、獨立合併決定。每批只寫該批記錄與小型工作狀態，不重寫整本人資料。job 保存來源 manifest、範圍、provider/model、analysis/prompt 版本、預算、累計呼叫、in-flight 單位及失敗原因；record 保存主要／輔助來源身分、實際背景單位依賴、提及、事實、合併提案、safeAfter 與 committed 標記。

提及使用來源證據衍生的 entityID，名稱僅是標籤。同名不同來源不自動合併；蒙面人等暫定稱呼保留 unresolved。事實保留 narration、statement、rumor、interpretation、correction、relationship 類型；後文修正新增記錄，保留前期聲稱和傳聞。預設按原文揭露位置排列。

模型只選送入本次的 segment ID 與逐字短引文。App 核對引文在指定片段中唯一出現，再計算 source UTF-16、章節 ID、正文 digest、轉換版本。捏造 ID、錯引文、同片段重複或重疊引文、非人物類型或不完整 schema 整批拒收。完整 JSON 與合法來源位置只證明機械契約，不證明語意。

合併提案有獨立原文證據，須由使用者確認，同名或模型信心不直接合併。確認／撤回只改關係決定；原 entityID、名字、事實與證據不重寫。每次查看只從當下允許的關係建立分組，沒有跨進度保存的全書 union-find。決定限相同 snapshot；新增章節後舊抽取可以重用，但原合併決定保守要求重新確認。

人物卡由已保存資料直接形成，包含可見稱呼、未決狀態、目前找到最早的明確提及、經歷／關係類型、原文與章節。人物列表每頁 40 筆並可搜尋，經歷每頁 30 筆，沒有前 N 人或 TopK 生平截斷。看卡片不追加模型呼叫。閱讀器 AI 面板入口使用既有 source UTF-16 引用跳轉；其他入口保留引文並明示無法精準跳轉，不猜 offset。

本次沒有自然語言簡介潤飾，也沒有把人物記憶接到問答、TTS、既有人工卡或說話人名單。聊天仍使用 Phase 2 原文檢索；不能把本次交付稱為聊天事件記憶已接通。

## 防劇透、續跑與增量

直接引文位置與 safeAfter 分開。safeAfter 取整批實際送入的主要／輔助正文及背景事實之最大依賴位置；即使模型只引用批次前半，也不能降到前半。背景僅選取該批之前、來源身分有效且詞面相關的記錄，不讀後文卡片或已合併真名。人物名、搜尋、卡片、統計都在安全投影後計算。

合成案例：第 40 章蒙面人；第 620 章揭露蒙面人就是柳青。第 500 章視圖只有蒙面人一張卡、沒有柳青搜尋結果或別名關係；第 650 章可見揭露前後的三筆暫定實體及兩個合併提案。確認後為一張包含兩個可見稱呼的卡；退回 500 章仍只有原蒙面人卡。撤回後恢復三個原始實體。這些是 production 投影實際測試斷言，不是模型語意品質宣稱。

模型呼叫前先原子保存累計次數和 in-flight reservation；即使未收到結果也不把已預留次數歸零。結果與 committed 標記同一原子檔案，保存失敗不增加完成範圍；commit 後、checkpoint 前重啟可以辨識已存結果，不重複插入。網路結果不明、取消或未保存中斷顯示可能已計費，需手動確認續跑，不宣稱外部請求 exactly-once。

每書並行度 1；離開畫面／退背景同時取消尚在建立 checkpoint 的啟動／續跑動作與當前 owner，傳送前及保存後再次核對取消狀態。晚到回覆不能提交或覆寫新續跑預算；新工作有獨立 active job 身分。預算用完暫停，增加額度需確認。一般 schema／證據／服務失敗沒有自動重試。預設 length 也暫停；只有事先開啟選項時允許有限二分（UI 一層），父／子共享原工作呼叫額度，覆蓋只算 leaf 單位。手動分拆最多兩層，未知 in-flight 不能直接當作未呼叫單位分拆。

單位身分核對主要區間、章節 digest、此前 manifest prefix、轉換、analysis/prompt、provider/model/configuration 和影響輸入的預算設定；保存實際背景單位 ID 並驗證其仍有效。尾端新增章節不更改前面單位身分，不直接重標舊 record 的 sourceVersion。等長改文、補上較早缺失章節或分析設定變更，保守使受影響位置起的後續解讀失效。舊版本保留在磁碟，不進目前有效視圖；同一章尾端擴充會保守重建該章。

清除本書人物建檔會取消工作並刪除此 book 的 feature 目錄，保留正文、聊天、既有卡片／名單及人工語音設定。書籍刪除也接上此清理；不是常駐背景工作。

## 驗證記錄

基線：`AIPhase2ConversationTests` 27 項通過，`/tmp/yuedu-phase3-baseline.log`，wrapper exit 0。早期服務編譯另跑 Phase 1 repair 6 項通過；不拿此結果代表最後變更。

最終新增回歸 `AIPhase3CharacterMemoryTests`：23 個 Swift Testing tests 通過（其中輸出拒收測試含 9 組參數），wrapper exit 0、`TEST SUCCEEDED`。日誌 `/tmp/yuedu-phase3-delivery-AIPhase3CharacterMemoryTests.log`。此 run 已編譯最後修改後的 App 與測試 target，不另做 clean。來源清單自此 run 至交付保持不變。

合成長篇工作實測 650 章跨 3 個 store instance 續跑，再新增 2 章：652 個主要單位、652 次 mock 外部呼叫、652 個已保存單位；9,662 Character／9,662 UTF-16／25,308 UTF-8 bytes；實測 10,298.76 ms（Simulator、本機 fixture）。沒有把章節數或字數換稱 token，也不將此耗時當真實 API 吞吐。新增章節工作只消耗 2 次呼叫，650 個既有單位重用；85 人卡片測試另驗證列表分頁與無額外摘要呼叫。

影響面回歸結果於下表列出。

| 類別 | Swift Testing tests | 結果 | 日誌 |
| --- | ---: | --- | --- |
| `AIPhase1RepairTests` | 6 | 通過，exit 0 | `/tmp/yuedu-phase3-delivery-AIPhase1RepairTests.log` |
| `AIPhase1IntegrationTests` | 18 | 通過，exit 0 | `/tmp/yuedu-phase3-delivery-AIPhase1IntegrationTests.log` |
| `AIPhase2ConversationTests` | 27 | 通過，exit 0 | `/tmp/yuedu-phase3-delivery-AIPhase2ConversationTests.log` |
| `AIAssistantFeatureTests` | 19 | 通過，exit 0 | `/tmp/yuedu-phase3-final-AIAssistantFeatureTests.log` |
| `AIAgenticAssistantTests` | 10 | 通過，exit 0 | `/tmp/yuedu-phase3-final-AIAgenticAssistantTests.log` |
| `AIProviderTests` | 13 | 通過，exit 0 | `/tmp/yuedu-phase3-final-AIProviderTests.log` |
| `AISpeakerRosterTests` | 8 | 通過，exit 0 | `/tmp/yuedu-phase3-final-AISpeakerRosterTests.log` |
| `TTSRoleVoiceCastTests` | 15 | 通過，exit 0 | `/tmp/yuedu-phase3-final-TTSRoleVoiceCastTests.log` |
| `TTSSpeakerAnnotatorTests` | 15 | 通過，exit 0 | `/tmp/yuedu-phase3-final-TTSSpeakerAnnotatorTests.log` |
| `ChunkCharacterOffsetTests` | 5 | 通過，exit 0 | `/tmp/yuedu-phase3-delivery-ChunkCharacterOffsetTests.log` |

新增 23 項與上述既有 136 項合計 159 個 Swift Testing tests；未將重跑次数、參數組數或 fixture 的 652 次模型替身呼叫重複算成測試數量。

既有問答／引用／TTS 的程式與各自測試範圍未改，沿用本次工作區已通過的相關回歸；最後的生命週期補強已重跑完整人物測試類別，沒有用較早的 22 項結果代替最後變更。另修正共用 `AITextCoordinates.uniqueRange` 對重疊引文的歧義判定：第二次搜尋從首次命中的下一個 Character 開始，避免把「人人人」中的「人人」誤認為唯一；因此 Phase 1／2 與引用定位也在此修正後重跑。

使用 `/Applications/Xcode-beta.app/Contents/Developer`，以 `scripts/sim.sh` 解析本次 destination `id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`。所有測試由 `scripts/xctest.sh` 逐類執行，關閉 parallel testing；未使用裸 `xcodebuild test` 或改寫 wrapper。典型命令：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
YUEDU_DEST=id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400 \
bash scripts/xctest.sh -l /tmp/yuedu-phase3-delivery-AIPhase3CharacterMemoryTests.log -- \
  -only-testing:'yuedu appTests/AIPhase3CharacterMemoryTests'
```

靜態檢查：`ruby scripts/check_localizations.rb` 通過（三語各 2,855 鍵）；`git diff --check` 通過。標題模式掃描確認本次新增推入頁／sheet 均為 inline；沒有順帶修改其他既有頁面。

初輪失敗如實保留：`/tmp/yuedu-phase3-tests.log` 因刪書呼叫 main-actor service 的隔離錯誤未編譯；`/tmp/yuedu-phase3-tests-v2.log` 因新增測試缺少 `try` 未編譯。修正後 v3 的 21 個 Swift Testing tests 通過，後續再加入同時續跑測試與 activation 保護，因此以最終回歸為交付證據。

## 限制與未實測

全部開發驗證使用本機合成文字與外部模型替身，未呼叫真實 API、下載小說或模型、上傳私人正文。沒有真機操作／完整人工點按 UI 驗收，也未評估真實模型的人物漏抽、同名誤合併、事件證據語意、發言誤分類或模型自帶知識造成的劇透。資料隔離不能宣稱消除了所有生成劇透風險。可沿用 `AI_QA_EVALUATION_TEMPLATE.md` 驗收問答；真實抽取需日後明確授權並先用少量章節與有限預算。

`AI_PHASE3_TRACE.testFixture.json` 從 production pipeline 實際捕捉的 trace 匯出；標示 origin=testFixture、externalModel=mock。一般診斷只有單位、來源 digest、位置、數量、呼叫與驗證／保存狀態；人名、正文、事實仍需事先 opt-in 與選擇匯出，未捕捉內容標 unavailable。

## 本階段修改檔案

- 修正 `Modules/Core/AI/AISourceSnapshot.swift` 的 literal quote 唯一性檢查，拒絕重疊命中，不改來源座標契約。
- 新增 Core：`Modules/Core/AI/AICharacterMemory.swift`、`AICharacterMemoryPlanner.swift`、`AICharacterMemoryExtraction.swift`。
- 新增服務與儲存：`Modules/Services/AI/AICharacterMemoryService.swift`、`AICharacterMemoryStore.swift`。
- 新增 UI：`Modules/Features/AI/AICharacterMemoryView.swift`；接線 `AIAssistantPanelView.swift`、`AICharacterListView.swift`、`AIStatusView.swift`。
- 整合 `Modules/Services/AI/AIDiagnostics.swift`、`Modules/Services/LibraryStore/BookStore.swift`；三語 `Resources/*/Localizable.strings` 新增 81 個同步鍵。
- 新增 `Tests/iOS/yuedu appTests/AIPhase3CharacterMemoryTests.swift`，本報告與 `AI_PHASE3_TRACE.testFixture.json`。

交付程式／資源／測試與既有待提交工具檔的 SHA-256 對照位於 `/tmp/yuedu-phase3-delivery-source-identity.json`，排序內容的整體 SHA-256 為 `d3f8df4c4ed5ee5eec6ccc4dd77c9242743f17d4b7317fe703f488bc164c3647`。HEAD 相同並未被當作工作區內容相同的證據。
