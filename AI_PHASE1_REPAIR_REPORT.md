# Yuedu AI Phase 1 修復報告

基準：`main` / `f7e472a558ba59dd7a4dd45823bc223b451f76f2`。在原工作區實作，保留原有未追蹤的 `AI_ARCHITECTURE_AUDIT.md`，未切分支、commit、stash 或 reset。本階段未實作對話歷史理解、全書 LLM 人物抽取或下一階段檢索策略。

## 修復與資料契約

### 索引來源與持久化

- 新增 `Modules/Core/AI/AISourceSnapshot.swift`。`AISourceManifest` 保留章節穩定 ID（href，沒有 href 時用來源章序）、順序、章名 digest、取得狀態、索引用正文 SHA-256 與 UTF-16 長度。JSON 以 sorted keys 編碼，再用 CryptoKit SHA-256 產生來源版本。
- `AIBookContentAdapter` 固定同一次正文 snapshot；正文 digest 不再以章數、可用章數或總字數代替。相同長度改文、可用章節互換、章節順序／標題／href 或轉換版本改變，都會改變版本。閱讀器另把替換規則的 digest 編入轉換版本。
- `AIBookIndexStore` 使用 schema 2，保存 fingerprint、manifest、chunker 設定、tier、embedding 身分及 vectors。load 從上述欄位重建 identifier，核對 manifest digest、stored identifier 和呼叫端當前 expected identifier；不是把 stored identifier 直接貼回物件。
- 舊 schema／不可解碼的索引安全失效；新索引寫入後，新 store 實例可從磁碟重用。索引識別包含 chunker `recursive.utf16.v3` 與實際 `800/120/200` 配置；實體 Core ML provider 的識別包含 artifact digest、前處理版本與宣告維度。
- 同書、同版本以 actor 內的 pending task 共用建索引。較舊來源的完成結果仍可交給原呼叫者，但不得覆寫較新來源的記憶體／磁碟索引。服務與掃描也檢查取消及 snapshot 所有權。

### 邊界與搜尋執行順序

正式呼叫路徑：`ReaderView` snapshot → `AIAssistantService` → `AIBookRetrievalIndex.retrieve` → RAG／agentic／recap。

1. 以 `AIReadingBoundary` 的來源版本、章節 ID／順序、source UTF-16 offset 決定 eligible chunks。
2. 跨過閱讀點的 chunk 整段排除；section 限制同時套用。
3. BM25 在 postings 評分前排除非 eligible 文件；向量僅對 eligible chunks 計算 cosine。
4. 各路徑在此時才取候選前 K，之後融合、取最終 limit。

BM25 的全域 corpus 統計仍沿用現有索引，候選資格先於評分和截斷。`max(limit * 4, 32)` 是 eligible 範圍內的候選上限，不是先擷取全書再過濾。證據不足時允許少於 8 筆，不以未讀正文補滿。所有現有 agentic 檢索及 seed 都遵守相同邊界。

百分比只供 UI／提要新鮮度判斷；正式防劇透範圍不依下載正文總字數當分母。提要快取還必須版本一致、有 evidence IDs，且原生成邊界完全包含於目前邊界；往回跳不會因進度差小或未滿 24 小時而重用後文。

### 正文／閱讀器座標與明確降級

- Chunker 仍按 Character／自然段落切分，交由 adapter 將邊界轉成 source UTF-16。保留原文空白以維持 quote 與 range 對稱，不切開 surrogate pair 或 grapheme cluster。
- 引用新增來源版本與 `sourceUTF16` 單位。舊版沒有可驗證版本的引用不直接跳轉。
- 索引固定使用來源正文，不再隨排版 cache 進出而改用另一份文字。`aiSourceAdapter` 每次 gather 固定一次 manifest，更新閱讀位置時重用同一份 snapshot。
- 正文與當前排版字串完全相同時，可直接驗證 UTF-16 range；不同時，引用使用唯一、完整、literal quote 查找驗證目的位置。這是受限 fallback，並非模糊搜尋；找不到或有重複匹配就停止跳轉。
- 閱讀點在不同字串上時，以已讀前綴最後最多 80 個 Character（至少 16 個）在來源做唯一 literal anchor 匹配。沒有可驗證 anchor 或排版文字時，保守使用當章 offset 0。前面章節仍可檢索。
- **限制**：未建立涵蓋所有 HTML/ruby／腳註／替換的完整 source-to-layout map；不宣稱所有格式精準對齊。目標章節尚無排版文字時，也不猜 offset，UI 提示先開啟該章並重新整理引用。未修改 CoreText 排版／翻頁演算法。

### 正文取得、覆蓋與 UI

- `AttributedStringBuilding.localChapterText` 與各來源 builder 區分 available、notDownloaded、extractionFailed、unsupported。沒有正文時不建立看似有效的空白 evidence；manifest 仍保留缺失章節及原因。
- 線上小說沿用 `OnlineBookContentProvider` → `OnlineChapterContentService.payload(policy: .cacheOnly)`。遠端 EPUB 的資源讀取可能觸發 HTTP，因此 AI 全量 gather 只接受本機 EPUB；遠端尚未下載來源列為缺失。沒有增加網路下載 loader。
- `gatherAIBookText` 重新讀取本機 snapshot，以 generation、書籍和來源 context 阻止舊任務回寫，一次發布完成結果。來源、章節狀態或替換規則更新會使可見 AI surface 重取本機資料。
- 人物列表依 source／boundary 的 task identity 排程 `AISpeakerScanCoordinator`。過時結果不能覆寫新掃描；取消傳到 worker，各章節檢查取消。已完成且未改變的 snapshot 不重掃。
- UI 改稱「說話人候選」，明示啟發式掃描與「全書人物抽取尚未實作」；提要改稱「最近已讀片段提要」，只說最多 12 個片段，不換算成固定章數。
- `AIStatusView` 顯示目錄總數、本機正文覆蓋、缺失原因、索引章節／片段／進度、模型安裝及契約狀態，以及本次降級原因。新增文案同步繁中、簡中與英文。

### 生成、人物卡與朗讀

- RAG／recap 的正文移至 user 資料訊息，system 只保留應用規則；agentic 已執行的檢索詞也移出 system。chunk IDs 仍保留於 evidence。這是訊息權限修正，不宣稱完全解決 prompt injection。
- `LLMRawResponse` 保留可得的 served model、finish reason、HTTP status、usage；相容服務缺欄位仍可解碼。空白、length 截斷與 content_filter 回覆有明確失敗。
- Agentic malformed JSON 不再追加一次生成來掩飾解析失敗。人物卡必要欄位缺失／型別錯誤或空 summary 直接失敗，不把原始回覆存成成功摘要。
- 只有完成解析、未取消且來源仍有效的結果才 upsert。既有有效卡保留，UI 顯示本次失敗。
- 人物卡分開保存 retrievedEvidenceIDs 與 citationChunkIDs，後者限於實際檢索到且模型引用的 ID；沒有引用顯示「未提供可核對引用」。保存 sourceBoundary 與最大 evidence 位置。
- 全書模式需明確選擇，提示可能揭露身分、關係與結局。safe mode 隱藏全書／未知／過時來源卡片，保留資料；`AICharacterCardStore` 與 `AISpeakerRosterStore` 的安全查詢不提供這些別名給 TTS。人工角色語音設定未刪除。
- 說話人名單生成也驗證完整 schema；解析失敗不保存成已整理名單。

### Embedding 契約

- 安裝、載入／契約通過、語意品質評測分開表達。readyProvider 檢查唯一 string input、唯一 multiArray output、輸出 shape、實際向量數量／維度／有限值／非零，並以本機 probe 驗證已安裝 artifact。
- 整個文件向量集合必須完整、符合同一 provider 契約；query/document 維度不相容與「一致維度但不符宣告」分開分類。不再逐 chunk 默默跳過不相容向量。
- 既有 hybrid 索引遇到缺失或不相容外部 artifact，會明確降級 keyword，trace 和狀態頁保留原因；建索引時的模型契約錯誤則明確失敗。未安裝模型時 keyword 是正常可用模式。
- **未實測**：真實 embedding artifact／tokenizer、內部截斷、pooling、projection 與語意品質；沒有下載或轉換模型，也沒有用 cosine 接近 1 推論截斷。

## 診斷與敏感資料

每次服務操作以 TaskLocal request trace 串起 metadata：功能／書籍／來源與 snapshot、source UTF-16 boundary、正文取得耗時與覆蓋、缺失章節原因、cache hit／rebuild reason、tier／artifact／dimensions／契約狀態、檢索輪次與候選／排除數、chunk ID／範圍／分數類型、message roles／數量／Character 長度、生成 provider／model／輸出限制／HTTP／finish reason／usage、解析結果、自評狀態、停止／失敗原因與各階段耗時。無 token 計數時明示 unavailable，不把字元數當 tokens。

- 預設只持久化最新一筆 metadata，位於 Application Support/AIDiagnostics/latest-metadata.json，使用本機檔案保護。來源正文仍在本機索引中，診斷預設不額外複製正文。
- 使用者可在「AI 狀態與診斷」明確開啟下一次請求的敏感內容暫存；僅暫存於記憶體，不寫公開 log。
- 匯出前可分別選 messages／輸入、檢索原文、模型回覆／自評。未事先啟用暫存的請求無法事後匯出原文，避免偷偷保存敏感內容。
- Provider credentials／endpoint 不進入 trace 介面；內容匯出另遮蔽 URLs、Bearer、sk- keys、標示的帳號／password／token 和 email。任意散文不能視為完全匿名資料，原文匯出仍需使用者選擇。
- 匯出用原生檔案匯出器，本功能不自動上傳。origin 明確區分 observed、testFixture、reconstructed。
- `AI_PHASE1_TRACE.testFixture.json` 是 production retrieval／RAG／diagnostic formatter 跑合成資料和 mock provider 的實際 trace；不是書籍真實效果或真機問題已解決的證據。

## 回歸與驗證

使用當次 resolver 結果：Xcode-beta `/Applications/Xcode-beta.app/Contents/Developer`、目的地 `id=B4947D2C-C3CE-467F-9F5B-A09B2E0DA400`。這是本次紀錄，不應在後續 session 硬編碼；重新執行時先用 `scripts/sim.sh` 解析。

所有 Xcode 測試由 `scripts/xctest.sh` 執行，`-parallel-testing-enabled NO`，逐一測試 class。未呼叫付費模型、下載小說或語意模型。這些是 Simulator 上的單元／整合回歸，不冒充實體裝置或模型品質驗收。

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
export YUEDU_DEST="$(bash scripts/sim.sh dest)"
bash scripts/xctest.sh -l /tmp/yuedu-ai-final-AIPhase1IntegrationTests.log -- \
  -only-testing:'yuedu appTests/AIPhase1IntegrationTests'
# 其餘 class 同樣逐一替換 -only-testing 尾端。
ruby scripts/check_localizations.rb
git diff --check
```

初始新增 `AIPhase1RepairTests` 在原實作重現 **6 項測試失敗／11 個 issues**：冷 store 載入、等長與可用章集合指紋、候選 33、Unicode round-trip、原文 system authority、回退提要。基線紀錄 `/tmp/yuedu-ai-phase1-red.log`。原有兩項測試曾要求「正文放 system」和「malformed card 當成功摘要」；改為符合本需求的權限／失敗斷言，沒有跳過或降低檢查。

中途整合測試抓到 query/document 維度分類錯誤，修正後重跑；另有 source context 接線編譯錯誤，修正後重建。中途失敗未當成成功。

測試工具也完成兩個必要修正：

- 移除 `scripts/xctest.sh` 的全域 `pkill -f`，僅終止該次 `BUILD_PID`；避免影響同時進行的其他工作。
- 退出碼改以 `** TEST SUCCEEDED **`／`TEST FAILED`／`BUILD FAILED` 與測試 issue 為準，缺 verdict 必須失敗。修正前，背景系統 log 的 `failed` 會讓全通過 run 也返回 exit 1，且成功例外 regex 不支援新版 `tests in 1 suite passed` 格式。
- `python3 scripts/tests/xctest_wrapper_test.py` 使用 fake CLI 測試 success-with-background-error、failure、missing-verdict、timeout，並保留一個名稱符合舊 pkill pattern 的獨立程序，驗證不誤殺。沒有用 fake CLI 代替 Swift 回歸；兩者分別記錄。


最終逐 class 結果如下。

| 測試 class | 項數 | 結果 | 本次 log |
|---|---:|---|---|
| `AIPhase1RepairTests` | 6 | 通過 | `/tmp/yuedu-ai-final-AIPhase1RepairTests.log` |
| `AIPhase1IntegrationTests` | 18 | 通過 | `/tmp/yuedu-ai-final-AIPhase1IntegrationTests.log` |
| `AIBookRetrievalIndexTests` | 9 | 通過 | `/tmp/yuedu-ai-final-AIBookRetrievalIndexTests.log` |
| `AIRetrievalTests` | 14 | 通過 | `/tmp/yuedu-ai-final-AIRetrievalTests.log` |
| `AIAssistantFeatureTests` | 19 | 通過 | `/tmp/yuedu-ai-final-AIAssistantFeatureTests.log` |
| `AIAgenticAssistantTests` | 10 | 通過 | `/tmp/yuedu-ai-final-AIAgenticAssistantTests.log` |
| `AIProviderTests` | 13 | 通過 | `/tmp/yuedu-ai-final-AIProviderTests.log` |
| `AISpeakerRosterTests` | 8 | 通過 | `/tmp/yuedu-ai-final-AISpeakerRosterTests.log` |
| `AISelfAssessmentTests` | 9 | 通過 | `/tmp/yuedu-ai-final-AISelfAssessmentTests.log` |
| `ChapterPlainTextTests` | 6 | 通過 | `/tmp/yuedu-ai-final-ChapterPlainTextTests.log` |
| `TTSRoleVoiceCastTests` | 15 | 通過 | `/tmp/yuedu-ai-final-TTSRoleVoiceCastTests.log` |
| `TTSSpeakerAnnotatorTests` | 15 | 通過 | `/tmp/yuedu-ai-final-TTSSpeakerAnnotatorTests.log` |
| `ChunkCharacterOffsetTests` | 5 | 通過 | `/tmp/yuedu-ai-final-ChunkCharacterOffsetTests.log` |

合計 **147 項 Swift 測試**。另有測試腳本 4 個 fixture 情境通過；`ruby scripts/check_localizations.rb` 通過（三語 2756 keys），`git diff --check` 通過。相關測試已編譯 app／test target，沒有另外執行 clean。

Trace 樣例維持上述已通過整合測試使用的合成小片段設定（20/0/0），回覆由 mock 腳本提供，僅驗證檢索／訊息／引用解析與診斷串接，不驗證回答語意。曾嘗試將展示樣例改成 800/120/200；單方法 selector 未附 `()` 時選到 0 項（未算通過），補上 `()` 後遇到下述併行編譯問題。已撤回這個非必要樣例調整，保留實際執行通過且已匯出的 fixture，不假造後續成功。

### 最後工作區編譯狀態：另項併行變更尚未相容

在上述 13 組回歸通過後，工作區的 `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutPageEngine.swift:550` 出現本任務未編輯的改動：從 `scan(html:cssTexts:writingMode:)` 改成 `scan(input:writingMode:)`。目前專案解析到 YueduCoreText **0.4.0 / 4a49d3183f5f5c0cc44ff3e68c1a01113d255438**，該套件的 `BrowserLayoutCapabilityScanner` 沒有新 overload，導致 extra argument 'input'／missing arguments 'html', 'cssTexts' 編譯錯誤；後續 key-path 錯誤是這個無法解析呼叫的連鎖結果。

證據：`git diff -- Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutPageEngine.swift` 的單行呼叫變更、當前 SourcePackages checkout 的 scanner 宣告，以及 `/tmp/yuedu-ai-final-trace-fixture-verified.log`。這不是將任意失敗推定為與 AI 無關；來源與 API 差異已直接核對。

本任務保留這項併行修改，沒有回退它、改動 CoreText 行為或擅自更換套件版本。**目前整個工作區不能宣稱最後編譯通過**；須由該變更的相容性整合完成後再驗證。前述 147 項是已發生的通過結果，並非這次失敗 build 的結果。


## 驗收項目對應

| 原需求 | 主要 production 路徑／測試 |
|---|---|
| 1–4 冷啟動、來源身分、舊 schema／引用 | AIBookIndexStore / manifest；coldStoreReusesFingerprint、equalLengthChangesInvalidate、manifestIsDeterministicAndVersioned、oldSchemaRebuildsOnceAndInvalidatesOldCitations |
| 5–6 候選 33、未讀高分不擠掉已讀證據 | AIBM25Index / vectorHits；thirtyThreeCandidates、vectorAndHybridRetrieveBeyondThirtyTwo（向量及混合兩組） |
| 7–8 Unicode、來源與排版差異 | AITextCoordinates / chunker；unicodeCoordinatesRoundTrip、literalMappingAndGraphemeBoundaries、boundaryIsIndependentOfAvailableTextDenominatorAndExcludesStraddlers |
| 9 正文缺失、不下載 | typed localChapterText；localOnlineGatherReportsMissingWithoutDownloading；遠端 EPUB 明確禁止 AI 資源網路讀取 |
| 10 掃描更新與舊任務 | AISpeakerScanCoordinator；scansRefreshAfterMoreLocalContent（continuation gate，無計時等待） |
| 11–12 失敗保留卡片、retrieved/cited | service / strict parser；failedGenerationPreservesExistingCardAndSeparatesCitations、requiredCharacterFieldTypesAreValidated、providerRetainsWireMetadataAndCompatibleLegacyResponse |
| 13 全書別名隔離 | card / roster 安全查詢；failedGenerationPreservesExistingCardAndSeparatesCitations、rosterUnknownOrWholeBookScopeIsNotSafe；既有 TTS suites |
| 14 回退提要 | AIRecap.canReuse；backwardRecapIsUnsafe、recapRequiresMatchingVersionAndSafeEvidenceBoundary |
| 15 embedding 契約 | AIEmbeddingContract / retrieval；embeddingFailuresAreExplicitAndDistinguishContracts；不冒充實體模型驗證 |
| 16 診斷預設／選擇匯出 | AIRequestTrace / traced provider；diagnosticsOnlyExportSelectedOptedInContent、exportsSanitizedFixtureTraceFromProductionRetrieval |
| 17 既有閱讀、引用、人物自訂、朗讀 | AIAssistantFeatureTests、ChapterPlainTextTests、TTSRoleVoiceCastTests、TTSSpeakerAnnotatorTests、ChunkCharacterOffsetTests |
| 併發補充 | concurrentBuildsShareWorkAndOldSnapshotCannotOverwriteNew、obsoleteCharacterRequestCannotSaveAfterSourceChanges |

## 尚未實測與下一階段最小樣本

- 沒有實體裝置的 VoiceOver／大字體／完整引用跳轉與多角色音訊驗收；本次保留原生控制、語意字級、個別按鈕無障礙標籤，編譯與邏輯回歸不能代替真機觀察。
- 沒有真實 LLM／embedding 效果評測。下一輪可提供一個明確授權的問題、閱讀點、必要原文片段及本機匯出 trace，先區分正文覆蓋、eligible 檢索、生成與解析問題。
- 若要擴大來源與排版 mapping，需要一個含 ruby／腳註／替換的最小章節、對應排版字串與讀取點；目前維持唯一 literal 匹配或保守排除，不猜測位置。
- 若要評測語意模型，需使用者明確提供／授權現有 artifact 與 tokenizer／轉換資訊，才可判斷內部 truncation／pooling／projection；本階段沒有因此要求下載或更換生成模型。

## 本任務修改檔案清單（不含併行 BrowserLayout 修改）

- `AI_PHASE1_REPAIR_REPORT.md`
- `AI_PHASE1_TRACE.testFixture.json`
- `Modules/Core/AI/AIAgenticAssistant.swift`
- `Modules/Core/AI/AIBM25Index.swift`
- `Modules/Core/AI/AIBookRetrievalIndex.swift`
- `Modules/Core/AI/AIBookSpeakerScan.swift`
- `Modules/Core/AI/AICharacterProfile.swift`
- `Modules/Core/AI/AIChunking.swift`
- `Modules/Core/AI/AIRAGPipeline.swift`
- `Modules/Core/AI/AIRecap.swift`
- `Modules/Core/AI/AISourceSnapshot.swift`
- `Modules/Core/AI/AISpeakerRoster.swift`
- `Modules/Core/AI/LLMProviding.swift`
- `Modules/Core/ReaderCore/CoreText/AttributedStringBuilding.swift`
- `Modules/Core/ReaderCore/CoreText/EPUBAttributedStringBuilder.swift`
- `Modules/Core/ReaderCore/CoreText/MarkdownAttributedStringBuilder.swift`
- `Modules/Core/ReaderCore/CoreText/NodeAttributedStringBuilder.swift`
- `Modules/Core/ReaderCore/CoreText/OnlineProviderAttributedStringBuilder.swift`
- `Modules/Core/ReaderCore/CoreText/TXTLazyAttributedStringBuilder.swift`
- `Modules/Core/ReaderCore/EPUBPageRenderer.swift`
- `Modules/Features/AI/AIAssistantPanelView.swift`
- `Modules/Features/AI/AICharacterListView.swift`
- `Modules/Features/AI/AISettingsView.swift`
- `Modules/Features/AI/AIStatusView.swift`
- `Modules/Features/Reader/ReaderView+SourceChange.swift`
- `Modules/Features/Reader/ReaderView.swift`
- `Modules/Features/Reader/TTS/TTSRoleCastView.swift`
- `Modules/Services/AI/AIAssistantService.swift`
- `Modules/Services/AI/AIBookContentAdapter.swift`
- `Modules/Services/AI/AIBookIndexStore.swift`
- `Modules/Services/AI/AICharacterCardStore.swift`
- `Modules/Services/AI/AIDiagnostics.swift`
- `Modules/Services/AI/AIEmbeddingModel.swift`
- `Modules/Services/AI/AISpeakerRosterStore.swift`
- `Modules/Services/AI/OpenAICompatibleProvider.swift`
- `Resources/en.lproj/Localizable.strings`
- `Resources/zh-Hans.lproj/Localizable.strings`
- `Resources/zh-Hant.lproj/Localizable.strings`
- `Tests/iOS/yuedu appTests/AIAgenticAssistantTests.swift`
- `Tests/iOS/yuedu appTests/AIAssistantFeatureTests.swift`
- `Tests/iOS/yuedu appTests/AIPhase1IntegrationTests.swift`
- `Tests/iOS/yuedu appTests/AIPhase1RepairTests.swift`
- `scripts/tests/xctest_wrapper_test.py`
- `scripts/xctest.sh`
