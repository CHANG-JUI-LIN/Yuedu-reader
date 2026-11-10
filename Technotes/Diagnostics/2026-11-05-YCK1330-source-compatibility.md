# YCK 1330 書源模擬器實測與 Legado 相容性報告

測試日期：2026-11-05～2026-11-06（Asia/Taipei）。Run ID：`YCK1330-20261105-f821dc9a`。

## 結果

**794 個書源已透過 App 的正式 UI 匯入，資料檔逐一比對也確認 794／794 全數存在。整批校驗有 791 個自然結束：227 個通過目前檢查、564 個未通過；另 3 個卡在使用者互動等待。** 後三個已另外以明確取消回覆重測，沒有將重測結果混入原始通過數。

不能把這次稱為「794 個全數正常完成自動校驗」：原始整批執行因三個等待無法收尾而手動停止，runner 最終回報 TEST FAILED。這個阻塞本身也是本次確認的驗證器問題。後續兩個直接相關診斷測試均已通過。

已確認的核心問題是 Java／HTTP／DOM 物件契約不完整、HTML 元素上下文遺失、URL 處理順序及搜尋詳情頁分支缺漏；不是僅靠補幾條 CSS 規則能解決。未通過項目仍有需逐源定因者，沒有把它們全部歸因於網站失效。

- [完整 794 筆 CSV](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/results.csv)：每源網址、媒體型別、五階段結果、錯誤、證據分類。
- [完整 JSON 與三源重測結果](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/results-with-js.json)、[原始整批檢查點](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/full-live-report.json)。
- [匯入成功截圖](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/import-success.png)、[資料檔比對](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/import-evidence.json)。
- [錯誤與進度索引](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/runtime-evidence.txt)、[完整原始日誌 gzip](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/audit.log.gz)。

| 書源宣告型別 | 總數 | 通過目前檢查 | 未通過 | 互動阻塞 |
| --- | ---: | ---: | ---: | ---: |
| 文字 | 691 | 177 | 511 | 3 |
| 音訊 | 13 | 5 | 8 | 0 |
| 漫畫／圖片 | 70 | 35 | 35 | 0 |
| 檔案 | 7 | 3 | 4 | 0 |
| 影片 | 13 | 7 | 6 | 0 |

型別依原始 JSON，沒有擅自更改。例如「茶杯狐狸」實際是影片操作，但原源宣告為文字。檔案源按既有校驗流程不檢查目錄／正文；音訊、圖片與影片通過此探測，也不代表已驗證全部播放、圖片解碼、下載或所有章節。

227 個通過項目中，仍有 15 個記錄到可唯一歸源的 JS 錯誤。部分可能是封面等非必要欄位或其他分支，不能直接說它們完全不可用；這也說明抽樣校驗通過不等於該源所有功能皆相容。

## 測試條件與對照版本

- 原始資料：[使用者提供的 JSON](https://www.yckceo.com/yuedu/shuyuans/json/id/1330.json)，7,857,616 bytes，794 個不同 source URL，全部 enabled。
- 凍結材料：[source-pack.json](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/source-pack.json)，SHA-256 `ce7782fcbafa82bc9f0df02e19257024812784a8db295745e0c03078c03b1f4c`。
- iPhone 18 Pro Max 模擬器，iOS 27.2；UDID `3CE40849-64C1-4E24-8B59-DB772C2C3D2D`；Xcode 27.2 (27B52)。未操作實體 iPhone。
- 使用正式 `BookSourceHealthChecker` → `BookSourceFetcher`／`BookSourceSession`，搜尋與發現各自接詳情、目錄、首章。預設關鍵字「我的」，源有 checkKeyWord 時依現有實作覆寫；每源設定 180 秒；僅標記，不停用、不刪源。
- 主工作區的另一批 TTS 修改當時無法編譯，因此用 `f821dc9a7f35b375ea043c07fd1b95e15465e267` 的隔離目錄建置。本次比對書源、規則引擎、網路相關 82 個 Swift 檔案，與主工作區完全一致，見 [比對證據](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/source-equivalence.json)。未修補或撤回 TTS 修改。
- Android 對照使用你本機的三份原始碼；本次 runtime 實測平台是 iOS 模擬器。

| 本機版本 | Git revision |
| --- | --- |
| [legado-upstream](/Users/zhangruilin/Desktop/Yuedu-reader/legado-upstream) | `4f0ad90729f841ead8385b2bb3ba28f3c8620beb` |
| [legado-E](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E) | `8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c` |
| [legado-md3](/Users/zhangruilin/Desktop/Yuedu-reader/legado-md3) | `611706a5d332deb20b291daef73783b73033ca01` |

三份參考目錄的未追蹤檔僅為索引標記／README 複本，本次沒有更改它們。上述 hash 是本機版本，未以網路上後來變動的版本取代。

## 失敗分布

以下是目前驗證器的第一個分類，屬於畫面判定，**不是已證實的根因分類**：

| 分類 | 數量 |
| --- | ---: |
| 網站／傳輸等例外 (`siteError`) | 255 |
| 搜尋無有效結果 (`searchFailed`) | 253 |
| 發現無有效結果 (`discoveryFailed`) | 12 |
| 目錄為空 (`tocEmpty`) | 33 |
| 檢查規則缺失 (`ruleMissing`) | 3 |
| 正文為空／檢查拒絕 (`contentEmpty`) | 7 |
| 明確傳回的 JS 例外 (`jsError`) | 1 |

五階段失敗次數為：搜尋 449、發現 94、詳情 23、目錄 63、正文 63；同一源可以有多個失敗階段，不能相加當成書源數。

564 個未通過項目中，保守地按可唯一歸源的紀錄計，有 81 個伴隨 JS 例外；13 個實際呼叫了未提供的 Java API，另有 69 個留下 HTTP 拒絕、153 個逾時、12 個 TLS 信任失敗的證據。這些集合重疊，且後三種觀測本身不能證明 Android 也失敗。

有 249 個未通過項目尚無足夠明確的底層分類證據；其餘有錯誤紀錄者也可能同時有多個問題。CSV 的 `evidenceFlags`／`jsEvidenceMatch` 保留證據界線。整包有 38 組同名書源，未將只有名字的 log 任意套到另一個 URL；因此 JS 計數是保守值。

## 真實回應的離線重放

以下由模擬器內的正式解析管線重放補抓回應，不再連網；補抓回應與整批原始回應不是同一份，所以成功重放不能倒推原始失敗原因。

| 源 | HTTP 回應材料 | 正式搜尋解析 | 直接證據 |
| --- | --- | ---: | --- |
| 全本小說網 (`www.qbxs.net`) | 41,945 bytes，100 列有 td 的書目 | 0 本 | 第一列原有 6 個 td，序列化後獨立重解析只剩 0 個 td |
| 恩京書房 | 34,411 bytes，搜尋頁 | 13 本 | 這份回應可正常解析；整批失敗仍待對照原始請求／回應，未硬判解析器壞掉 |
| 半夏小說 | 69,948 bytes，搜尋直接回傳詳情頁 | 0 本 | 同一 HTML 走詳情規則可取出書名「偉大航路賣八卦的人生」 |

全本案例的根因鏈是列表元素轉 outerHtml 字串 → 欄位再次透過 `JsoupDocumentCache` 的 `SwiftSoup.parse` 建成獨立 Document → tr／td 的表格上下文消失 → `tag.td.0@text` 空值 → 所有書目被丟棄。Legado 保留原 Element，因此這裡須修中間值與解析上下文，不能換搜尋字來避開。

黃果短劇的原始搜尋 URL 另以不連網的 evaluator 探針檢查：只有 `encodeURIComponent(key)` 送進 evaluator，前面的 IIFE 未執行；中間結果已將 `now-ts<180000` 破壞成 `now-ts180000`、`k<res.length` 破壞成 `kres.length`，確認頁碼掃描在 JS 執行前就改壞程式。

[離線結果 JSON](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/captured-responses.json)、[離線完整診斷 log](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/captured-responses.log.gz)。

## 已確認的相容性差異

下列結論來自本次模擬器錯誤紀錄，加上本機三份 Legado 原始碼對照。它們能證明相容性有缺口，不能直接推算「補完後一定全部通過」；同一書源可能同時遇到橋接問題與網站限制。

### 1. Java／Android API 與 `Packages` 命名空間不完整

番茄漫畫、番茄聽書、番茄短劇、七貓 API 的實測紀錄出現 `UnsupportedLegadoAPIError`，包含 `java.security.MessageDigest.getInstance`、`java.nio.charset.Charset.forName`。另有書源用到 `Thread.sleep`、`android.text.TextUtils.isEmpty`、`io.legado.app.help.http.StrResponse` 等未提供的介面。

我們的 [LegadoRuntimeCapabilityRegistry.swift](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/LegadoRuntimeCapabilityRegistry.swift:15) 明確列舉允許的能力；[LegadoJavaInteropRuntime.swift](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/LegadoJavaInteropRuntime.swift:343) 對未提供的呼叫拋錯。這是實際缺少介面，不能用「已支援 Java 加密」概括成相容。

另外，`org.jsoup.Jsoup.parse(...)` 已有橋接，但 `Packages.org.jsoup.Jsoup.parse(...)` 沒有接到同一個物件。桔紙書屋、台灣小說網的紀錄直接顯示後者遭拒。對照 [JSCoreEngine.swift](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift:1378)，`Packages` 由註冊表建立，`org` 則另行建立，兩個入口未共用完整能力。

Legado-E／MD3 的 Android 規則透過 Rhino 呼叫 JVM 物件；官方本機版本已重構為共用核心與平台橋接，不能把三個版本當成完全相同的實作。本次核對它們共同提供的公開規則介面，並保留版本差異。

**修正方向：** 按真實書源的已執行呼叫補足能力，統一 `org`／`Packages.org` 的入口；每個 API 要連同參數、回傳型別及錯誤行為測試，不能只讓名稱存在。

### 2. `java.getElement` 缺失，DOM 物件也會失去方法

實測八叉書庫出現 `java.getElement is not a function`。整包有 11 個書源包含這個呼叫，這是靜態使用數；並非 11 個都已走到相同失敗分支。

三份本機版本均提供 `getElement`：

- [Legado-E AnalyzeRule.kt](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt:376)
- [MD3 AnalyzeRule.kt](/Users/zhangruilin/Desktop/Yuedu-reader/legado-md3/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt:371)
- [官方共用 AnalyzeRuleCore.kt](/Users/zhangruilin/Desktop/Yuedu-reader/legado-upstream/shared/src/commonMain/kotlin/io/legado/app/model/analyzeRule/AnalyzeRuleCore.kt:380)

我們的 [LegadoJSBridgeExport](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift:185) 只有 `getElements`。兩者不是單純的拼字別名：Legado 的 `getElement` 可以回傳保留方法的 Elements／JSON 物件，不能一律改成字串陣列。

另外，頂點小說、包子漫畫等紀錄出現 `result[i].attr`、`x.attr`、`lis[i].select` 等方法不存在。JSoup 的 `Elements` 建構子、`selectFirst` 等介面也有缺漏。

[JSCoreEngine.extractString](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift:1861) 把一般 JS 物件轉成 JSON 字串；[ModernRuleEngine.rehydrateJSListResult](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/ModernRuleEngine.swift:603) 再把每個物件轉回 JSON／HTML 字串。下個欄位收到的已不一定是原本有 `.select()`／`.attr()` 的元素。Legado-E 的 [evalJS](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt:828) 則直接回傳腳本物件。

**修正方向：** 在現有規則管線保留中間值的型別與元素身分，補齊所需 DOM 介面；不能只補一個方法名稱，或在每個失敗書源旁加獨立解析器。

### 3. HTTP 回應物件的契約不同

八叉書庫、八一中文等出現 `.raw is not a function`；哔哩輕小說、天悅小說出現 `.header is not a function`。

Legado-E 的 [StrResponse.kt](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/help/http/StrResponse.kt:15) 提供 `raw()`、`callTime()`。它的 [java.get／post](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/help/JsExtensions.kt:483) 回傳的是 JSoup `Connection.Response`，可呼叫 `header(name)` 等方法；`get` 在該版本也明確不自動跟隨重新導向。

我們目前將這些呼叫統一為 [LegadoStrResponse](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift:2528)，有 `headers()`、`code()`，但缺少上述介面；HTTP 呼叫使用 URLSession，重新導向語意也需要逐項對齊。

**修正方向：** 依各 API 的回傳契約提供物件，保留原始狀態、標頭、最終網址及呼叫時間；避免把不同回應型別縮成同一個不完整的 wrapper。

### 4. URL 內嵌 JS 與頁碼規則的處理順序顛倒

黃果短劇的搜尋 URL 含 `{{(function(){ ... })()}}`，其中有 `<`／`>` 比較與逗號；本次在 URL 建構階段失敗。

我們的 [AnalyzeUrl.replaceKeyPageJs](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/URL/AnalyzeUrl.swift:252) 先用 `<(.*?)>` 處理頁碼，再處理 `{{…}}`。Legado-E 的 [同名方法](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt:190) 順序相反，原始碼也明確解釋要避免把 JS 的大小比較誤切。MD3 與官方共用核心另可依本機版本核對。

本次另以原始 URL、替代 JS evaluator 做不連網的診斷，輸出實際傳入 evaluator 的片段，避免將遠端線路狀態混進這項判斷。結果見離線重放段落。

**修正方向：** 對齊內嵌規則與頁碼規則的順序和掃描語意；用這份真實 URL 作回歸材料。

### 5. 搜尋回傳詳情頁的分支缺失

半夏小說本次搜尋失敗，但同一源的發現 → 詳情 → 目錄 → 正文成功，正文樣本為 3,375 字。補抓其設定關鍵字的搜尋回應時，得到的是書籍詳情 HTML，而非搜尋清單。

Legado-E／MD3 的 [BookList.analyzeBookList](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/model/webBook/BookList.kt:62) 會依 `bookUrlPattern` 判定詳情頁，也處理未設定 pattern、清單為空時按詳情頁解析的情形，並保留 `infoHtml`。我們的 [parseSearchResults](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift:1038) 只套搜尋清單規則；原生搜尋路徑另將原始請求網址傳入解析，沒有攜帶完整重新導向資訊。

**修正方向：** 在既有搜尋管線接上 Legado 的詳情頁辨識契約，保留回應最終網址與已取得的詳情 HTML。這是明確的來源回應型態，不應靠換關鍵字或重試掩蓋。

### 6. `checkKeyWord` 在校驗與搜尋過濾中的語意不同

本包有 199 個源設定 `ruleSearch.checkKeyWord`，其中 10 個包含 URL 或 `++`／`--` 等除錯輸入。

本機 Legado-E／MD3 的 `getCheckKeyword` 會排除這類除錯輸入、改用預設校驗關鍵字；本機官方共用版本則直接接受非空值。這項確實存在版本差異。

我們的 [HealthChecker](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceHealthChecker.swift:779) 直接採用非空 `checkKeyWord`，而 [filterSearchResultsByCheckKeyWord](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceFetcher+Search.swift:334) 又因該欄位存在，強制要求結果名稱／作者包含查詢字串。對 URL 型輸入而言，這種過濾可能清掉已解析結果。Legado 的校驗用關鍵字與呼叫者指定的搜尋 filter 是不同用途。

**證據界線：** 這是確認的程式行為差異；10 個源中有些更早就被橋接或 URL 錯誤擋住，不能說本次這 10 個都只因這項過濾而失敗，也不能把 199 當成實際受害數。

### 7. 校驗的錯誤分類會掩蓋底層原因

番茄聽書／漫畫在底層已拋出未支援 API 錯誤，驗證摘要卻可能是 `searchFailed` 或 `tocEmpty`。原因是 JS 執行層以 nil／空結果回傳，上層把它當成「沒有書／沒有章節」。

[JSCoreEngine](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift:955) 有記錄 `lastError` 與錯誤 log，但一般搜尋解析不會將這類錯誤一路作為結構化失敗傳到 [probeSearch](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceHealthChecker.swift:982)。部分原生 HTTP 錯誤即使在 `.propagateTransportError` 模式下也轉成空結果，見 [disposition](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceFetcher+Search.swift:46)。

**修正方向：** 保留 transport／JS／解析失敗與合法空結果的差別，讓來源驗證直接顯示根因；不能只調整顯示名稱。

## 驗證器額外缺陷：180 秒超時無法結束等待使用者的規則

茶杯狐狸的搜尋／發現兩條路徑會重複驗證正文。該源正文規則先寫入 cache，之後呼叫 `java.startBrowserAwait` 等待瀏覽器回傳。此次第一個正文網路回應於 23:35:18 完成，超過十分鐘後該源仍停在 content，儘管校驗設定為單源 180 秒。

根因鏈：

1. [LegadoJSBridge.waitForUser](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift:439) 使用無期限 semaphore 等待 UI completion。
2. [JSCoreEngine.onJSQueueWithTimeout](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift:455) 刻意在等待使用者期間不套用 JS runaway timeout；互動閱讀需要這個語意。
3. [HealthChecker.withTimeout](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceHealthChecker.swift:706) 雖用 task group 與 timeout 競速，但離開 group 前仍須等未結束的工作；取消沒有連動到這個 UI wait。

因此問題不是應刪除 `startBrowserAwait`，而是背景來源驗證需要自己的「需要使用者介入」結果與可取消生命週期。此次也觀察到網站開啟媒體覆蓋層後，第一次點瀏覽器取消沒有讓等待結束；保留 UI 階層與時間證據，未將該來源視為一般網路逾時。


## TLS、網站回應與未完成的定因

本次確實有憑證驗證失敗、DNS 失敗、逾時以及 HTTP 403／404／429／5xx。這些是本次 iOS 端觀測到的結果，並不等於「源在 Android 也壞了」。

例如 Legado-E 的 [HttpHelper.kt](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/help/http/HttpHelper.kt:64) 明確使用寬鬆的 TLS 信任及 hostname verifier，而我們的 URLSession 走系統信任。因此憑證錯誤也是可解釋的平台行為差異，不能全部歸給網站失效。本次沒有為追求通過率而修改信任設定。

帳號、Cookie、人機驗證、來源自訂變數、IP／區域及網站當時回應也可能影響結果。本次沒有憑空建立登入憑證，亦未將需要登入的失敗等同於規則引擎缺漏。

逐源表將保留「未能定因」的項目；HTTP 200 但沒有結果，仍須對照實際回應與各條規則。沒有足夠證據的項目，未任意標成網站失效或已確認相容性 bug。

## 建議修復次序

1. 先修可重現且跨源共用的契約：`getElement`、DOM 中間值、`Packages` 能力及 HTTP 回應型別。
2. 修正 URL 內嵌規則順序、搜尋詳情頁辨識，再對照各版本處理 `checkKeyWord`。
3. 讓驗證完整傳遞失敗種類，再處理剩餘來源的請求差異、登入與 TLS 個案。

每一類以本次原始規則與已保存回應先建立會失敗的回歸，再修現有共用管線。本次任務是驗證與報告，尚未修改正式相容性實作，也沒有加入重試或其他替代抓取路徑。


## 三個互動阻塞項目的重測與收尾

整批最後只剩茶杯狐狸、黑粉小說、高腐屋，三者都在等待瀏覽器或驗證碼回覆。保留當時階段、UI 階層及等待堆疊後停止整批，沒有把未結束項目補成通過／一般網站失效。

測試入口新增可選的 `cancelInteractiveRequests`，只在這三個源的後續診斷啟用，遇到請求即記錄並回覆取消，正式 App 行為未修改：

| 源 | 明確取消後的結果 | 解讀 |
| --- | --- | --- |
| 茶杯狐狸 | checker 報通過，兩條路徑各抓取 7 字 | 規則回傳「请刷新查看内容」提示，並非已取得／播放影片；未提升原始 227 通過數 |
| 黑粉小說 | 請求圖形驗證碼，取消後目錄失敗 | 記為需要互動，另保留底層錯誤；未視為網站必然失效 |
| 高腐屋 | 請求圖形驗證碼，取消後目錄失敗 | 同上 |

[三源重測結果](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/interactive-followup.json)、[重測 log](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/interactive-followup.log.gz)、[等待時間證據](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105/browser-wait-evidence.json)。一般 UI 的取消／Escape／向下關閉手勢未解開最初等待；偵錯器移除視窗後仍有三個 waitForUser 堆疊，最後停止測試 host。未以這些人工處置聲稱正常取消已修好。

## 本次修改與執行證據

只修改診斷測試與報告，未改正式書源相容性程式：

- [BookSourceCompatibilityAuditTests.swift](</Users/zhangruilin/Desktop/Yuedu-reader/Tests/iOS/yuedu appTests/BookSourceCompatibilityAuditTests.swift>)：允許明確測全部媒體型別、寫入逐源檢查點、可選的互動取消診斷，原有預設仍只測文字源。
- [CapturedBookSourceResponseAuditTests.swift](</Users/zhangruilin/Desktop/Yuedu-reader/Tests/iOS/yuedu appTests/CapturedBookSourceResponseAuditTests.swift>)：真實回應重放、表格元素前後比對、URL 規則掃描診斷。
- `scripts/xctest.sh`：後續三源稽核 **1 test passed / TEST SUCCEEDED**；最後版離線重放 **1 test passed / TEST SUCCEEDED**。每次均 `-parallel-testing-enabled NO`，個別測試類別執行；兩次均有實際測試與編譯證據，沒有另跑 clean。
- 原始全批因互動阻塞手動停止，**TEST FAILED**，已與後續診斷通過分開記錄。這份報告不是相容性修復完成聲明。

重現材料集中在 [證據資料夾](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261105)，包含凍結書源、三份 HTML、原始／後續設定 JSON、完整結果與日誌。重新執行時，將所選設定複製至 `/tmp/yuedu-source-audit.json` 或 `/tmp/yuedu-source-response-audit.json`，再用 `scripts/xctest.sh` 選對應類別。原始全批設定保留了會等待使用者的真實行為；無人值守診斷應明確選用互動取消模式，並另外呈現需要介入的源。
