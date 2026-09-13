# Yuedu Reader — AI 功能現況架構稽核

**稽核日期**：2026-09-13
**稽核對象**：本機工作區 `/Users/zhangruilin/Desktop/Yuedu-reader`
**性質**：唯讀稽核。未修改任何 production 程式、專案設定或依賴；未提交、未切換分支、未 reset/stash；未呼叫任何付費模型 API；未將任何書籍內容送出本機。

**證據標記**（全文一致使用）

| 標記 | 意義 |
|---|---|
| `[程式碼確認]` | 直接讀到該行程式碼，行號來自實際讀取 |
| `[執行確認]` | 本次稽核實際執行並取得輸出 |
| `[推論]` | 由程式碼推導，但未實際執行驗證 |
| `[無法確認]` | 缺少證據，明確標示為未知 |

**行號基準**：工作區在 HEAD `f7e472a5` 上是乾淨的（`git status --porcelain` 無輸出，`[執行確認]`），因此所有行號同時是 committed 行號與 working-tree 行號。

---

## 1. 一頁摘要：目前系統究竟怎麼運作

Yuedu 的 AI 功能是一套**單層、無狀態、flat-chunk 的 BYOK RAG**。它沒有任何跨章節結構、沒有摘要階層、沒有實體資料庫、沒有對話記憶。

實際運作路徑，去掉所有修飾：

```
讀者開 AI 面板
→ ReaderView 用「排版好的章節 + 開面板時抓下來的全書純文字」組成 AIBookContentAdapter
→ 整本書切成 800 字（overlap 120）的 chunk，章內遞迴切分，不跨章
→ 建一份 in-memory BM25（NLTokenizer 中文分詞）；若使用者自行下載並安裝了 Core ML embedding 模型，另外算一份向量
→ 問題原文（一個字串，沒有改寫、沒有人名擴展、沒有歷史）丟進 BM25
→ 取 max(limit*4, 32) 候選 → RRF 融合（關鍵詞權重 1.2 > 向量 1.0）→ 用 progressEnd <= 進度 過濾 → 取前 8
→ 8 個 chunk 直接以 [chunkID]\n正文 的形式塞進 system message
→ 一次非串流 POST /v1/chat/completions，max_tokens=1024
→ 從回覆裡用正則抓 [chunkID] 當引用，抓不到就標記「沒有證據」
→ 顯示
```

四個目標場景的現況：

| 你要的 | 現況 | 判定 |
|---|---|---|
| 讀到第 500 章時問前面情節、人物關係、跨章節因果 | 單次 BM25 top-8，無查詢改寫、無多跳、無摘要層 | **結構上不支援**。能答的是「某個詞出現在哪幾段」，不是「因果」 |
| 批次處理小說生成人物卡與人物經歷 | 人物卡是**單人、即時、最多 3 步 agentic 檢索**。沒有任何批次、逐章、累積式處理 | **未實作**。「掃描整本書」是正則對話啟發式，不是 LLM 抽取 |
| 區分「截至進度」與「全書劇透」 | 問答／前情提要：在檢索層以 `progressEnd <= 進度` 硬擋（正確）。人物卡：**固定 scope = 1.0（全書），只靠 prompt 說「不要透露結局」** | **部分實作，且兩者標準不同** |
| 回答與人物卡能找到對應原文證據 | 問答：模型寫 `[chunkID]`，程式核對 ID 是否在送出的清單裡 → 有位置可跳。人物卡：`citationChunkIDs` 存的是**全部送進去的 chunk**，不是模型引用的那些 | **問答做到「ID 存在且確實送出」；人物卡只做到「確實送出」** |

**最該先看的三件事**（詳見 §7）：

1. **A1｜磁碟索引永遠失效**。`AIBookIndexStore.load()` 重建 index 時沒把 `contentFingerprint` 傳回去，載入的 identifier 永遠是空指紋，永遠對不上期望值。結果：每次 App 重啟都重新切塊、重建 BM25；hybrid tier 下等於**重新 embedding 整本書**。這是 `f7e472a5` 引入的回歸。
2. **A2｜多輪對話完全沒有歷史**。`answer(question:)` 只接受一個字串，prompt 只有 `[system(片段), user(問題)]`。你舉的「那他後來為什麼背叛？」送出去時，模型看不到「他」是誰。
3. **A3/A4｜`charOffset` 單位不一致**。AI 這一側用 Swift `Character` 計數，閱讀器那一側用 UTF-16。中文 BMP 字元兩者相同，但 CJK 擴展 B 區（𠮷 等真實會出現在小說裡的字）1 Character = 2 UTF-16，偏移會單向累積漂移。

---

## 2. 工作區版本與檢查範圍

### 2.1 版本

| 項目 | 值 | 證據 |
|---|---|---|
| 專案 | Yuedu Reader（閱讀），iOS，SwiftUI + CoreText | `CLAUDE.md` |
| 分支 | `main` | `git rev-parse --abbrev-ref HEAD` `[執行確認]` |
| HEAD | `f7e472a558ba59dd7a4dd45823bc223b451f76f2` (2026-09-13 15:51:51 +0800) | `git log -1` `[執行確認]` |
| 未提交修改 | **無**（工作區乾淨） | `git status --porcelain` 空輸出 `[執行確認]` |

AI 功能全部在 HEAD 這一個 commit 內首次進入版本控制（`git show --stat HEAD` 顯示 30 個 `Modules/**/AI/*.swift` 皆為 `create mode`，`[執行確認]`）。也就是說**這次是 AI 功能第一次被提交**，先前一直在工作區。

### 2.2 模組與入口

| 層 | 位置 | 內容 |
|---|---|---|
| Core（純邏輯） | `Modules/Core/AI/` | 15 檔：切塊、BM25、檢索融合、RAG pipeline、agentic loop、自評、人物卡 schema、前情提要、說話人名單、LLM 協定 |
| Services（有狀態） | `Modules/Services/AI/` | 15 檔：索引 store、內容 adapter、設定/Keychain、embedding 模型、模型清單、聊天/人物卡/前情提要/名單 store、OpenAI 相容 provider |
| Features（UI） | `Modules/Features/AI/` | 3 檔：`AIAssistantPanelView`、`AICharacterListView`、`AISettingsView` |

**UI 入口（production，已追到呼叫鏈）** `[程式碼確認]`：

| 入口 | 位置 | 通往 |
|---|---|---|
| 閱讀器底部控制列「AI 助手」 | `Modules/Features/Reader/ReaderBottomControlBar.swift:76` → `ReaderView+Toolbars.swift:133` → `ReaderView.swift:2380` | `AIAssistantPanelView`（問答 + 前情提要） |
| 閱讀器工具列 | `ReaderView+Toolbars.swift:440` | 同上 |
| 聽書面板 →「多角色朗讀」→「人物卡」 | `ReaderView.swift:2405` → `TTSPanelView.swift:124` → `TTSRoleCastView.swift:159` | `AICharacterListView`（人物卡 + 全書掃描） |
| 設定 → 個人頁 | `Modules/Features/Settings/ProfileView.swift:277` | `AISettingsView` |
| 面板內 / 人物卡內 / 多角色內的「設定 AI 助手」 | `AIAssistantPanelView.swift:126`、`AICharacterListView.swift:99`、`TTSRoleCastView.swift:64` | `AISettingsView` |

**沒有未接線的孤兒實作**，唯一例外見 A10（`stream()` 完整實作但無人呼叫）。

### 2.3 ChatBook 移植來源

`NOTICE`（repo 根）列出 13 個檔案宣告衍生自 ChatBook，每檔開頭有 header 標明來源檔名 `[程式碼確認]`：

```
Modules/Core/AI/LLMProviding.swift        ← Sources/ChatBookCore/Assistant/LLMProvider.swift
Modules/Core/AI/AIChunking.swift          ← Sources/ChatBookCore/Text/Chunking.swift
Modules/Core/AI/AIBM25Index.swift         ← Sources/ChatBookCore/Retrieval/BM25Index.swift
Modules/Core/AI/AIRAGPipeline.swift       ← Sources/ChatBookCore/Retrieval/RAGPipeline.swift
Modules/Core/AI/AIAgenticAssistant.swift  ← Sources/ChatBookCore/Assistant/AgenticReaderAssistant.swift
（其餘 8 檔見 NOTICE）
```

**來源版本不明** `[無法確認]`：header 只記檔名，沒有 commit SHA、tag 或日期；`Package.resolved` 裡也沒有 ChatBook（它不是 SPM 依賴，是人工移植）。**不應把目前 GitHub 上的 ChatBook 當作參考版本**。

**非移植、Yuedu 自有**（無 ChatBook header）：`AIBookSpeakerScan`、`AISpeakerRoster`、`AIBookContentAdapter`、`AIBookIndexStore`、`AIEmbeddingModel`、`AIModelCatalog`、`AIProviderPreset`、`AIChatMessage`、`AIChatStore`、`AICharacterCardStore`、`AIRecapStore`、`AISpeakerRosterStore`、全部 UI。

---

## 3. 各功能實際呼叫鏈

### A. 一般書內問答

```
AIAssistantPanelView.send(_:)                              Modules/Features/AI/AIAssistantPanelView.swift:505
→ 問題 = 輸入框字串（原樣，不做任何改寫）
  閱讀位置 = ReaderView.aiReadingProgress()                ReaderView+SourceChange.swift:1137
  進度上限 = gs.aiSpoilerSafe ? progress : 1.0             AIAssistantPanelView.swift:36
→ AIAssistantService.answer(question:bookID:adapter:progress:)   AIAssistantService.swift:121
→ 文字來源 = AIBookContentAdapter（見 §4.1）              ReaderView+SourceChange.swift:1095
→ 索引 = AIAssistantService.index(forBook:adapter:)        AIAssistantService.swift:61
      → AIBookIndexStore.index(for:expectedIdentifier:build:)  AIBookIndexStore.swift:45
      → AIPublicationChunker(800/120/200).chunks(from:)     AIAssistantService.swift:70
→ 搜尋詞 = 問題原文，一個，無改寫                          AIAssistantService.swift:130
→ 檢索 = AIBookRetrievalIndex.retrieve(query:maximumProgress:limit:8:embedding:)  AIBookRetrievalIndex.swift:104
      候選 max(8*4,32)=32 → RRF(1.2 keyword / 1.0 vector) → 進度過濾 → prefix(8)
→ 上下文組裝 = AIRAGPipeline.systemPrompt(for:selfAssessmentNonce:)  AIRAGPipeline.swift:22
      8 個 chunk 以「[id]\n正文」串接，全部放 system
→ 模型請求 = provider.generate(...)  非串流                AIRAGPipeline.swift:103
      messages = [system(規則+片段), user(問題)]            AIRAGPipeline.swift:75-88
→ 回覆解析 = AISelfAssessmentStreamParser 剝自評區塊 → AICitationParser.parse 抓 [id]
                                                            AIRAGPipeline.swift:105-113
→ 引用 = 只保留 ID 在送出清單裡的；hasEvidence = 引用非空   AIRAGPipeline.swift:114-123
→ 保存 = AIChatStore（UserDefaults，每書 30 場 × 每場 60 則） AIChatStore.swift:12-13
→ UI = 氣泡 + 引用卡（點擊 jumpToChapter(spineIndex, charOffset:)） ReaderView.swift:2389
```

**零命中分支**：`hits.isEmpty` → `noEvidenceResult`，**不呼叫模型**，直接回固定字串「書中（防劇透範圍內）沒有與這個問題相關的內容。」`AIRAGPipeline.swift:98-100, 55-68` `[程式碼確認]`。**沒有補搜、沒有放寬、沒有降級。**

### B. 帶追問的多輪對話

**未實作。**

`AIAssistantService.answer` 的簽名只有 `question: String`（`AIAssistantService.swift:121-126`）。`AIRAGPipeline.request` 組出的 messages 恆為兩則：`[system, user(query)]`（`AIRAGPipeline.swift:75-88`）。`AIChatSession.messages` 只用於 UI 顯示與 `AIChatStore` 持久化，**從未進入檢索或生成**（`AIAssistantPanelView.swift:514-519` 只傳 `question`）。`[程式碼確認]`

後果：「那他後來為什麼背叛？」→ 檢索詞是這整句，BM25 會命中「背叛」相關段落但完全不知道「他」是誰；生成時模型也拿不到前一輪。

### C. 指定人物生成人物卡

```
AICharacterListView：點列表某人名，或在「掃不到的人物」輸入名字
→ build(name:)                                             AICharacterListView.swift:184（按鈕在 :131, :284）
→ AIAssistantService.characterCard(name:bookID:adapter:onStep:)  AIAssistantService.swift:169
→ 索引：同 A（共用 AIBookIndexStore）
→ AIAgenticAssistant.run(task:userInput:index:provider:embedding:scope:1.0,maxSteps:3,...)
                                                            AIAssistantService.swift:178-186
   迴圈（AIAgenticAssistant.swift:107-242）：
     每一步 → provider.generate（planner，max_tokens 512）   :128
     解析純 JSON {action,query,queries,missing,reason,answer,citations}  :379
     action=retrieve/rewriteAndRetrieve → 對每個新查詢做一次 index.retrieve(limit:8, maximumProgress:1.0)  :204
     action=finish 或 步數用盡 → 回答（max_tokens 1024）
   停止條件：maxSteps=3／maxQueries=5／連續 2 輪無新 chunk／查詢重複／planner 回覆無法解析
   → 任何非正常結束都走 synthesize()（再一次 generate）      :254
→ 解析 = AICharacterProfile.parse(fromAnswer:...)            AICharacterProfile.swift:83
   JSON 解析成功 → 填欄位；失敗 → summary = 原始文字，結構欄位留空，**仍然存檔**  :106-120
→ citationChunkIDs = result.retrievedChunks.map(\.id)  ← 全部送進去的，不是模型引用的
                                                            AIAssistantService.swift:191
→ AICharacterCardStore.upsert（Application Support/AICharacterCards/<bookID>.json）
→ UI = profileSection；別名同時餵給多角色朗讀                AICharacterListView.swift:326
```

**模型呼叫次數上限**：3 次 planner/answer + 最多 1 次 synthesize = **最多 4 次 generate**；檢索次數上限 5。`[程式碼確認] AIAgenticAssistant.swift:88-89, 178, 202`

### D. 全書掃描／自動發現所有人物

**這是三件不同的事，目前只做了第一件。**

```
AICharacterListView.onAppear → scanBook()                   AICharacterListView.swift:93, 228
→ sectionsInScope：scope=.read 時只取進度以內的章節         :214-225
→ Task.detached → AIBookSpeakerScan.scan(sections:aliases:)  AIBookSpeakerScan.swift:38
      對每章逐段落跑 TTSSpeakerAnnotator.attributions        TTSSpeakerAnnotator.swift:31
      → DialogueHighlighter.dialogueRanges 找引號
      → ReaderDialogueSegmentation.speaker 從敘述尾巴剝說話動詞
      → 統計每個候選詞的句數 + 抓 40 字上下文
→ 按句數排序顯示
```

**這條路徑完全沒有 LLM、沒有 embedding、沒有索引。** 它是純正則／啟發式。「掃描整本書」按鈕（`AICharacterListView.swift:246-254`）做的事只是把 `scope` 從 `.read` 換成 `.wholeBook` 再跑一次同樣的啟發式。`[程式碼確認]`

唯一的 LLM 介入是**手動按「用 AI 整理名單」**：

```
verifyRoster()                                              AICharacterListView.swift:285
→ AIAssistantService.buildSpeakerRoster(bookID:adapter:candidates:)  AIAssistantService.swift:203
→ AISpeakerRoster.build → 一次 generate（temperature 0, max_tokens 2048）  AISpeakerRoster.swift:94-101
   輸入：候選詞 + 句數 + 40 字樣本的純文字清單
   輸出：{"names":{候選詞:正式名字或""}}
→ 解析：模型沒提到的候選詞**保留為自己**（防止截斷答案刪掉角色）  :70-91
→ AISpeakerRosterStore（UserDefaults）
```

### E. 前情提要

```
AIAssistantPanelView.askRecap()                             AIAssistantPanelView.swift:538
→ AIAssistantService.recap(bookID:bookTitle:adapter:progress:stored:)  AIAssistantService.swift:145
→ 重用判斷：AIRecap.canReuse（進度差 < 5% 且 < 24 小時 且 promptVersion 相同） AIRecap.swift:36-50
→ **不經過檢索**：AISpoilerSafeFilter.chunks(index.chunks, maximumProgress:) → suffix(12)
                                                            AIAssistantService.swift:155-156
→ AIRecap.generate → 一次 generate（max_tokens 700, temp 0.3）  AIRecap.swift:97-99
   messages = [system(任務 + 12 段正文), user("請為《書名》寫前情提要。")]  AIRecap.swift:72-83
→ AIRecapStore（UserDefaults）
```

### 共用模組與分岔點

| 問題 | 答案 | 證據 |
|---|---|---|
| 哪些功能共用索引？ | A（問答）、C（人物卡）、E（前情提要）共用 `AIBookIndexStore` 的同一份 index | `AIAssistantService.swift:127, 177, 153` `[程式碼確認]` |
| D（人物掃描）用索引嗎？ | **不用**。直接讀 `adapter.chunkSections` 原文 | `AICharacterListView.swift:218, 236` `[程式碼確認]` |
| 哪些有額外檢索？ | 只有 C（人物卡）有 agentic 多輪檢索；A 是單次 | `AIAgenticAssistant.swift:107` vs `AIAssistantService.swift:129` |
| 人物卡會被問答使用嗎？ | **不會**。`AIRAGPipeline.answer` 只收 hits，服務層也沒讀 `AICharacterCardStore` | `AIRAGPipeline.swift:91-97`、`AIAssistantService.swift:121-142` `[程式碼確認]` |
| 人物卡別名用在哪？ | 只用在**多角色朗讀**的說話人歸一 | `ReaderView+SourceChange.swift:982-983, 995-996` → `TTSSpeakerAnnotator.attributions(aliases:)` |
| 聊天紀錄參與檢索嗎？ | **完全不參與**，連最終生成也不加入 | 見 §3.B |
| 前情提要會被後續問答使用嗎？ | **不會**。`AIRecapStore` 只被 `askRecap` 讀 | `AIAssistantPanelView.swift:547` |

---

## 4. 文字、切塊、embedding 與檢索

### 4.1 文字到底從哪裡來

| 項目 | 目前實作／有效設定 | 證據位置 | 不確定之處 |
|---|---|---|---|
| 統一入口 | `EPUBPageRenderer.chapterSourceText(at:)` → `contentBuilder?.chapterPlainText(at:)` | `EPUBPageRenderer.swift:588-596`（`chapterSourceText`）、`AttributedStringBuilding.swift:85, 91` `[程式碼確認]` | — |
| 本地 EPUB | `PublicationSession.chapterHTML(at:)` 讀 zip 內 XHTML → `ChapterPlainText.fromHTML` | `EPUBAttributedStringBuilder.swift:97-102` `[程式碼確認]` | — |
| TXT | mapped file 切章，走 `TXTChapterParser` + 全域替換規則 | `TXTLazyAttributedStringBuilder.swift:192-195, 197-215` | — |
| Markdown | 節點轉換後的純段落 | `MarkdownAttributedStringBuilder.swift:52-58` | — |
| 線上書源 | `provider.contentForChapter(index:)`，`OnlineBookContentProvider` 固定用 **`.cacheOnly`**，未下載的章節丟錯 → 回 nil | `OnlineProviderAttributedStringBuilder.swift:265-277`、`BookContentProviderAdapters.swift:123-125` `[程式碼確認]` | — |
| 固定版面 EPUB / 漫畫 / PDF / 有聲書 | 走各自引擎，`contentBuilder` 為 nil → 回 nil → **AI 無文字可用** | `AttributedStringBuilding.swift:91` 預設實作 | 未逐一驗證每種 pipeline，`[推論]` |
| 觸發時機 | 兩個 sheet 的 `.task { await gatherAIBookText() }` | `ReaderView.swift:2392, 2411` `[程式碼確認]` | — |
| 收集方式 | 一次跑完整本，**只在最後 publish 一次** | `ReaderView+SourceChange.swift:1110-1130` | 數千章的耗時未實測，`[無法確認]` |
| 排版好的章節 | 優先使用（與閱讀位置同偏移空間） | `ReaderView+SourceChange.swift:1096-1101` | — |

**「書架上有這本書」是否代表本機有完整正文？** **否。** `[程式碼確認]`

- 線上書源：只有**下載過**的章節有文字（`.cacheOnly`）。其餘 `chapterPlainText` 回 nil。
- 本地 EPUB/TXT：正文在檔案裡，理論上全有。
- `BookChapter.content` 在閱讀器裡**恆為空字串**（三條建構路徑：`ReaderView+PageBuilding.swift:207, 350, 485`），所以它不是文字來源。

**尚未下載／抽取失敗的章節如何處理？** 在 `gatherAIBookText` 裡 **`continue` 靜默跳過**（`ReaderView+SourceChange.swift:1120-1122`），在 chunker 裡 `where !section.text.isEmpty` 靜默跳過（`AIChunking.swift:117`）。`[程式碼確認]`

**全文章節數／可取得章節數／成功索引章節數是否分開記錄？** **沒有。** `[程式碼確認]`
- `indexState` 只有 `.ready(chunkCount:tier:)`（`AIAssistantService.swift:33`）。
- `contentFingerprint` 是 `"總章數/有文字的章數/總字數"`（`AIBookContentAdapter.swift:65-67`）——**這是目前唯一能反推覆蓋率的東西，而且它沒有被顯示在任何 UI 上**。
- 沒有任何「哪幾章失敗」的記錄。

**正文清理是否丟掉對話、註解、章名，或混入目錄？**

`ChapterPlainText.fromHTML`（`AttributedStringBuilding.swift:98-110`）→ `ReaderHTMLUtilities.displayText(preservingLineBreaks: true)`（`ReaderHTMLUtilities.swift:13-88`）：

- **保留**段落換行（`</p> </div> <br> </li> </h1-6> …` → `\n`）。這是刻意的，因為說話人判斷是逐段落做的（`ChapterPlainTextTests.swift:18-29` `[執行確認]`）。
- **剝掉** `<script>`/`<style>` 的內容（`AttributedStringBuilding.swift:103-107`，測試 `ChapterPlainTextTests.swift:39-50` `[執行確認]`）。
- **章名**：EPUB/線上的章名若在 HTML body 裡就會留在正文中；另外 `AIChunkableSection.title` 另存一份給引用顯示用（`AIBookContentAdapter.swift:35`）。引用卡會剝掉開頭重複的章名（`AIAssistantPanelView.swift:341-350`）。
- **目錄**：EPUB 的 nav/toc 若在 spine 內會被當成一章索引進去。`[推論]`，未實測。
- **已知副作用**：`displayText` 先解 entity 再剝標籤，所以正文裡的 `&lt;完&gt;` 會連同真標籤一起被剝掉。這是既有共用函式的契約，非 AI 專屬（`ChapterPlainTextTests.swift:52-63` 有明確記錄，`[執行確認]`）。

**原文位置如何表示，如何跳回？**

`AIChunkLocation(spineIndex:charOffset:progress:)`（`AIChunking.swift:13-23`）→ `LLMCitation(spineIndex:charOffset:)`（`LLMProviding.swift:65-80`）→ `jumpToChapter(_:charOffset:)`（`ReaderView.swift:2389` → `ReaderView+Logic.swift:193`）。

**⚠ 單位不一致，見 §7 A3。**

### 4.2 切塊與索引

| 項目 | 目前實作／有效設定 | 證據位置 | 不確定之處 |
|---|---|---|---|
| chunk 大小 | `maximumCharacters: 800` | `AIAssistantService.swift:71`（實際呼叫值） | — |
| overlap | `overlapCharacters: 120` | 同上 :72 | — |
| 尾段下限 | `minimumCharacters: 200`（末尾碎片折回前一塊） | 同上 :73；語意見 `AIChunking.swift:93-96` | — |
| **單位** | Swift **`Character`**（grapheme cluster）。`Array(text)`、`text.count` | `AIChunking.swift:190` `Array(text)`、`AIBookContentAdapter.swift:40-41` `text.count` | 與閱讀器的 UTF-16 不一致，見 A3 |
| 切分邊界 | 遞迴四層：`\n` → `。！？.!?` → `，,；;` → 硬切 | `AIChunking.swift:180-184, 193-205` | — |
| 跨章切塊 | **不跨章**。每章獨立切，ordinal 連續累加 | `AIChunking.swift:114-122, 130-173` | — |
| 前後片段關係 | **只有 overlap，沒有任何 prev/next 指標** | `AIContentChunk` 欄位見下 | — |
| 超長段落 | 逐層下切，最後按 800 硬切 | `AIChunking.swift:195-205` | — |
| token 計數 | **完全沒有**。全系統零處 token 計算 | `grep -riE "tokencount\|countTokens\|tiktoken\|numTokens" Modules/Core/AI Modules/Services/AI` 無結果 `[執行確認]` | — |

**chunk 欄位**（`AIChunking.swift:26-56`）`[程式碼確認]`：

| 欄位 | 內容 |
|---|---|
| `id` | `"<bookUUID>:<sectionID>:<ordinal>"` — `AIChunking.swift:157` |
| `bookID` | UUID |
| `sectionID` | 章節索引的字串形式（`"\(index)"`，`AIBookContentAdapter.swift:34`） |
| `ordinal` | 全書連號 |
| `text` | 正文 |
| `start` / `end` | `AIChunkLocation(spineIndex, charOffset, progress)` |
| `progressStart` / `progressEnd` | 0…1，`progressEnd = max(start, end)` |

**不存在的欄位**（不要以為有）：內容版本／內容 hash、embedding 模型版本（只在 index 層級有）、章節標題（在 `sectionTitleByID` 另表）、前後 chunk 指標、抽取時間。

**index 身分**（`AIBookRetrievalIndex.swift:90-96`）：`"<tier>@<embeddingID|none>@<chunker version>@<contentFingerprint>"`，例如 `keyword@none@recursive.v2@300/300/4200000`。

**建立／失效機制** `[程式碼確認]`：

| 情境 | 行為 |
|---|---|
| 首次建立 | `AIBookIndexStore.index(for:expectedIdentifier:build:)` → 切塊 →（hybrid）分批 32 個 embedding → 存記憶體 + 存磁碟 `AIBookIndexStore.swift:45-61`、`AIAssistantService.swift:68-104` |
| 增量更新 | **沒有**。內容指紋一變就整份重建 |
| 斷點續跑 | **沒有**。取消就從頭來（`try Task.checkCancellation()` 只是中止，`AIAssistantService.swift:81`） |
| 內容變更 | 指紋（章數/有文字章數/總字數）變 → 重建 |
| 切換 embedding 模型 | `AIEmbeddingModelStore.download()`/`remove()` 呼叫 `AIBookIndexStore.discardAll()`，刪掉所有書的索引 `AIEmbeddingModel.swift:169, 181` |
| 磁碟重用 | **實際上永遠失效，見 A1** |

**「索引完成」實際表示什麼？** 表示：全書（可取得的部分）已切成 chunk、BM25 倒排表已在記憶體建好、若 hybrid 則所有 chunk 的向量已算完。它**不**表示：全書正文都拿到了、每章都成功、任何 LLM 讀過任何內容。

### 4.3 Embedding

| 項目 | 目前實作／有效設定 | 證據位置 | 不確定之處 |
|---|---|---|---|
| provider | `CoreMLEmbeddingProvider`（本機 Core ML），唯一實作 | `AIEmbeddingModel.swift:201` | — |
| 模型 | `distiluse-base-multilingual-cased-v2@1`，宣告 512 維 | `AIEmbeddingModel.swift:34-40` | — |
| **是否安裝** | **預設無**。`sourceURLString` 預設空字串，**沒有任何官方託管位址**，使用者必須自己貼 URL | `AIEmbeddingModel.swift:73-78, 94` `[程式碼確認]` | — |
| 本機實際狀態 | 所有模擬器上 **`AIEmbedding` 目錄不存在** | `find ~/Library/Developer/CoreSimulator/Devices -name AIEmbedding` 無結果 `[執行確認]` | 真機狀態 `[無法確認]` |
| 輸入長度 | **App 端不做任何截斷或分段**，整段 chunk 以 `NSString` 丟給模型 | `AIEmbeddingModel.swift:227-232` `[程式碼確認]` | 模型內部是截斷還是報錯 `[無法確認]` |
| tokenizer | **App 端沒有**。假設打包在 `.mlmodelc` 內 | 同上 | 無法從程式確認 |
| pooling / projection / normalization | **App 端沒有任何後處理**，直接取第一個輸出 feature 的 multiArray | `AIEmbeddingModel.swift:229-237` | 是否在模型內 `[無法確認]` |
| 特殊前綴 | 無。`embedQuery` 預設直接 `embed([text])[0]` | `AIBookRetrievalIndex.swift:18-22` | — |
| query/document 一致性 | **完全相同的路徑**（協定留了分開的鉤子但未使用） | 同上 | — |
| 維度驗證 | **沒有**。`descriptor.dimensions = 512` 從未與模型實際輸出比對 | `AIEmbeddingModel.swift:220, 233` | — |
| 維度不符時 | **靜默跳過該 chunk**，不重建、不報錯 | `AIBookRetrievalIndex.swift:138` `guard … vector.count == query.count else { continue }` `[程式碼確認]` | — |
| 完整 chunk 是否都參與 | 是，分批 32 個，全部 chunk | `AIAssistantService.swift:78-95` | — |

**轉換腳本**：repo 內無（`Modules/` 下無 Python/轉換腳本）。註解稱模型「ChatBook 轉換並驗證過」（`AIEmbeddingModel.swift:27-33`）。**無法確認轉換配置** `[無法確認]`——不得僅憑模型名稱判斷 pooling/normalization 是否正確。

### 4.4 檢索

**存在的步驟**（`AIBookRetrievalIndex.retrieve`，`AIBookRetrievalIndex.swift:104-131`）`[程式碼確認]`：

| 順序 | 步驟 | 有效參數 |
|---|---|---|
| 1 | BM25 關鍵詞 | `k1=1.5, b=0.75`（`AIBM25Index.swift:36`）；候選 `max(limit*4, 32)` = **32**（`:114`） |
| 2 | 向量（僅 tier == hybrid 且有模型且 vectors 非空） | 同樣 32 候選，cosine（`:117-121, 133-150`） |
| 3 | RRF 融合 | `rankConstant = 60`，權重 keyword **1.2** / vector **1.0**（`:40-42, 96`） |
| 4 | `restrictToSectionIDs` 過濾 | production **從未使用**（無呼叫端傳值）`[程式碼確認]` |
| 5 | 進度過濾 | `progressEnd <= 進度 + 1e-6`（`AIRetrieval.swift:69-76`） |
| 6 | 取前 K | `limit`，問答 = **8**，agentic 每次檢索 = **8** |

**不存在的步驟**：reranker、鄰接片段補讀、查詢改寫（一般問答）、去重（RRF 天然按 id 去重，但沒有語意去重）、上下文 token 預算。

| 問題 | 答案 | 證據 |
|---|---|---|
| 已讀範圍在 TopK 前還是後過濾？ | **前**。候選 32 → 融合 → 過濾 → `prefix(8)` | `AIBookRetrievalIndex.swift:123-130` `[程式碼確認]`（`AIRetrievalTests` 有對應測試，`[執行確認]`） |
| 過濾後不足是否補搜？ | **否**。就少給 | 同上，無補搜分支 |
| 只讀到章節中間如何限制？ | 以 chunk 為粒度：`progressEnd <= ceiling`，所以**尾巴超出進度的那個 chunk 整塊被丟掉** | `AIRetrieval.swift:67-76` |
| 零命中 | 不呼叫模型，回固定字串「書中（防劇透範圍內）沒有與這個問題相關的內容。」 | `AIRAGPipeline.swift:55-68, 98-100` |
| 低相關 | **沒有分數門檻**。BM25 分數 > 0 就算命中 | `AIBM25Index.swift:81-86` |
| 重複命中 | RRF 以 chunk id 聚合，天然去重 | `AIRetrieval.swift:101-112` |
| 搜尋詞只用當前問題？ | **是**。無人名擴展、無別名、無歷史、無代詞消解 | `AIAssistantService.swift:130` |
| 首次出場／全部經歷 → 遍歷流程？ | **沒有遍歷**。人物卡是 agentic 多輪 TopK（最多 5 個查詢），一般問答是單次 TopK | `AIAgenticAssistant.swift:200-214` |
| 找不到證據的說法 | 說「**書中沒有**」，不是「目前未找到」 | `AIRAGPipeline.swift:59-63` ← **這是誤導性措辭，見 A7** |

---

## 5. 模型實際收到什麼，以及回覆怎麼處理

### 5.1 生成服務

| 項目 | 值 | 證據 |
|---|---|---|
| Provider 實作 | `OpenAICompatibleProvider`，唯一 production 實作 | `OpenAICompatibleProvider.swift:13` |
| API | `POST <base>/chat/completions`，`Authorization: Bearer <key>` | `:99-119` |
| 預設 base / model | `https://api.deepseek.com/v1` / `deepseek-chat` | `AIProviderSettings.swift:20-23` |
| **本機實際有效值** | `{"defaultModel":"deepseek-chat","endpoint":"https://api.deepseek.com/v1"}`（iPhone 17 Pro 模擬器，即預設值未改） | 讀 `com.zhangruilin.yuedureader.plist` 的 `yd_ai_provider_configuration` `[執行確認]` |
| API Key | Keychain，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `synchronizable: false`；不進 UserDefaults、不進 log | `AIProviderSettings.swift:94-122` `[程式碼確認]` |
| 真機使用的 model | `[無法確認]`。模擬器上沒有任何索引/聊天/人物卡資料，截圖來自真機，本機取不到 |
| 串流 | `stream()` 已實作但**production 無人呼叫**，全部走 `generate()` | `grep "\.stream(" Modules` 只命中 `BookOriginSearchService` `[執行確認]` |
| 逾時 | 請求 20s（首字）／資源 120s | `OpenAICompatibleProvider.swift:25, 29-30` |
| 超長內容處理 | **沒有**。不截斷、不分段、不計 token；靠伺服器回錯 | 見 §4.2 |

**各用途的輸出預算** `[程式碼確認]`：

| 用途 | max_tokens | temperature | top_p |
|---|---|---|---|
| 一般問答 | 1024 | 0.2 | 1.0 |
| agentic planner（每步） | 512 | 0.2 | 1.0 |
| agentic 最終答案 / synthesize | 1024 | 0.2 | 1.0 |
| 前情提要 | 700 | 0.3 | 1.0 |
| 說話人名單 | 2048 | 0 | 1.0 |
| 連線測試 | 32 | — | — |

### 5.2 messages 組成

| 功能 | messages | 證據 |
|---|---|---|
| 一般問答 | `[0] system` = 規則 + 自評 envelope 指令 + **全部 8 個 chunk 正文**<br>`[1] user` = 問題原文 | `AIRAGPipeline.swift:75-88` |
| 前情提要 | `[0] system` = 任務 + **12 段正文**<br>`[1] user` = 「請為《書名》寫前情提要。」 | `AIRecap.swift:72-83` |
| agentic（每步） | `[0] system` = 任務 + 工具說明 + 進度範圍 + 已試過的查詢 + 剩餘預算 + 步數提示<br>`[1] user` = `<reader-input>人名</reader-input>` + **已累積的全部 chunk** | `AIAgenticAssistant.swift:331-356, 363-374` |
| 說話人名單 | `[0] system` = 任務<br>`[1] user` = 候選詞清單 + 句數 + 40 字樣本 | `AISpeakerRoster.swift:54-63` |

**沒有出現在任何 prompt 裡的東西**：歷史對話、目前閱讀的頁面內容、章節摘要、人物卡、前情提要。`[程式碼確認]`

**注入防護**：讀者輸入與書籍正文只在 agentic 路徑用 `<reader-input>` 圍欄放進 user role（`AIAgenticAssistant.swift:359-374`）。一般問答把**書籍正文放在 system message**（`AIRAGPipeline.swift:45-46`），這與該檔自己的註解不一致（註解說「書籍正文只在 system 當片段引用」，`:79-81`），是刻意的設計取捨但值得注意。

**追問時檢索與生成是否看到相同背景？** 兩者都看不到歷史，所以「相同」——都是零。`[程式碼確認]`

**從普通回答升級成多步檢索時是否丟失歷史或閱讀位置？** 一般問答**永遠不會**升級成 agentic；兩條路徑是分開的功能（問答 vs 人物卡）。人物卡固定 `scope = 1.0`，不讀閱讀位置。`AIAssistantService.swift:183` `[程式碼確認]`

### 5.3 Agent 流程

| 項目 | 值 | 證據 |
|---|---|---|
| 可用工具 | `retrieve(query)`、`rewriteAndRetrieve(missing,queries)`、`finish(reason,answer,citations)` | `AIAgenticAssistant.swift:334-337` |
| 最大步數 | 人物卡呼叫傳 **3**（預設 5） | `AIAssistantService.swift:184`、`AIAgenticAssistant.swift:54` |
| 總查詢預算 | **5**（預設） | `AIAgenticAssistant.swift:55, 102` |
| 每次命中數 | `retrieveLimit = 8` | `:90, 207` |
| 停止條件 | ①`action=finish` ②步數用盡 ③planner 無法解析 ④無新查詢／預算用盡 ⑤連續 2 輪無新 chunk | `:151, 132, 180, 226` |
| 失敗回退 | 全部走 `synthesize()`（再一次 generate）；synthesize 也解析失敗 → **回空字串** | `:254-294` |

**次數區分（不要混為一談）**：
- **模型呼叫次數**：最多 3 次 planner/answer + 最多 1 次 synthesize = **4**
- **檢索次數**：最多 **5**（`maxQueries`）
- **全文掃描次數**：**0**。agentic 流程從不遍歷全書，只做 TopK 檢索

### 5.4 人物卡 JSON 處理

| 項目 | 現況 | 證據 |
|---|---|---|
| schema | `{"firstAppearance":string,"role":string,"relationships":[string],"aliasCandidates":[string],"summary":string}`，寫在 prompt 裡，**沒有 JSON mode / response_format / function calling** | `AICharacterProfile.swift:60-67`；請求體無 `response_format` 欄位（`OpenAICompatibleProvider.swift:66-83`） |
| 輸出限制 | `max_tokens` 1024 | `AIAgenticAssistant.swift:57` |
| 截斷偵測 | **沒有**。不看 `finish_reason`（回應解析只取 `choices[0].message.content`） | `OpenAICompatibleProvider.swift:85-91, 144-149` `[程式碼確認]` |
| 解析失敗 | 去 ``` 圍欄 → 直接 decode → 失敗則取第一個 `{` 到最後一個 `}` 再試 | `AIAgenticAssistant.swift:379-392`、`AICharacterProfile.swift:90-92` |
| 重試／修復 | **沒有自動重試**。UI 有「重新整理」按鈕需手動點 | `AICharacterListView.swift:284-296` |
| **malformed JSON 是否被存成正常人物卡？** | **是。** summary = 原始文字，結構欄位全空，照樣 `upsert` 進 store，UI 照樣顯示成一張卡 | `AICharacterProfile.swift:106-120` → `AIAssistantService.swift:194` `[程式碼確認]` |

### 5.5 引用做到哪一層

| 宣稱 | 問答 | 人物卡 |
|---|---|---|
| 「ID 確實存在」 | ✅ `AICitationParser.parse` 只保留 `byID[id]` 命中的（`AIRAGPipeline.swift:139`） | ✅ agentic 內部有 `gatheredIDs.contains` 過濾（`AIAgenticAssistant.swift:154`） |
| 「片段確實送給模型」 | ✅ 引用來源就是送出的 `chunks` 陣列 | ⚠ **存進卡片的是全部送出的 chunk，不是模型引用的**（`AIAssistantService.swift:191` 用 `result.retrievedChunks`，丟棄了 `result.citationChunkIDs`） |
| 「片段真的支持該結論」 | ❌ 未驗證 | ❌ 未驗證 |

**自評 envelope 的現況**：模型被要求輸出 `[[SELFASSESS:nonce]]{"sufficient":…}[[/SELFASSESS:nonce]]`，解析器把它從正文剝掉，但**回傳的 `assessment` 被丟棄**，不觸發補充檢索、不顯示給使用者。`AIRAGPipeline.swift:105-107`（只用 `.body`）`[程式碼確認]`

---

## 6. 人物卡與小說的持久記憶

### 6.1 實際存在的資料模型

| 資料 | 有無 | 儲存 | 證據 |
|---|---|---|---|
| 章節摘要 | ❌ **沒有** | — | 全 repo 無此結構 |
| 篇章摘要 | ❌ **沒有** | — | — |
| 人物實體 | ⚠ 只有 `AICharacterProfile`（一段文字檔案，非結構化實體） | `Application Support/AICharacterCards/<bookID>.json` | `AICharacterCardStore.swift:24, 74-75` |
| 別名 | ✅ 兩處：卡片的 `aliasCandidates`、說話人名單 `[候選詞:正式名]` | 卡片同上；名單在 UserDefaults `yd_ai_speaker_rosters.<bookID>` | `AICharacterProfile.swift:43`、`AISpeakerRosterStore.swift:19, 53-54` |
| 人物出場記錄 | ❌ **沒有**。只有 `firstAppearance`（一句自由文字） | — | `AICharacterProfile.swift:38` |
| 事件 | ❌ **沒有** | — | — |
| 關係變化 | ❌ **沒有**。只有 `relationships: [String]`，是一組沒有時間軸的句子 | — | `AICharacterProfile.swift:40` |
| 原文證據 | ⚠ `citationChunkIDs`，但語意是「送進模型的」而非「支持結論的」 | 同卡片 | `AICharacterProfile.swift:46` |
| 揭露位置 | ❌ **沒有** | — | — |
| 處理進度 | ❌ **沒有**。無逐章覆蓋表 | — | — |
| 對話紀錄 | ✅ 純聊天記錄，**不參與任何檢索或生成** | UserDefaults `yd_ai_chats.<bookID>`，每書上限 30 場 × 60 則 | `AIChatStore.swift:12-13, 18` |
| 前情提要 | ✅ 一段文字 + 產生時的進度/時間/模型/promptVersion | UserDefaults `yd_ai_recaps.<bookID>` | `AIRecap.swift:13-21`、`AIRecapStore.swift:13` |
| 索引 | ✅ chunk 全文 + 向量 + 章名表 | `Application Support/AIBookIndexes/<bookID>.json` | `AIBookIndexStore.swift:29-37, 82` |

**明確結論：這裡沒有事件資料庫。** 有的是「一本書一份 chunk 索引 + 一疊人物簡介 + 一份別名表 + 聊天記錄」。

### 6.2 逐題回答

**人物卡是「指定名字後搜尋少數片段生成」還是「逐批處理正文累積合併」？**
→ **前者。** 最多 5 次 TopK 檢索（每次 8 個 chunk），上限 40 個 chunk ≈ 32000 字，佔百萬字小說的 3%。`AIAgenticAssistant.swift:88-90, 204-209` `[程式碼確認]`

**所謂「全書掃描」實際完成的是什麼？** 四件事必須分開講 `[程式碼確認]`：

| 項目 | 有沒有做 |
|---|---|
| 取得全文 | ✅ `gatherAIBookText()` 把裝置上有的章節全讀進來（`ReaderView+SourceChange.swift:1110`） |
| 建立全文 embedding | ⚠ **只有在使用者自行下載並安裝了模型時**；預設沒有模型 → 只有 BM25 |
| 讓生成模型逐批讀全文 | ❌ **完全沒有**。全書掃描是正則啟發式，零 LLM 呼叫（`AICharacterListView.swift:236-238` → `AIBookSpeakerScan.scan`） |
| 結構化抽取與人物合併 | ⚠ **只有一次**：手動按「用 AI 整理名單」，一次 LLM 呼叫做「候選詞 → 是不是人 / 正式名」的映射（`AISpeakerRoster.swift:94-101`）。不抽事件、不抽關係、不抽出場 |

**逐章／逐批的成功、失敗、待重試覆蓋紀錄？** → **沒有。** 失敗章節在 `gatherAIBookText`（`ReaderView+SourceChange.swift:1120-1122`）與 chunker（`AIChunking.swift:117`）兩處靜默略過。`[程式碼確認]`

**新章節加入時怎麼更新？** → `contentFingerprint` 變 →（設計上）整份索引重建。**非增量**。且 A1 使得磁碟索引本來就沒被重用。`[程式碼確認]`

**人物同名、別名、錯合併怎麼處理？**
- 別名來源兩處：卡片 `aliasCandidates`、名單 `roster`；合併時**卡片優先**（`ReaderView+SourceChange.swift:983` `{ _, card in card }`）。
- 同名不同人：**無處理**。`AICharacterCardStore` 以 `name` 為 key（`AICharacterCardStore.swift:43-55`），兩個同名角色會互相覆蓋。
- 錯合併：無偵測、無回復。一個錯誤別名會讓兩個角色在多角色朗讀裡共用一個聲音。
- 保護措施：`AISpeakerRoster.parse` 對模型沒提到的候選詞**保留為自己**，避免截斷答案刪掉角色（`AISpeakerRoster.swift:79-89`）。

**人物卡是覆寫摘要還是保存獨立事實？** → **整張覆寫。** `upsert` 直接以新 profile 取代同名舊卡（`AICharacterCardStore.swift:43-53`）。沒有事實層、沒有版本、沒有合併。`[程式碼確認]`

### 6.3 防劇透

| 路徑 | 機制 | 強度 |
|---|---|---|
| 一般問答 | **檢索層硬擋**：`progressEnd <= 進度`，超出的文字**根本不會送給模型** | 強（非 prompt） |
| 前情提要 | 同上，用 `AISpoilerSafeFilter.chunks` | 強 |
| 人物卡 | **`scope = 1.0` 固定全書**，只在 prompt 寫「不要透露該人物的最終結局或生死」 | **弱（純 prompt）** |
| 人物列表預設範圍 | `scope = .read`，只列進度以內出現過的角色；「掃描整本書」是明確的一次點擊 | 中（UI 層） |
| 使用者開關 | `gs.aiSpoilerSafe`，**預設 true**，輸入框上的膠囊可切換 | `GlobalSettings.swift:2099`、`AIAssistantPanelView.swift:36, 429` |

**後期才揭露的身分／別名／關係是否可能進入前期的人物卡、摘要或檢索？**

| 途徑 | 會不會 |
|---|---|
| 進入人物卡 | **會。** 人物卡讀全書，只有 prompt 擋結局，沒擋身分與別名 `[程式碼確認]` |
| 進入前情提要 | 不會。走進度過濾 |
| 進入問答檢索 | 不會。走進度過濾 |
| **已產生的全書人物卡是否可能被已讀範圍問答引用？** | **不會。** `AIRAGPipeline.answer` 只接受檢索 hits，服務層不讀 `AICharacterCardStore`（`AIAssistantService.swift:121-142`）`[程式碼確認]` |
| **卡片的別名是否會外溢？** | **會，往多角色朗讀外溢。** 卡片別名合進 `roster` 餵給 `TTSSpeakerAnnotator`（`ReaderView+SourceChange.swift:982-983`）。後期才揭露的化名一旦進了卡片，聽書時該化名會立刻用上真身的聲音 `[推論]`（機制確認，未實測聽感） |

---

## 7. 一條可核對的問答紀錄

### 7.1 結論：**沒有真實 runtime 紀錄可用**

`[執行確認]` 本機搜尋結果：

| 找什麼 | 結果 |
|---|---|
| 任何模擬器上的 `AIBookIndexes` / `AICharacterCards` / `AIEmbedding` 目錄 | **不存在**（`find ~/Library/Developer/CoreSimulator/Devices … ` 無輸出） |
| 任何模擬器上的 `yd_ai_*` UserDefaults | 只有 1 個 key：`yd_ai_provider_configuration`（在 `B4947D2C…` 上，值為預設 DeepSeek 設定）。**沒有** `yd_ai_chats`、`yd_ai_recaps`、`yd_ai_speaker_rosters`、embedding source URL |
| AI 模組內的檢索／生成 log | **零**。`Modules/Core/AI` + `Modules/Services/AI` 全部 6 處 `AppLogger` 呼叫都是儲存／模型載入的 `.error`，沒有任何一處記錄查詢、命中、prompt 或回覆 |
| agentic trace | `AIAgenticResult.trace` 有被建立，但**模組外從未被讀取**（`grep` 確認），不寫 log、不進 UI、不持久化 |

你截圖裡的失敗案例（51% 前情提要失敗、空答案、94% 兩個角色）來自**真機**，本機取不到該裝置的容器。

**因此：本節只有靜態呼叫鏈，未取得真實請求。** 以下 §7.2 是依程式碼重建的請求範例，標示為 **reconstructed**，不是 observed。

### 7.2 Reconstructed 請求（非實測）

> ⚠ **RECONSTRUCTED — 由 §3.A / §5.2 的程式碼推導，並非任何一次真實請求的紀錄。** 內容中的書名、片段、chunkID 皆為示意，非真實小說內容。

假設：讀者讀到 51%，防劇透開啟，問「張若塵第一次見到黑袍人是在哪裡？」

```
POST https://api.deepseek.com/v1/chat/completions
Authorization: Bearer ***REDACTED***
Content-Type: application/json

{
  "model": "deepseek-chat",
  "temperature": 0.2,
  "top_p": 1.0,
  "max_tokens": 1024,
  "messages": [
    { "role": "system", "content":
      "你是閱讀助手。只能根據下面提供的書內片段回答問題。\n\n規則：\n- 每個論斷後面用 [片段ID] 標註來源，例如 [<bookUUID>:12:0]；可以標多個。\n- 只使用提供的片段，不要編造，也不要引用沒有提供的片段。\n- 如果片段不足以回答，直接說「書中（防劇透範圍內）沒有相關內容」，不要臆測。\n- 用繁體中文回答。\n\n\n回答正文之後必須附上且只附上一個內部自評區塊（不要向使用者解釋它）：\n[[SELFASSESS:A1B2C3]]{\"sufficient\":\"full|partial|insufficient\",\"missing\":\"…\"}[[/SELFASSESS:A1B2C3]]\n…\n\n片段：\n[<bookUUID>:12:0]\n<約 800 字正文>\n\n[<bookUUID>:12:1]\n<約 800 字正文>\n\n…（共 8 段）"
    },
    { "role": "user", "content": "張若塵第一次見到黑袍人是在哪裡？" }
  ]
}
```

**注意這裡沒有的東西**：沒有 `stream`、沒有 `response_format`、沒有歷史訊息、沒有人物卡、沒有摘要。system message 大小 ≈ 8 × 800 + 規則 ≈ **6600 字**，無 token 計算、無上限保護。

### 7.3 下一次最少需要收集的欄位（與插入點）

> 本次**未**新增任何診斷程式碼。以下是給下一輪的清單。

| 欄位 | 建議插入點（檔案:行） |
|---|---|
| `bookID` / 章節總數 / 有文字章節數 / 總字數 | `ReaderView+SourceChange.swift:1129`（`gatherAIBookText` 結束時），資料現成：`adapter.contentFingerprint` |
| 索引身分 / chunk 數 / tier / 建立耗時 | `AIAssistantService.swift:105`（`indexState = .ready` 處） |
| 實際搜尋詞 / 各階段候選數（BM25、向量、RRF 後、進度過濾後、最終） | `AIBookRetrievalIndex.swift:113-130`（`retrieve` 內每一步） |
| 最終送出的 chunkID 清單 + 每個的 `progressEnd` | `AIRAGPipeline.swift:101-103` |
| messages 的 role 與**長度**（不要記內容） | `OpenAICompatibleProvider.swift:118`（`httpBody` 組完後） |
| HTTP 狀態 / `finish_reason` / 回覆長度 | `OpenAICompatibleProvider.swift:142-149`（目前 `finish_reason` **根本沒被解碼**，需先加進 `ChatResponseBody`） |
| 解析出的引用數 / `hasEvidence` | `AIRAGPipeline.swift:114-123` |
| agentic 每步的 action / 查詢 / 新增 chunk 數 / 停止原因 | `AIAgenticAssistant.swift:216-222`（`trace` 已經建好了，只差寫出去） |
| 分階段耗時 | 專案已有 `SourcePerfTrace`（見 `CLAUDE.md`），可在上述同樣位置加 span |

**目前完全沒有任何耗時數據**，本報告不做任何耗時估算。`[無法確認]`

---

## 8. 問題與未知事項

### A. 有程式或執行證據支持的實作問題

---

**A1 — 磁碟索引永遠失效，每次啟動重建整本書** 🔴

| | |
|---|---|
| 證據 | `AIBookIndexStore.load()` 在 `AIBookIndexStore.swift:95-102` 用 `AIBookRetrievalIndex(bookID:chunks:sectionTitleByID:tier:embeddingIdentifier:vectors:)` 重建物件，**沒有傳 `contentFingerprint`**；該參數預設 `""`（`AIBookRetrievalIndex.swift:68`），於是 `identifier` 被算成 `keyword@none@recursive.v2@`（`:75-79, 90-96`）。而 `expectedIdentifier(for:)` 一定帶真實指紋（`AIAssistantService.swift:51-58`）。兩者在 `AIBookIndexStore.swift:53` 的比較**恆為 false**。`Stored.identifier`（`:30`）被存進檔案但**從未被讀回使用**。`[程式碼確認]` |
| 觸發條件 | 每一次冷啟動後第一次使用任何 AI 功能 |
| 使用者症狀 | 每次重開 App 問第一個問題都要等很久；hybrid tier 下等於**重跑整本書的 embedding**（數百章 = 數千次 Core ML 推論，分鐘級 + 耗電）。使用者會覺得「AI 很慢」且「每次都要等」 |
| 影響範圍 | 正確性不受影響（重建出來的索引是對的），純粹是成本 |
| 引入時機 | `f7e472a5`，即本次 commit 加入 `contentFingerprint` 時 |
| 最小驗證 | 一個不需模擬器的單元測試：`let a = AIBookRetrievalIndex(bookID:…, contentFingerprint: "1/1/100")`，存進 `AIBookIndexStore(directory: 暫存目錄)`，再以同一個 `expectedIdentifier` 取回，斷言 `build` 閉包**沒有**被第二次呼叫。目前 `AIBookIndexStore` **一個測試都沒有**（`grep -rln AIBookIndexStore Tests/` 無結果，`[執行確認]`） |
| 最小修法（**本次未施作**） | `AIBookIndexStore.swift:95-102` 的 `Stored` 需要多存 `contentFingerprint`，或改成 `load()` 直接比對 `stored.identifier` 而非重算 |

---

**A2 — 多輪對話沒有任何歷史，追問等同新問題**

| | |
|---|---|
| 證據 | `AIAssistantService.answer(question:bookID:adapter:progress:)`（`AIAssistantService.swift:121-126`）只收單一字串；`AIRAGPipeline.request`（`AIRAGPipeline.swift:75-88`）恆組 `[system, user(query)]`；`AIAssistantPanelView.send` 只傳 `question`（`:514-519`）。`AIChatSession.messages` 只給 UI 與 `AIChatStore`。`[程式碼確認]` |
| 觸發條件 | 任何含代詞或省略主語的追問 |
| 使用者症狀 | 「那他後來為什麼背叛？」→ 檢索詞含「他」「背叛」，命中一堆不相干的背叛段落；模型不知道「他」是誰，只能從 8 個隨機片段裡猜。這正是你說的「使用效果不理想」最直接的來源之一 |
| 最小驗證 | 在 `AIAssistantFeatureTests` 加一個假 provider，斷言 `answer()` 送出的 `messages.count == 2`（現在必定成立，即證明無歷史） |

---

**A3 — `charOffset` 單位不一致：AI 側是 Character，閱讀器側是 UTF-16**

| | |
|---|---|
| 證據 | AI 側：`AIChunking.swift:190` `Array(text)`（Character 陣列）、`AIBookContentAdapter.swift:40-41` `text.count`（Character 數）、`:51` 以此 clamp。閱讀器側：`CoreTextReadingPositionMapper.clampedCharOffset` 用 `layout.attributedString.length`（**UTF-16**，`CoreTextReadingPosition.swift:42`）。`[程式碼確認]`<br>實測：`"𠮷野家的𡈽"` → `Character.count = 5`，`utf16.count = 7` `[執行確認]` |
| 觸發條件 | 章節內含任何非 BMP 字元（CJK 擴展 B 罕用字、emoji、變體選擇符）。中文網文出現罕用字並不少見 |
| 使用者症狀 | 點引用卡跳回原文，落點偏前；偏移在章內**單向累積**，一章內罕用字越多、越往後偏得越遠 |
| 最小驗證 | 純邏輯測試：對一段含 `𠮷` 的文字建 adapter，比對 `chunkLocation(…).charOffset` 與 `(text as NSString)` 上同一位置的 index |

---

**A4 — 進度天花板的輸入也是同一個單位錯配**

| | |
|---|---|
| 證據 | `aiReadingProgress()`（`ReaderView+SourceChange.swift:1137-1142`）把 `currentPagedReadingPositionForModeSwitch()?.charOffset`（UTF-16）直接當成 `characterOffset` 傳進 `chunkLocation`（該參數被當 Character 用，`AIBookContentAdapter.swift:51`）。`[程式碼確認]` |
| 觸發條件 | 同 A3 |
| 使用者症狀 | 防劇透的邊界比實際閱讀位置**略微偏後**（UTF-16 數字較大），可能讓尚未讀到的一小段內容進入檢索範圍。影響量級小，但方向是「漏防」而非「過防」 |
| 最小驗證 | 同 A3，比對 `progress(forSpine:charOffset:)` 在兩種單位下的輸出差 |

---

**A5 — 人物卡的「引用」存的是全部送進去的片段，不是模型引用的**

| | |
|---|---|
| 證據 | `AIAssistantService.swift:191` 用 `gatheredChunkIDs: result.retrievedChunks.map(\.id)`；而 agentic 已經算好了真正的引用 `result.citationChunkIDs`（`AIAgenticAssistant.swift:154, 164, 297`），**被丟棄**。`[程式碼確認]` |
| 觸發條件 | 每一張人物卡 |
| 使用者症狀 | 卡片宣稱有 N 個原文依據，實際上那只是「檢索到的候選」。使用者若據此核對，會發現多數片段跟卡片內容無關 |
| 最小驗證 | 用 `ScriptedProvider`（`AIAgenticAssistantTests.swift:208` 已有）讓模型只引用 1 個 id，斷言存下的 `citationChunkIDs.count == 1` —— 現在會是 gathered 的全部 |

---

**A6 — 解析失敗的人物卡照樣存檔，看起來像正常卡片**

| | |
|---|---|
| 證據 | `AICharacterProfile.parse` 解析失敗時回傳 `summary = 原始文字`、結構欄位全空的 profile（`AICharacterProfile.swift:106-120`），呼叫端無條件 `upsert`（`AIAssistantService.swift:194`）。UI 的 `profileSection`（`AICharacterListView.swift:326`）對這種卡沒有任何標記。`[程式碼確認]` |
| 觸發條件 | 模型輸出被 `max_tokens=1024` 截斷、或輸出非 JSON 前言 |
| 使用者症狀 | 卡片只有一段散文、沒有身分/關係/別名，看起來像「這個角色資訊就是比較少」，而不是「這次失敗了」。**別名為空也意味著多角色朗讀拿不到這個角色的別名** |
| 相關 | `finish_reason` 根本沒被解碼（`OpenAICompatibleProvider.swift:85-91`），所以連「是否被截斷」都無從得知 |
| 最小驗證 | `OneShotProvider` 回傳 `"{\"role\":\"主角\""`（截斷的 JSON），斷言存下的卡片有某種 `isDegraded` 標記 —— 目前沒有這個概念 |

---

**A7 — 零命中時說「書中沒有」，而不是「目前未找到」**

| | |
|---|---|
| 證據 | `AIRAGPipeline.noEvidenceResult`（`AIRAGPipeline.swift:55-68`）回固定字串「書中（防劇透範圍內）沒有與這個問題相關的內容。」；`answer` 在 `hits.isEmpty` 時直接回它（`:98-100`）。`[程式碼確認]` |
| 觸發條件 | BM25 分詞沒切出可匹配的詞、或該書索引覆蓋不全 |
| 使用者症狀 | 系統對一本它只索引了一半的書，斬釘截鐵地說「書中沒有」。這是**把檢索失敗說成事實**，也是最傷信任的一種錯誤 |
| 最小驗證 | 已有測試涵蓋這條路徑的觸發（`AIAssistantFeatureTests`），改的是措辭與是否附上覆蓋率 |

---

**A8 — 向量維度不符時靜默降級，UI 仍宣稱「關鍵詞 + 語意」**

| | |
|---|---|
| 證據 | `AIBookRetrievalIndex.vectorHits` 的 `guard let vector = vectors[chunk.id], vector.count == query.count else { continue }`（`:138`）——不符就跳過該 chunk，不報錯。`descriptor.dimensions = 512`（`AIEmbeddingModel.swift:38`）從未與模型實際輸出比對（`:233`）。UI 只看 `embedding.isInstalled` 就顯示「關鍵詞 + 語意」（`AISettingsView.swift:224`）。`[程式碼確認]` |
| 觸發條件 | 使用者貼了一個維度不同的模型 URL（這**完全可能**，因為沒有官方託管位址，URL 是使用者自己找的） |
| 使用者症狀 | 設定頁顯示語意檢索已啟用，實際上向量命中恆為 0，等於白下載 258 MB、白算一輪 embedding |
| 最小驗證 | 假 provider 回 256 維，建 hybrid index，斷言 `retrieve` 的結果與 keyword-only 相同 |

---

**A9 — 檢索與生成完全沒有 log，事後無法診斷**

| | |
|---|---|
| 證據 | `Modules/Core/AI` + `Modules/Services/AI` 全部 6 處 `AppLogger` 都是儲存/模型載入的 `.error`（`[執行確認]`，見 §7.1）。`AIAgenticResult.trace` 建好但模組外從未被讀。`[程式碼確認]` |
| 使用者症狀 | 你截圖裡的三個失敗，沒有任何一個能從裝置日誌回推原因 —— 這次稽核之所以只能做靜態分析，直接原因就是這個 |
| 最小驗證 | 見 §7.3 的插入點清單 |

---

**A10 — `stream()` 完整實作但無人呼叫，答案一次性出現**

| | |
|---|---|
| 證據 | `OpenAICompatibleProvider.stream`（`:162-…`）含 SSE 解碼與 `[DONE]` 處理；`grep "\.stream("` 在 production 只命中 `BookOriginSearchService`（`[執行確認]`）。所有 AI 路徑走 `generate()`（6 處呼叫，見 §grep）。`[程式碼確認]` |
| 使用者症狀 | 問一個問題後只有「思考中…」，`max_tokens=1024` 的答案要等完整生成完才一次出現。長答案的體感很差 |

---

**A11 — 索引把全書正文再存一份 JSON**

| | |
|---|---|
| 證據 | `Stored.chunks: [AIContentChunk]`，`AIContentChunk.text` 是完整正文（`AIBookIndexStore.swift:33`、`AIChunking.swift:35`）；`JSONEncoder().encode(stored)` 整份寫檔（`:119`）。`[程式碼確認]` |
| 觸發條件 | 每次索引建立後 |
| 使用者症狀 | 百萬字小說會在 Application Support 產生一份**大於原文**（含 15% overlap + JSON 轉義）的檔案。多本書會累積。目前沒有任何清理或容量上限 |
| 相關 | 因為 A1，這個檔案寫了之後**永遠不會被讀** |

---

**A12 — 人物列表只在 `onAppear` 掃描一次，全書文字抓完後不會重掃**

| | |
|---|---|
| 證據 | `AICharacterListView.onAppear { … scanBook() }`（`:89-94`），`scanBook` 的 guard 是 `force || (scanned.isEmpty && !isScanning)`（`:230`）。`gatherAIBookText` 只在兩個 sheet 的 `.task` 觸發（`ReaderView.swift:2392, 2411`），完成後 `aiChapterTexts` 更新會讓新的 adapter 傳下來，但 `scanned` 不重算。`[程式碼確認]` |
| 觸發條件 | 在全書文字抓完之前就導航到人物卡頁 |
| 使用者症狀 | 角色列表停在部分掃描的結果；要手動點「掃描整本書」才會用完整文字重跑 |

---

**A13 — 前情提要固定只取最後 12 個 chunk**

| | |
|---|---|
| 證據 | `AIAssistantService.swift:155-156` `Array(readable.suffix(12))`。`[程式碼確認]` |
| 觸發條件 | 任何長度的書 |
| 使用者症狀 | 12 × 800 ≈ 9600 字 ≈ 三四章。對「讀到第 500 章」的使用者，「前情提要」實際上是「前三章提要」。沒有分層摘要，所以第 1–496 章的內容完全不在裡面 |

---

**A14 — 自評 envelope 解析後被丟棄**

| | |
|---|---|
| 證據 | `AIRAGPipeline.answer` 只用 `parser.finish().body`，丟掉 `.assessment`（`AIRAGPipeline.swift:105-107`）；`AISelfAssessmentStreamParser.finish()` 明明回傳 `(body, assessment)`（`AISelfAssessment.swift:116`）。全 repo 無任何處讀取 `assessment`（`[執行確認]`）。`[程式碼確認]` |
| 使用者症狀 | 每次問答都付費要求模型輸出一段自評，然後丟掉。既不用它觸發補充檢索，也不顯示「這個答案證據不足」 |

---

### B. 目前設計沒有覆蓋的需求

| 編號 | 需求 | 現況缺口 |
|---|---|---|
| B1 | 跨章節因果 | 只有 flat chunk + 單跳 TopK。沒有實體圖、沒有事件鏈、沒有多跳檢索。**架構上不存在能回答因果的資料** |
| B2 | 章節／篇章摘要階層 | 完全沒有。百萬 token 的書只有 800 字的葉節點 |
| B3 | 批次生成人物經歷 | 沒有任何批次處理入口。人物卡是單人、即時、上限 40 chunk |
| B4 | 逐章覆蓋記錄（成功/失敗/待重試） | 沒有。失敗兩處靜默略過 |
| B5 | 增量索引 | 沒有。新章節 → 指紋變 → 全量重建 |
| B6 | 人物卡累積事實 | 沒有。整張覆寫 |
| B7 | 同名角色消歧 | 沒有。`name` 是唯一 key |
| B8 | token 預算與上下文管理 | 沒有。零處 token 計算，8 chunk 是寫死的 |
| B9 | 查詢改寫／人名別名擴展（一般問答） | 沒有。只有人物卡的 agentic 路徑會改寫 |
| B10 | reranker / 鄰接片段補讀 / 分數門檻 | 三者皆無 |
| B11 | 覆蓋率透明度 | `contentFingerprint` 有資料但不顯示；使用者無從知道 AI 看得到這本書的多少 |
| B12 | 人物卡的防劇透 | 只有 prompt。與問答/前情提要的檢索層硬擋不同標準 |

### C. 需要樣本或實測才能判斷的假說

| 編號 | 假說 | 為什麼現在無法判斷 | 最小驗證 |
|---|---|---|---|
| C1 | 800 字 chunk + BM25 對「第 500 章問前面情節」的召回率不足 | 沒有真實語料的檢索紀錄 | 取一本已索引的書，離線跑 `AIBookRetrievalIndex.retrieve`，人工標注 20 個問題的 top-8 是否含正解。不需呼叫任何付費 API |
| C2 | `NLTokenizer` 的中文分詞會把人名切碎，傷害人名檢索 | 分詞結果從未被檢視 | 純邏輯測試：`AIBM25Index.tokenize("張若塵走進了黑風谷")`，看 `張若塵` 是否為一個 token |
| C3 | distiluse 的 512 token 上限會截斷 800 字的 chunk | 模型內部行為，App 端看不到（`AIEmbeddingModel.swift:227-232` 直接丟字串） | 需先取得模型與其 config；或對同一 chunk 的前 400 字與全文分別 embed，比較 cosine 是否 ≈ 1（若是，代表後半被丟棄） |
| C4 | 數千章的 `gatherAIBookText` 會造成可感知的卡頓或記憶體壓力 | 從未實測；HTML→文字已 detach 到背景（`EPUBAttributedStringBuilder.swift:99-101`），但 zip 讀取次數是章節數 | 用一本真實長篇，在 `ReaderView+SourceChange.swift:1110/1129` 兩端加計時，記錄總耗時與峰值記憶體 |
| C5 | 目錄/版權頁被當成正文索引，污染檢索 | 未檢視任何真實 EPUB 的 spine | 對一本真實 EPUB 跑 `AIBookContentAdapter`，印出前 5 個 section 的前 100 字 |

---

## 9. 已執行測試及結果

### 9.1 已執行

`[執行確認]` 指令：`bash scripts/xctest.sh -- -only-testing:…`（11 個 suite），destination `id=69BF10A0-6C96-44AC-8343-457985D98740`（iOS 27.0 模擬器）。

```
✔ Test run with 116 tests in 11 suites passed after 0.193 seconds.
** TEST SUCCEEDED **
```

| Suite | @Test 數 | 驗證的是什麼 |
|---|---|---|
| `AIAgenticAssistantTests` | 10 | **流程與解析**（`ScriptedProvider` 假回覆）：步數/查詢預算、無新證據停止、JSON 圍欄容錯、引用過濾 |
| `AIAssistantFeatureTests` | 19 | **流程與解析**（`CountingProvider`/`EnvelopeEchoProvider`）：零命中不呼叫模型、自評剝除、標記清除 |
| `AIBookRetrievalIndexTests` | 9 | **檢索邏輯**（`CountingEmbedding` 假向量）：index 身分、進度過濾在 TopK 前、keyword tier 可用 |
| `AIProviderPresetTests` | 9 | 供應商預設與 base URL 正規化 |
| `AIProviderTests` | 13 | **傳輸層**（假 provider + `URLProtocol`）：SSE 解碼、`[DONE]`、錯誤映射 |
| `AIRetrievalTests` | 14 | RRF 融合、排序穩定性、`AISpoilerSafeFilter` 邊界 |
| `AISelfAssessmentTests` | 9 | nonce 圍欄的跨 delta 串流解析 |
| `AISpeakerRosterTests` | 8 | 名單 JSON 解析、未提及候選詞保留 |
| `ChapterPlainTextTests` | 6 | HTML→文字保留段落、剝 script/style、adapter 取得未排版章節 |
| `TTSSpeakerAnnotatorTests` | — | 說話人歸屬 |
| `ReaderDialogueSpeakerTests` | — | 對話說話人啟發式 |

**這些測試驗證的是「流程正確」與「解析正確」，全部使用測試替身。** `[程式碼確認]`（7 個假 provider/embedding，見 §grep 結果）

**它們沒有驗證、也不能宣稱驗證的**：
- 真實模型的回答品質
- 真實長篇小說的檢索召回率
- 真實 embedding 模型的向量品質
- 任何一次真實的 HTTP 請求
- A1（`AIBookIndexStore` **零測試覆蓋**）

### 9.2 未執行及原因

| 未執行 | 原因 |
|---|---|
| 呼叫真實 LLM API | 稽核規則禁止（付費、且會送出書籍內容） |
| 真實書籍的端到端問答 | 同上；且本機模擬器無任何書籍與索引資料 |
| embedding 模型驗證 | 本機未安裝模型（`AIEmbedding` 目錄不存在，`[執行確認]`），且無官方託管位址 |
| A1 的執行級驗證 | 需要新增測試檔 = 修改 repo，逾越本次「唯讀稽核」邊界。程式碼證據已足以定案 |
| 全量測試套件 | 本次只跑 AI 相關 11 個 suite。**參考**：稍早同工作區的全量跑為 `3174 tests in 442 suites, 29 issues`，29 個失敗全部在 BrowserLayout / ruby / chapter alignment / storage migration / aggregate search / rule engine / reader theme，與 AI 無關 |
| UI 手動操作驗證 | 模擬器上無書籍資料；且不屬於本次靜態稽核範圍 |

---

## 10. 產出檔案

| 檔案 | 說明 |
|---|---|
| `AI_ARCHITECTURE_AUDIT.md` | 本報告（repo 根目錄） |

**未產出** `AI_REQUEST_TRACE.sanitized.json`：本次沒有取得任何真實請求紀錄（見 §7.1），把 reconstructed 請求另存成 trace 檔會讓下一位讀者誤以為那是實測資料。重建的請求範例保留在 §7.2，並已明確標示 `RECONSTRUCTED`。

---

## 附錄 A：關鍵程式碼片段

### A.1 索引身分不對稱（A1 的完整證據）

```swift
// Modules/Services/AI/AIBookIndexStore.swift:95-102  ← 載入時
return AIBookRetrievalIndex(
    bookID: bookID,
    chunks: stored.chunks,
    sectionTitleByID: stored.sectionTitleByID,
    tier: stored.tier,
    embeddingIdentifier: stored.embeddingIdentifier,
    vectors: stored.vectors
)                                    // ← contentFingerprint 未傳，預設 ""

// Modules/Core/AI/AIBookRetrievalIndex.swift:68, 75-79
contentFingerprint: String = ""      // ← 預設值
self.identifier = Self.identifier(
    tier: tier,
    embeddingIdentifier: embeddingIdentifier,
    contentFingerprint: contentFingerprint
)

// Modules/Services/AI/AIAssistantService.swift:51-58  ← 期望值永遠帶真實指紋
return AIBookRetrievalIndex.identifier(
    tier: embedding == nil ? .keyword : .hybrid,
    embeddingIdentifier: embedding?.identifier,
    contentFingerprint: adapter.contentFingerprint   // 例如 "300/300/4200000"
)

// Modules/Services/AI/AIBookIndexStore.swift:53  ← 比較恆為 false
if let loaded = load(bookID: bookID), loaded.identifier == expectedIdentifier {
```

### A.2 進度過濾在 TopK 之前（設計正確的部分）

```swift
// Modules/Core/AI/AIBookRetrievalIndex.swift:113-130
let candidateLimit = max(limit * 4, 32)
var rankings: [[AIRetrievalHit]] = [keyword.search(query: query, limit: candidateLimit)]
var weights: [Double] = [Self.keywordWeight]          // 1.2
if tier == .hybrid, let embedding, !vectors.isEmpty {
    let queryVector = try await embedding.embedQuery(query)
    rankings.append(vectorHits(for: queryVector, limit: candidateLimit))
    weights.append(Self.vectorWeight)                 // 1.0
}
var merged = rankings.count == 1 ? rankings[0]
    : AIReciprocalRankFusion.merge(rankings: rankings, weights: weights)
…
return Array(
    AISpoilerSafeFilter.apply(to: merged, maximumProgress: maximumProgress).prefix(limit)
)
```

### A.3 單位不一致（A3）

```swift
// Modules/Core/AI/AIChunking.swift:190      ← Character 陣列
return split(Array(text), maximum: maximum, level: 0)

// Modules/Services/AI/AIBookContentAdapter.swift:40-41, 51  ← Character 計數
lengths.append(text.count)
running += text.count
let clamped = min(max(characterOffset, 0), sectionLengths[sectionIndex])

// Modules/Core/ReaderCore/CoreText/CoreTextReadingPosition.swift:42  ← UTF-16
let upperBound = max(layout.attributedString.length, 0)
```

實測 `[執行確認]`：

```
text=普通中文一行。  Character.count=7  utf16.count=7
text=𠮷野家的𡈽      Character.count=5  utf16.count=7
text=測試🙂表情      Character.count=5  utf16.count=6
```

### A.4 人物卡引用的來源（A5）

```swift
// Modules/Services/AI/AIAssistantService.swift:187-193
let profile = AICharacterProfile.parse(
    fromAnswer: result.answer,
    name: name,
    gatheredChunkIDs: result.retrievedChunks.map(\.id),   // ← 全部送出的
    provider: result.provider,
    model: result.model
)
// result.citationChunkIDs（模型實際引用的，AIAgenticAssistant.swift:154/297 已算好）未被使用
```

---

## 附錄 B：本次執行的指令

```bash
git rev-parse --abbrev-ref HEAD && git log -1 --format='%H %ad %s' --date=iso
git status --porcelain                       # 空 → 工作區乾淨
git show --stat --format='' HEAD | grep -iE "/AI/"

grep -rn "showAIAssistantPanel|AICharacterListView\(" Modules Targets --include="*.swift"
grep -rn "\.stream\(" Modules --include="*.swift"
grep -riE "tokencount|countTokens|tiktoken|numTokens" Modules/Core/AI Modules/Services/AI
grep -rn "AppLogger\." Modules/Core/AI Modules/Services/AI --include="*.swift"

find ~/Library/Developer/CoreSimulator/Devices \
     \( -name AIBookIndexes -o -name AICharacterCards -o -name AIEmbedding \)   # 無輸出
plutil -p <app container>/Library/Preferences/com.zhangruilin.yuedureader.plist | grep yd_ai

swift <scratchpad>/units.swift               # Character vs UTF-16 實測

bash scripts/xctest.sh -l /tmp/audit-ai.log -- \
  -only-testing:'yuedu appTests/AIAgenticAssistantTests' \
  -only-testing:'yuedu appTests/AIAssistantFeatureTests' \
  -only-testing:'yuedu appTests/AIBookRetrievalIndexTests' \
  -only-testing:'yuedu appTests/AIProviderPresetTests' \
  -only-testing:'yuedu appTests/AIProviderTests' \
  -only-testing:'yuedu appTests/AIRetrievalTests' \
  -only-testing:'yuedu appTests/AISelfAssessmentTests' \
  -only-testing:'yuedu appTests/AISpeakerRosterTests' \
  -only-testing:'yuedu appTests/ChapterPlainTextTests' \
  -only-testing:'yuedu appTests/TTSSpeakerAnnotatorTests' \
  -only-testing:'yuedu appTests/ReaderDialogueSpeakerTests'
```

所有 `grep`/`find` 的完整輸出都在本報告對應章節引用。本次未執行任何寫入 repo 的指令（除產出本檔案外），未執行 `git add`/`commit`/`checkout`/`reset`/`stash`。
