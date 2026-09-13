# AI Phase 2 實作與驗證報告

## 工作區與依賴

本次從 `62c2656b114d64f4f5628b161d07abde949021dd` 開始，開始時工作區乾淨。Phase 1 的 scanner API 問題已由已發布的 YueduCoreText **0.5.0** 解決；Xcode 的 resolved revision 為 `1bbe08accd9342cfdd68cc27c26bcb9f79c6a89b`。實際 checkout 宣告與 App 呼叫均為 `scan(input:writingMode:)`。本次未更換套件或修改排版語意。

修改前基線：正常 `.xcodeproj` 透過 `scripts/xctest.sh` 選取 `AIPhase1RepairTests`，6 項通過、`TEST SUCCEEDED`、wrapper exit 0。記錄 `/tmp/yuedu-phase2-baseline.log`。基線來源清單 SHA-256 記錄於 `/tmp/yuedu-phase2-baseline-sha256.txt`，不把它當成後續工作區的驗證。Xcode 執行後 `project.pbxproj` 有四處 exception-set 顯示註解正規化，沒有 target／依賴／建置設定差異，保留此工具產生的變更。

本次在原工作區實作，未 commit、切分支、reset 或 stash。文末列本次回歸使用的來源身分與結果；不是沿用 Phase 1 的 147 項歷史 run。

## 正式呼叫鏈

`ReaderView` 的本機 source snapshot／已驗證閱讀位置 → `AIAssistantPanelView.send` → `AIQuestionContext` → `AIAssistantService.answer(context:onStage:)` → 原有 `AIAgenticAssistant` 的 `answerQuestion` 模式 → `AIBookRetrievalIndex.retrieve`／`AIQuestionSourceReader` → `AIQuestionPrompt.assemble` → 既有 traced provider → `AIRAGPipeline.result`。

舊 `answer(question:bookID:adapter:progress:boundary:)` 入口也委派同一條新路徑。沒有新增第二個 transport、source loader、持久索引或問答快取。人物卡使用的既有 agentic 任務模式未擴大；本次問答模式共用原 agentic namespace、retrieval、provider、RAG parser 和診斷。

`AIQuestionContext` 固定 requestID、bookID、conversationID、原問題、source snapshot、source UTF-16 boundary、歷史與 `AIQuestionBudget`。目前位置由 adapter 的 mapping 驗證結果決定；無法驗證時 offset 保留 0，不從畫面一整頁推測已讀內容。

## 歷史與保存

- 沿用 `AIChatStore` 與每本書最多 30 個對話／每對話 60 則訊息；沒有遷移或刪除舊聊天。
- `AIChatMessage` 新增可選 `provenance`／`notices`，舊 JSON 缺欄位仍可讀、可顯示；局部缺欄位或格式無效的 provenance 以明確相容分支視為未知 scope，記錄泛用錯誤但保留聊天文字。這個分支可在不再支援舊聊天時移除。未知 metadata 不參與模型上下文。
- 完成回合保存來源邊界、request／book／conversation ID、完成狀態、曾送出的 evidence（含範圍、parentID、來源種類）、最終 evidence IDs、使用的歷史 message IDs。邊界代表整個請求依賴上限，不以最後引用位置替代。
- 同書、同對話、同來源且 completed 的訊息才可用；全書、較晚閱讀點、失敗／取消／pending 或未知 scope 會被排除。前進可沿用安全舊回合；回跳或縮限不能帶入較寬回合。
- 最近最多 6 則，另受 6,000 UTF-8 bytes 上限。從最近往前保留連續窗口；超額時不跳過最新訊息再偷偷使用更早背景。使用者與助手歷史都標為 conversation data、evidence=false。它們可幫助理解問題，不能作原文引用；不讀人物卡、別名表或舊摘要來猜指代。
- UI 每個請求有 owner（request／conversation／book／boundary）。取消、換書、換來源、換對話、縮限都使舊 owner 失效；service 也在 await 後核對取消與 snapshot。安全的往前翻不強制取消或重建索引。
- 不顯示中間草稿，只顯示搜尋／補查／整理答案。成功才寫最終回答。新回合有範圍 metadata，切到更窄範圍時暫時隱藏超界回答；舊未知 metadata 仍可顯示，但不進上下文。
- 重試沿用使用者 message ID、替換失敗助手槽位；pending／已成功的同一回合不可重複建立。資料未遷移。取消保留附屬於問題的停止狀態。

## 問題解析、補读與搜尋

明確單輪問題直接初搜，一次生成可結束。偵測到代詞／承接語且有安全歷史時，先進行小型 JSON 規劃：`rewrittenQuestion`、最多 3 個 queries、`unresolvedReferences`、purpose，嚴格驗證型別、非空與長度。無安全歷史或仍有歧義，回覆請補人名／事件，不猜對象。解析失敗直接失敗，不追加修復呼叫。原始問題與改寫始終同時保留於 user 資料訊息，原始問題也是一條搜尋線。

既有 BM25／hybrid 仍 eligible-first；本機詞面補充以 NLTokenizer 原詞與 CJK 雙字原詞命中改善人名切分差異，只讀 eligible 正文，與原檢索用 RRF 合併。它不建立別名等價關係，詞面命中不證明語意。

命中後從同章 ordinal 前後各一塊開始補讀，安全邊界與輸入預算決定能送多少。直接命中優先於鄰接，重疊文字以精確來源區間去重；裁切／拆分建立 `fragment:<digest>:start:end`，保留 parentChunkID，不冒用原 chunk ID。

跨閱讀點 chunk 僅能產生 request-local 安全前綴，grapheme 邊界保守裁切、UTF-16 與來源正文 round-trip。prefix 只依安全前綴本身作詞面相關判斷，或用於「剛讀到這段」問題，沒有把含未讀後綴的向量送入 prefix 檢索。索引原文、ID 與向量不被覆寫。鄰接讀取也不跨章或越界。

## 整體預算與補查停止

可配置起始值：最多 4 次生成呼叫、5 個有效 queries、最多一輪補查／修訂、每次輸入 16,000 Characters／48,000 UTF-8 bytes、輸出 maxTokens 1,024。狀態頁明示模型呼叫與 query 上限及供應商可能計費。所有 rewrite／planner／draft／final 共用局部累計數，不向下重置預算。

初搜零命中時，在保留答案額度後可做一次缺口規劃與補搜。已有草稿自評 partial／insufficient 時，在尚未補查且仍有規劃＋答案額度下可補搜。重複 query、不增加任何安全原文區間、額度不足或取消立即停止。一次補查後不再用新的 partial 開下一輪。自評是觸發訊號，不是正確性證明。

`AIQuestionPrompt` 對包含 system、history、原始問題、改寫、已搜尋詞與 evidence 結構的完整序列化 messages 計算 Character／UTF-8 bytes。沒有模型相符 tokenizer，token count=unavailable、model capacity=unknown；上述計數是本機上限，不能保證供應商 context window 接受。

先移除較舊的可選歷史，再移除較低優先的完整 evidence。指代所需的選中歷史不被靜默截斷；必要問題／背景仍超額會明確失敗。JSON、不完整 UTF-16 pair、正文與範圍不一致的裁切都不會送出。輸出以 maxTokens 保留額度，但未知 provider 容量仍可能拒絕。

## 證據、引用與診斷

區分 retrieved → selected → sent → cited。每個模型呼叫保存 sent 集合，最終 parser 只接受最後一次答案 request 的 evidence IDs；曾檢索或曾給 planner 看過的 ID 不因此成為最終合法引用。歷史助手不會變成 source evidence。

要求答案區分原文事實與推論；「第一次／全部／從未」另顯示非完整遍歷提示。來源缺失、位置無法驗證、歷史排除、已讀範圍與預算不足各有說明。無命中用「目前可用範圍的結果不足以確認」，不等同「書中沒有」。空白、length、content_filter、格式錯誤與 transport error 都保持失敗，不自動重試。

Phase 1 trace 新增 history IDs／排除原因、規劃結果與歧義數、每條搜尋／fragment 的種類與範圍、sent／final evidence、累計模型與 query 數、補查原因、停止結果、budget 計數方式。模型階段保留原有 timing／served model／usage／finish reason。UI、service 與 trace 共用 requestID；實際顯示、失敗或取消狀態以 uiFinalState 記錄。預設 metadata 不保存 query、人名、原文或 planner 內容；敏感資料依然只在事先 opt-in 後暫存記憶體，並按 messages／evidence／response＋assessment 的原選項匯出。未捕捉的選取類別在 export 列為 unavailableContentCategories，不事後重建。

`AI_PHASE2_TRACE.testFixture.json` 從 production service 跑合成多輪案例時的實際 trace 匯出。來源是合成人物柳青／沈舟，外部生成模型是 `phase2-mock`／`scripted-external-model`，origin=testFixture。這只證明參數、檢索與約束串接，回覆與 usage 欄位是 fixture 腳本資料，不是實際 tokenizer 計量或模型理解力測評。

## 測試與交付身分

當次環境由 `bash scripts/sim.sh xcode`／`dest` 解析：`/Applications/Xcode-beta.app/Contents/Developer`、`id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`。逐一 class 執行，全部使用 `scripts/xctest.sh`，因此都有 `-parallel-testing-enabled NO`。以下是這次最後來源版本的結果，共 **174 項 Swift tests**，未把修改前基線或不同版本的中途 run 重複加入總數。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
bash scripts/xctest.sh -l /tmp/yuedu-phase2-delivery-AIPhase2ConversationTests.log -- \
  -only-testing:'yuedu appTests/AIPhase2ConversationTests'
# 其餘 class 逐一替換 -only-testing 及 log 名稱；各次實際 log 如下。
python3 scripts/tests/xctest_wrapper_test.py
ruby scripts/check_localizations.rb
bash -n scripts/xctest.sh
git diff --check
```

| 選取 class | 項數 | 結果 | 最後有效 log |
|---|---:|---|---|
| `AIPhase2ConversationTests` | 27 | 通過 | `/tmp/yuedu-phase2-delivery-AIPhase2ConversationTests.log` |
| `AIPhase1RepairTests` | 6 | 通過 | `/tmp/yuedu-phase2-delivery-AIPhase1RepairTests.log` |
| `AIPhase1IntegrationTests` | 18 | 通過 | `/tmp/yuedu-phase2-delivery-AIPhase1IntegrationTests.log` |
| `AIBookRetrievalIndexTests` | 9 | 通過 | `/tmp/yuedu-phase2-delivery-AIBookRetrievalIndexTests.log` |
| `AIRetrievalTests` | 14 | 通過 | `/tmp/yuedu-phase2-delivery-AIRetrievalTests.log` |
| `AIAssistantFeatureTests` | 19 | 通過 | `/tmp/yuedu-phase2-final-AIAssistantFeatureTests.log` |
| `AIAgenticAssistantTests` | 10 | 通過 | `/tmp/yuedu-phase2-final-AIAgenticAssistantTests.log` |
| `AIProviderTests` | 13 | 通過 | `/tmp/yuedu-phase2-final-AIProviderTests.log` |
| `AISpeakerRosterTests` | 8 | 通過 | `/tmp/yuedu-phase2-final-AISpeakerRosterTests.log` |
| `AISelfAssessmentTests` | 9 | 通過 | `/tmp/yuedu-phase2-final-AISelfAssessmentTests.log` |
| `ChapterPlainTextTests` | 6 | 通過 | `/tmp/yuedu-phase2-final-ChapterPlainTextTests.log` |
| `TTSRoleVoiceCastTests` | 15 | 通過 | `/tmp/yuedu-phase2-final-TTSRoleVoiceCastTests.log` |
| `TTSSpeakerAnnotatorTests` | 15 | 通過 | `/tmp/yuedu-phase2-final-TTSSpeakerAnnotatorTests.log` |
| `ChunkCharacterOffsetTests` | 5 | 通過 | `/tmp/yuedu-phase2-final-ChunkCharacterOffsetTests.log` |

27 項 Phase 2 tests 中的參數化測試涵蓋多種額度及錯誤（Swift Testing 以 test 定義計數，沒有另把每組 argument 加進總數）。Phase 1 的既有 147 項全部重跑，沒有刪除舊斷言以降低要求。

新增覆蓋：安全歷史／跨書與對話隔離、前進與回退／來源變更、模糊指代、歷史猜測不能成為 citation、同章鄰接、閱讀點前綴、無 mapping 時 offset 0、Unicode／overlap round-trip、預算移除後的引用集合、零命中改寫、分隔章節補查、重複 query 與無新證據停止、總 query／LLM 計數、長上下文、生成／規劃錯誤、晚到取消、owner／scope 隔離、同回合重試、舊 JSON 及不完整 provenance 相容、預設診斷無敏感輸入。

長篇本機 fixture：**320 章、418,223 UTF-16 code units、640 個 production 800/120/200 chunks**；相距第 3／251 章的證據進入最終請求，閱讀上限在第 271 章，後面的合成揭露沒有進入任何模型訊息。最後 run 的索引／檢索／組裝耗時 **277.098 ms**；使用 mock，這不是網路延遲、真實小說品質或效能前後比較。

測試 wrapper 額外 **6 個情境通過**：成功但背景 log 含 failed、真失敗、缺 verdict、timeout、成功字樣後自然非零退出、零項測試。每次都檢查獨立 sentinel 程序仍存活。wrapper 新增自然退出碼與正數 test count 檢查；只有 wrapper 自己在完整 verdict 後發出的 signal 可解釋非零 signal status。未以片段成功文字掩蓋 raw 非零。相關 shell syntax／localization（3 語、2774 keys）／diff whitespace 檢查通過。

中途失敗分開保留：首輪 24 項新增 tests 有 5 項固定繁中文案斷言不符合英文測試環境，改用完整 `localized(...)` 期望值；該失敗 run 在已見測試失敗後停止，沒有算成通過。隨後重試測試的 mutating call 直接放入 `#require` 引發 macro 編譯錯誤，改為先取得值再斷言。之後 26 項通過；再增加不完整 provenance 相容測試與 requestID／query 計數斷言，最後 27 項通過。日誌分別為 `/tmp/yuedu-phase2-newtests.log`、`/tmp/yuedu-phase2-final-AIPhase2ConversationTests.log`、`/tmp/yuedu-phase2-final-AIPhase2ConversationTests-v2.log`，均未取代上表最後結果。

交付 HEAD 仍為 `62c2656b114d64f4f5628b161d07abde949021dd`。上表各有效 run 對應的最後相關檔案集合身分為 **`78a1570194dc3111a24a7bc1d0d64c0ad86e4d5f74d09b8c19524ff93d5a4cda`**（以下 path→SHA-256 mapping 以 Python `json.dumps(mapping, sort_keys=True)` 編碼後 SHA-256）。驗證後再次逐檔比對一致；沒有以 HEAD 相同代替 working-tree 比對。最初較早執行的四組已在最後修改後重跑，表中僅列後一次。

| 修改／新增的程式、測試與工具檔案 | 最後 SHA-256 |
|---|---|
| `Modules/Core/AI/AIAgenticAssistant+Question.swift` | `12309f67a7ea1f65eb457ad534c7b14162ec3446a87a5dfd5e8affcc3f7a3462` |
| `Modules/Core/AI/AIChatMessage.swift` | `e6b24751e90756f96fc6ba62f4f706b6209c7556e3c4f657841636173d7cf82d` |
| `Modules/Core/AI/AIQuestionContext.swift` | `65c6a9e55f1429ca44fe7aa56e24e650ab3a2e3acd3c3a4d9cb544b107eb164a` |
| `Modules/Core/AI/AIQuestionEvidence.swift` | `ca4672abf04695aff1ebaa66be3f09cec741de9efaa59a465d944952b69b4cc1` |
| `Modules/Core/AI/AIRAGPipeline.swift` | `6852d57afe24030b0467e9308197a5ef989cd0feaf484d69e959b2f2643ea5c4` |
| `Modules/Core/AI/LLMProviding.swift` | `e34c2e2e2e244451abf3c64d20e795b0d5753b7ffbc0998747ea056a42d4f51e` |
| `Modules/Features/AI/AIAssistantPanelView.swift` | `01f2ee4d0e283db6eba4b88fce312475e3e22e29db009bab20cd1d23e4014d8b` |
| `Modules/Features/AI/AIStatusView.swift` | `2ed6c66386d0c0c44ce2603568a15437d924703442cf45bf106b5351017bb084` |
| `Modules/Services/AI/AIAssistantService.swift` | `9ae2596f462434c8b0d0daead6eb58b8001b39098944905012497fba7241ddd4` |
| `Modules/Services/AI/AIBookContentAdapter.swift` | `4ba9847de2a32abeb9381c43f0e3007df730c4ae4fb10dbefb7d6a1cea71d762` |
| `Modules/Services/AI/AIDiagnostics.swift` | `960f42a53f997db3e9e5ba7ebb487c2bf43093196cdb78e3d30548f15155995e` |
| `Resources/en.lproj/Localizable.strings` | `3487e8750b25d0a3bfa5cbd2e0a3f73e43a35a4d9d3939a16637c8034308b098` |
| `Resources/zh-Hans.lproj/Localizable.strings` | `bd920dc0cb4efcd5f7028a485968dc11c5d312a9fd4a76eef1feadb208d2467f` |
| `Resources/zh-Hant.lproj/Localizable.strings` | `ca78a7d4741a42dc35a8d6fe71b4bf8e72d273cd3807067f4e3843e32d811b7e` |
| `Tests/iOS/yuedu appTests/AIPhase2ConversationTests.swift` | `3de831a36ac2da962f41e89b7fd9eb47c0fc77d3d45fef07e6da96a182580e13` |
| `Yuedu-Reader.xcodeproj/project.pbxproj` | `e0ea7004d5c3787e7e0cdfd6ef41ff09d0a91d326d8966bd679b6e9f43c0dc39` |
| `scripts/tests/xctest_wrapper_test.py` | `ede3505c9e1f5f45c8042c66b2dbbf07240d839f984d33991c399f1276e0418a` |
| `scripts/xctest.sh` | `59cac97c8722e5a63faf34f25f11e6540b223383fc66fad5e2e22e565e2caa33` |

另新增本報告、`AI_PHASE2_TRACE.testFixture.json`、`AI_QA_EVALUATION_TEMPLATE.md`；文件與實際 capture 匯出不屬於 app 編譯輸入，因此不納入上述程式身分。最後回歸已編譯正常 App／tests targets，不另做 clean。交付工作區保留變更，未自動提交。


## 界線與仍未知的效果

- 未呼叫真實生成 API、上傳私人小說、下載正文或語意模型；全部外部生成使用本機 mock／原有 URLProtocol fixture。
- 代詞偵測是保守的中英語句啟發式；規劃／生成的語意品質、罕見語法和模糊人物稱謂仍需真實小說評估。合法 JSON、引用與 selfAssessment 並不證明語意正確。
- 詞面雙字可能帶來低相關候選；鄰接預讀從 +/-1 起步，並不是最優品質結論。未實作全量事件遍歷、GraphRAG、全書人物抽取或增量 embedding。
- 無精確 model tokenizer／容量資料，不保證服務端一定接受輸入；超長與截斷保持明確失敗。
- source/layout 不可映射時仍保守排除當章；引用仍沿用 Phase 1 的 exact／unique literal map，無唯一位置就明示不能精準跳轉，不擴大到排版 mapping 工程。
- 真機、VoiceOver 實機操作、真實 embedding artifact 與真實小說回答品質尚未驗收。SwiftUI 回歸涵蓋其實際共用的 request ownership／重試資料邏輯，不能代替手動閱讀與無障礙操作。

後續人工評估使用 `AI_QA_EVALUATION_TEMPLATE.md`；未授權的真實 API 對照不執行。本階段到此，不自動進入全書人物建檔。
