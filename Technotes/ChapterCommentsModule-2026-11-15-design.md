# 本章說／段評模組設計（草案）

> 日期：2026-11-15　狀態：**已實作、未提交**——模組 JS、正文內的段評氣泡／熱評卡／作者說卡／本章說卡（TXT、線上來源、模組的書走 CoreText 路徑；EPUB 走新引擎，要套件 0.19.0，見下）、點擊開原生清單。**下面 §5–§7 是動工前的草案，與實作不同處以這一段為準。**
>
> 實作摘要（維護者 2026-11-15 更正：這四種都在正文裡，不是另開的清單）：
> - 插入走整章翻譯的 `ReaderTranslationLayout.splice`（一般化成每個區塊自己標記、可加 `Decorations`），氣泡和卡片**不佔原文字元**，書籤／高亮／進度不動。§6-1 的風險因此不存在。
> - `ReaderChapterDecorationSource`（Core）← `ReaderChapterCommentDecorator`（Features）：章第一次建文件時問模組，答案到了發 `updates`，閱讀器照翻譯更新的方式重排那一章。來源自己畫了段評的章不問。
> - 氣泡用 `.commentBadge`、卡片用 `ReviewCardRaster.image(card:)`＋`yd-review-full`，都走既有渲染器與「氣泡設定／卡片模板」。
> - 點擊：`ydreview://` 的 payload 多一個 `m`（`ModuleCommentTargets` 的 token），`ReaderReviewSheetContent` 開 `ChapterCommentsSheet`。
> - 段落對位 `ChapterParagraphMatch`：`quote` 文字唯一命中，或 `index`＋`paragraphCount` 與本機段數相同。
> - EPUB（維護者 2026-11-15：「直接做新引擎的吧」，原本「有評論的章改用舊引擎」作廢並已拆掉）：
>   - **套件** YueduCoreText 0.19.0（`f3f34dc`，2026-11-16 已發佈，專案釘 0.19.0）：帶 `data-added-content` 的 `<img>` 在原文**不佔字元**（`SourceTextBuilder.addedPictureRange()`，長度 0 的範圍）；`BrowserPageGeometry.buildPageAddedStarts`／`pageIndex(forCharOffset:addedIndex:…)` 讓「整頁只有卡片」的頁找得到。
>   - **App**：`BrowserChapterAdditions` 包住書的資源，把氣泡／卡片當 `<a href="ydreview://…"><img src="yd-added:…" data-added-content></a>` 塞進章節 HTML，圖片由它供應（同一個 `ReviewCardRaster`、同一套氣泡畫法）。位置沿用 `CoreTextReadingPosition.translationOffset`＝該頁第一張外加圖片的序號（維護者選的「位置多記第幾張卡片」）；開書還原（`ReaderOpeningRestore.target`）也帶著它，否則還原會落到後一頁。點擊由引擎的 `onLinkActivate` 轉給 `presentReview`。
>   - 卡片的玻璃底：`BrowserLayoutPageView` 對顯示清單裡每張有玻璃的卡片放一個 `ReviewCardGlassView`（跟 CoreText 頁同一個），分頁的整頁和捲動的磚格都是；底下的繪製（頁面自己的 `draw`、捲動的片段點陣圖）略過卡片（`ReaderDisplayListDrawer.draw(glassCards: .liveViews)`）。翻頁用的快照畫靜態替身（`.baked`）。
>   - 冷啟動重開在卡片頁：評論比第一次排版晚到，還原當下那一頁還不存在，先落在同一位移的正文頁。分頁 Coordinator 放上讀者所在那一頁時保留存下來的精確位置（`ReaderSettledPosition`，FB-247），不換成那頁的頁首；評論到了、章節重排時就照這個位置放回卡片頁。讀者自己翻過頁，位置就是新頁的頁首，不會被蓋回去（feedback #112 的規矩）。原本的 `ReaderOpeningRestore.awaitingAdditions` 已刪除。
>   - 順帶修的競態：`notifyChapterDataChanged` 會先取消並等完還在跑的 preload（評論在第一次排版途中到達時，舊內容的頁被當成新內容的答案）。
> - 驗證：分頁、捲動、冷啟動重開回到卡片頁在模擬器看過；卡片頁的翻頁／跨章、直排的排版是單元測試（直排沒在畫面上看過）。未驗證：翻譯與評論同時開啟的實機畫面（單元測試有蓋位置對應）。
> - 模擬器裡每次翻頁的落定（commit／onPageChanged／存檔）都拖到下一次輸入才出現在 log，普通頁也一樣（2026-11-16 兩個 session 都看到）；沒有查是工具還是 App。

## 1. 目標與不做的事

**目標**

- 一本書不管從哪裡來（本機 TXT／EPUB、任何線上來源、模組），只要有一個已安裝的模組認得它，就能在閱讀器裡看到**本章說**（整章的評論）和**段評**（某一段的評論數氣泡，點開看內容）。
- 模組可以跑 JavaScript（維護者 2026-11-15：「跑 js 也行，來源配置不就是 js 嗎」）。規則能寫宣告式的就寫宣告式，需要簽名、解密、拼參數的地方用 JS，見 §3.1。
- 畫面沿用現有的氣泡與評論卡片樣式設定，不做第二套外觀。

**不做**

- 發表評論、按讚、回覆（需要對方網站的登入，另一個題目）。
- 改動 Legado 來源配置自帶的段評：它們照原樣走原本的路。
- App 內建或官方提供任何「抓某個網文平台評論」的模組。格式開放給第三方，資料從哪來由模組作者負責（跟現在的 `reviews` 一樣）。

## 2. 現況（都查過程式碼）

| 項目 | 現況 | 位置 |
|------|------|------|
| 作品層評論（書評／熱評） | **已經跨來源**：任何有 `reviews` 的已安裝模組會替任何作品回答，本機書也算。 | `WorkReviews.swift`、`ModuleReviewProvider.swift` |
| 找「哪一本書」 | 三步：書本來就出自這個模組 → ISBN `lookup` → 書名＋作者 `search`（最多 3 筆）。沒有作者就不搜。 | `ModuleReviewProvider.records(for:)` |
| 段評氣泡／本章說卡片 | **只有** Legado 來源塞在正文 HTML 裡的標記；清理時改寫成 `ydreview://` 錨點，渲染成行內氣泡。 | `ReaderHTMLUtilities.sanitizeOnlineChapterMarkup`、`NodeAttributedStringRenderer` |
| 點氣泡之後 | 開來源自己的網頁（WebView），App 手上沒有評論文字。 | `LegadoReviewBrowserView`、`LegadoReviewActionRunner` |
| 結構化的「第幾段 → 評論」模型 | **沒有**。 | — |
| 本機書顯示段評的路徑 | **沒有**；改寫只在線上章節抓取時發生。 | `ChapterFetcher.swift:137, 362` |
| 閱讀位置 | `(spineIndex, charOffset)`；引擎 0.11 起每張圖片在原文佔一個字元。 | `project_picture_source_extent_011` |

最後一列是整個設計最大的限制，見 §6。

## 3. 模組格式（提議 3.0.3：頂層 `comments`）

跟 `reviews` 一樣掛在模組自己的 `search`／`lookup` 紀錄上，所以「找哪一本書」完全沿用現有三步，不新增第二套配對。三段鏈對應字幕／彈幕模組的「找作品 → 找集數 → 拿內容」：

```json
"comments": {
  "cacheDuration": 3600,
  "chapters": {
    "request": { "url": "https://example.com/api/books/{{id}}/chapters" },
    "list": { "items": "$.chapters[*]", "id": "$.id", "title": "$.title", "nextPage": "$.next" }
  },
  "counts": {
    "request": { "url": "https://example.com/api/chapters/{{chapterId}}/paragraphs" },
    "list": { "items": "$.paragraphs[*]", "id": "$.pid", "quote": "$.text", "index": "$.no", "count": "$.total" },
    "chapterCount": "$.chapterTotal"
  },
  "paragraph": {
    "request": { "url": "https://example.com/api/chapters/{{chapterId}}/p/{{paragraphId}}?page={{page}}" },
    "list": { "items": "$.list[*]", "text": "$.content", "author": "$.user", "date": "$.time", "likes": "$.likes" }
  },
  "chapter": {
    "request": { "url": "https://example.com/api/chapters/{{chapterId}}/comments?sort={{sort}}&page={{page}}" },
    "sorts": [{ "title": "最熱", "value": "hot" }, { "title": "最新", "value": "new" }],
    "list": { "items": "$.list[*]", "text": "$.content", "author": "$.user", "date": "$.time", "likes": "$.likes" }
  }
}
```

| 區塊 | 必填 | 作用 |
|------|------|------|
| `chapters` | ✓ | 這本書在對方網站的章節表（`id`＋`title`），用來把讀者手上的章對到對方的章。快取一天以上。 |
| `chapter` | 二選一 | **本章說**：整章的評論清單，可分頁、可選排序（熱評就是 `sort=hot`）。 |
| `counts`＋`paragraph` | 二選一 | **段評**：`counts` 回這一章每一段有幾則，`paragraph` 回某一段的內容。兩個要一起給。 |

規則：

- `counts.list` 至少要有 `quote`（那一段的原文，或開頭一截）或 `index`（第幾段）其中一個；兩個都給最好。
- 評論一則的欄位（`text`／`author`／`date`／`likes`）和 `reviews.list` 完全相同，共用同一個解析與長度上限。
- 所有請求只能連到模組宣告的 `hosts`，`{{chapterId}}`／`{{paragraphId}}` 只來自模組自己上一段回的值——跟彈幕鏈一樣，上一段吐出什麼 id，下一段就收到什麼 id。
- 驗證器（`RuleModuleValidator`）：`requiredVersion` ≥ 3.0.3；必須有 `search` 或 `lookup`；`chapter` 與 `counts+paragraph` 至少一組；用了 JS 而沒宣告 `javascript` 照舊拒絕。
- 模組 `description` 必須寫明：打開本章說時會把**書名、作者（或 ISBN）**送到它的網站。章名只在本機比對，不送出。

### 3.1 JavaScript

**為什麼需要**：評論接口幾乎都要簽名（時間戳＋雜湊）、帶裝置參數，或回傳加密／壓縮過的內容。純宣告式規則做不到，等於這個功能只對極少數網站有用。來源配置能接這些網站靠的就是 JS。

**現況**：模組完全不碰 JS。驗證器看到 `@js:`、`<js>`、`{{ }}` 裡的 JS 就拒絕（`RuleModuleValidator.swift:563`），模組用的是沒有 JS 求值器的規則引擎（`RuleModuleClient.swift:143`）。這是當初刻意的：匯入畫面能保證「這個模組只會連到列出來的網站」。

**定案（維護者 2026-11-15，用選項選的）**：受限 JS、開給整個格式。實作在 `RuleModuleScriptRuntime`。

- 模組頂層 `"javascript": true` 才允許規則裡的 `@js:`／`<js>` 和 `request` 的 `script`（送出前改網址、標頭、內文，用來簽名）。
- **不用來源配置的 JS 引擎。** 查過它有九個以上的連網出口（含原始 socket、隱藏 WebView），還讀得到 cookie 和裝置識別碼，`hosts` 保證守不住。模組用的是一個空的 `JSContext`，只掛 `java` 這個物件，裡面全是純運算函式（雜湊、HMAC、Base64、AES／DES），名稱照來源配置的取，腳本小改就能搬。
- 腳本不能連線：所有請求仍由 `RuleModuleClient.send` 送出並檢查 `hosts`，`script` 改出來的網址連到別的主機就直接失敗。
- 每個模組版本一個重用的環境。一段腳本最多 2 秒；跑不完的腳本停不下來（JavaScriptCore 沒有公開的中止方法），那個模組的腳本整個關掉到 App 重啟，最多留下一條空轉的執行緒。
- 匯入預覽多一行「這個模組會執行 JavaScript」。沒宣告的模組行為完全不變。
- 欄位算在格式 3.0.2（App 目前就是 3.0.2，這一版格式還沒發佈），不另開 3.0.3。

## 4. 對位（等於字幕對時間軸，最難的一段）

對不上就**不顯示**，不猜。這不是替自己的 bug 加兜底：兩邊版本不同是外部事實，寧可沒有也不能把評論掛錯段。

### 4.1 對章

1. 兩邊章名都過 `WorkMatchKey` 摺疊（繁簡、全半形、標點、空白），再把「第十二章／第12章／Chapter 12／012」正規成同一種章號＋章名。
2. 章名（不含章號）相同且唯一 → 對上。
3. 章名對不上、但章號相同且兩邊章號都沒有重複 → 對上。
4. 其餘 → 這一章沒有評論。不用「第幾個」的位置去猜（分卷、番外、作者感言會讓位置整個錯開）。

結果（讀者的章 → 對方的 `chapterId`）跟著章節表一起快取。

### 4.2 對段

- **模組有給 `quote`**：把讀者這一章的每一段摺疊後，找開頭相同的那一段（`quote` 可能只是前 20 字）。唯一命中才掛氣泡；命中兩段以上（重複的短句，如「……」）不掛。這條最可靠，TXT 分段跟網站不同也沒關係。
- **只有 `index`**：只有當讀者這一章的段數跟對方回的段數**完全相同**時才照序號掛；不同就只顯示本章說，不顯示段評氣泡。
- 段評掛不上不影響本章說：本章說只需要對到章。
- **章名的段評**（2026-11-17，維護者指出模組少了標題氣泡）：起點、QQ閱讀把章名當成一段算段評（段落代號 −1／0；书山聚合的 `ruleContent.title` 把這一段的氣泡接在章名後面，數字是章名這一段自己的則數，不是本章說總數）。`counts`／`hot` 的 `list` 多一條 `title` 規則，讀到 true（`LegadoTruth`）的那一項不看 `quote`／`index`，掛在讀者這一章章名的最後一行（`ChapterParagraphMatch.titleEnd`），點開 `paragraph`；正文不是從章名開始就不掛。
- **熱門分色、語音、數字上限**（2026-11-17，維護者：分色只看模組標的熱門）：`counts.list` 多 `hot`、`voice` 兩條規則，讀成 `CommentBubbleTraits` 跟著氣泡走（CoreText 的 `RenderableNode.commentBadge`、瀏覽器引擎的圖片名 `bubble/<則數>/<traits>`）。熱門＝樣式的強調色槽（空著就是 `DSUIColor.commentBubbleHot`；內建兩款整個換色），**不再**用「99+／≥100」判斷強調。語音＝樣式的 `voiceSVG`，沒有就在原樣式數字下面加五條聲波（`CommentBubbleSVG.addingVoiceWave`）。數字上限 99／999 是閱讀設定（`commentBubbleMaxCount`，跟主題同步），只管 App 自己畫的數字：來源配置自帶的 SVG 在「跟隨來源」模式照原樣畫，它烤進去的 `99+` 不受影響；來源配置不會給熱門或語音，所以它的氣泡沒有強調色。
- **寫的人、樓中樓、接手來源配置的評論頁**（2026-11-17，維護者：做適配層讓 App 接過渲染，總開關、樓中樓顯示前幾則＋點開看全部）：`WorkReview` 多 `id`／`avatar`／`badge`／`floor`／`replies`（一層、最多 20）／`replyCount`，全部 Optional，舊快取照樣解碼；`ReviewRules` 同名規則，`replies` 在評論的範圍裡讀。`comments.replies` 用 `{{commentId}}` 拿全部回覆，推進同一個 `ChapterCommentsModel`（`parent`）。`comments.sourcePages` 用主機＋路徑正規式＋查詢參數認來源配置的評論頁，只取 `id`／`chapterId`／`paragraphId` 三個值（來源網址常帶 token，其餘一律不讀、不記 log），接手判斷在 `ReaderReviewSheetContent`，由 `GlobalSettings.commentsUseAppList`（預設關、不進主題）決定；開著時一律在 App 列表顯示（2026-11-24 維護者：開啟時強制渲染），沒模組認得也不開來源網頁，顯示 `UnreadableSourceCommentsSheet`（沒有模組能讀這個評論頁），要看網頁得關掉開關；關著時照舊開來源網頁；沒有 Pro 時開關當作關（開關在 Pro 的氣泡設定裡，到期的人摸不到，不能被它鎖住；存的值不動），接手後請求失敗顯示列表自己的失敗狀態，不退回網頁。限制：來源 JS 直接給 HTML、不給網址的評論頁（`sourceBrowserPage.html`）認不出來；瀏覽器排版引擎點 JS 型氣泡時本來就不先跑來源 JS，網址是空的，也不會接手。

## 5. App 端架構

一條路，照現有分層（view 只叫一個 use case）：

```
ChapterCommentService（Services，擁有快取／去重／對位／降級）
  ├─ 找書：沿用 ModuleReviewProvider.records(for:)，不複製
  ├─ 找章：RuleModuleClient+Comments（新）讀 chapters → ChapterMatch
  ├─ 段數：counts → [段落錨點: 則數]
  └─ 內容：paragraph／chapter → [WorkReview]（沿用現有模型）
```

- **模型**：新增 `ChapterCommentCounts`（章 → 每段則數＋整章則數）。評論內容直接用現有 `WorkReview`，不另造。
- **模組選擇**：沿用「資料來源」清單的順序與勾選（跟 `reviews` 同一份），第一個對得上這本書**而且**對得上這一章的模組回答。
- **來源自帶段評優先**：這一章的正文已經有來源自己的 `ydreview://` 標記時，不問模組——同一段不會出現兩顆氣泡。
- **畫氣泡**：在段尾放一個新種類的 `ydreview://` 錨點（payload 是 模組 id＋紀錄＋`chapterId`＋`paragraphId`），之後完全走現有的氣泡渲染與「氣泡設定」，不寫第二個繪製實作。
- **點氣泡**：`ReviewTarget` 加一個模組種類，開**原生評論清單**（沿用作品詳情「讀者評論」頁的列），不是 WebView。
- **本章說入口**：章末一張卡片（沿用評論卡片模板，kind＝本章說）＋閱讀選單裡一項「本章說」。
- **時機**：讀到某一章時在背景抓這一章**和下一章**的則數（讀者往後翻時已在快取裡）。抓不到、對不上都安靜略過並記 log（`AppLogger.network`），不擋正文。用 `SourcePerfTrace` 記 `comments.chapters`／`comments.counts` 兩個 span。
- **開關**：全域一個（預設開，沒裝有 `comments` 的模組就什麼都不發生）＋每本書可關。

## 6. 風險與待驗證

1. **氣泡不能動到閱讀位置（必須先做技術驗證）。** 位置是章內字元偏移；如果注入的氣泡在原文佔字元，開／關評論、或評論晚一步到，書籤、高亮、進度都會偏掉。兩個做法：
   - (A) 引擎（YueduCoreText）支援「不佔原文長度」的行內裝飾，氣泡用它畫。乾淨，但要動套件。
   - (B) App 端在存取位置時換算掉注入的字元。等於多一層座標轉換，容易漏路徑。
   建議 (A)。動工前先花半天確認引擎現在的附件能不能宣告零原文長度；不行就要先排套件工作。**在這點確認前，段評氣泡不排期。**
2. **本機書的注入點還沒逐一確認。** TXT、EPUB、線上三條內容路徑各自在哪裡組段落，注入要放在三者共用的一層；動工第一步是把這三條路徑列出來。
3. **TXT 沒有作者**時現有規則不搜書名。本章說對書的要求可以比書評寬一點：章節表對得上的比例夠高（例如八成章名相同）本身就是「同一本書」的證據。要不要這樣放寬，見 §8。
4. **評論晚到要重排一章。** 讀者正在看的那一章第一次拿到則數時要重排一次；做法 (A) 下位置不變，只是氣泡出現。要量重排耗時（先前量過：氣泡開啟時冷載明顯變慢，見 `ReaderCommentPerformance-20260907.md`，但那主要是來源 JS 的網路時間）。
5. **隱私**：P1 只在讀者點「本章說」時才問模組，送出的是書名、作者或 ISBN；章名不送。P2 若改成讀到就自動抓則數，要另外給開關。

## 7. 分期

| 期 | 內容 | 風險 | 依賴 |
|----|------|------|------|
| P0 | 補書評的缺口：**合併多個模組的結果**（現在只取第一個有結果的）、TXT 無作者時的處理。 | 低 | 無 |
| P0.5 | **模組可以跑 JS**（§3.1）：`javascript` 旗標、重用 bridge、JS 請求受 `hosts` 限制、匯入預覽揭露。 | 中 | 無 |
| P1 | **本章說**：格式的 `chapters`＋`chapter`、對章、章末卡片＋選單入口、原生清單、熱評排序。不碰正文排版。 | 中 | P0.5（要簽名的網站才需要） |
| P2 | **段評氣泡（`quote` 對位）**：`counts`＋`paragraph`、段尾氣泡。 | 高 | §6-1 的技術驗證 |
| P3 | 只有 `index` 的段評。 | 低 | P2 |

P1 單獨上線就有用（TXT 也能看本章說），而且完全避開 §6-1。

## 8. 要維護者決定的事

1. 先做哪一期（建議 P1 本章說，P0 可以併在前面）。
2. TXT 沒有作者時，要不要用「章節表對得上」當作同一本書的證據（建議要，門檻八成）。
3. 段評氣泡的技術驗證 (§6-1) 要不要現在就排。
4. JS 開給整個模組格式，還是只開給 `comments`（建議整個格式，§3.1）。
5. 這個功能本身免費還是 Pro（建議免費：模組新增已經是 Pro，功能再鎖一次等於收兩次）。

## 9. 驗收（每一期都要）

- 模組格式：`ModuleFormatDocumentationTests` 涵蓋新欄位；`docs/modules/README.md` 新增一節。
- 對位：同名不同章號、重複章名、番外插入、TXT 分段不同、`quote` 命中兩段——全部斷言「不顯示」，正確的才顯示。
- JS：沒宣告 `javascript` 的模組用了 JS → 匯入被拒；宣告了的模組在 JS 裡連 `hosts` 以外的主機 → 請求失敗、沒有任何封包送出；同一個模組連續呼叫只建一個 bridge。
- 請求：斷言送出去的 `chapterId`／`paragraphId` 就是上一段回來的值（不是只看回傳）。
- 來源自帶段評的章不問模組。
- 位置：開／關評論前後，同一個書籤落在同一個字（P2）。
- VoiceOver：氣泡讀「段評，N 則」，章末卡片與清單每一列都有標籤。

- **評論列表樣式進主題包、補欄位**（2026-11-17，維護者：「進主題包」；參考 yuedu2.0 分支的原生評論面板）：`WorkReview` 多 `quote`（段落原文引用）、`meta`（網站自己寫的時間·IP 屬地，取代日期）、`images`、`voice`、`isAuthor`，`ReviewRules`／`ReplyRules` 同名規則，`webURL` 一條路讀頭像、配圖、語音網址。列表的樣子是 `CommentListStyle`：滑桿與開關（卡片濃度、圓角、頭像、三種字級、行距、哪些部分顯示、樓中樓則數）＋孤島（Cay）方言的樣式表（頂層＝卡片，`.user`／`.text`／`.time`／`.quote`／`.label`／`.avatar`／`.floor`／`.reply`，`@dark`／`@light`）。優先順序：滑桿 > 樣式表 > App 預設，全在 `CommentListLook.resolved` 一處決定；樣式表只在設定時讀一次（`GlobalSettings.commentListSheet`）。它掛在 `AppearanceThemeReadingSettings.CommentBubble.list`，所以同步、主題包、匯入都走段評氣泡那一列；主題包的值穿上前先 `sanitized`。**不做**分支那套把 CSS 套到來源網頁的作法：它靠猜 DOM 結構加 `setTimeout`／MutationObserver 補標記，網站的標記不是我們的，猜錯就套錯；樣式表只作用在 App 的列表，讀不懂的寫法列在「未套用」並原樣留在主題包裡。
