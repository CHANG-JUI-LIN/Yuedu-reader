# YCK1330 新版主要相容性缺口

日期：2026-11-06。檢查的是 `/Users/zhangruilin/Desktop/Yuedu-reader` 當時的未提交修改碼；舊報告的 227 不是新版實測結果，也不是 iOS 可支援源數的上限。

## 結論

目前最優先的是共用的請求編碼、URL 模板空值和 WebView 路由，三群規則候選去重後 192 源。這是需要核對的範圍，不能相加，也不能直接當作修完必定新增的可用數。另找到普通 CSS 被錯誤交給文字 fallback 的入口，會讓已修好的表格節點保留失去作用。這些都是引擎可補齊的差異，沒有證據把約 300 源當成平台上限。

## 新版整批實測

- 同一凍結包 794 源全部完成自動驗證；全項通過 **276**，未全項通過 **518**。
- 比舊版有 57 個原先已完成但失敗的源改為通過，11 個原先通過的源這次未通過。這是跨次實測差異，包含網站/網路波動，不能全歸功或全歸咎於程式修改。另外 3 個舊版未完成的源，本次也得到檢查器通過，其中茶杯狐狸仍是假通過提示，已下列註明。
- 有 89 個未全項通過的源，至少有一條搜尋或發現路徑回報抓到內容。這表示全項通過數不能直接當成能閱讀的源數；也不能僅憑抓到非空文字便宣稱整本可讀。
- 9 次瀏覽器/驗證碼要求由無人值守測試回呼取消。需要使用者介入的行為，這次沒有完成登入或人工驗證。
- 檢查器通過但文字型別內容少於 100 字的源索引：205, 211, 258, 359, 401, 577, 791。其中 211 茶杯狐狸先前已確認回報的是「请刷新查看内容」提示，不能當成影片播放成功。其他短內容仍需個別確認，沒有僅依長度判死刑。

| 包內型別 | 源數 | 全項通過 |
|---|---:|---:|
| 文字（依包內宣告，部分實為影片） | 691 | 221 |
| 音訊 | 13 | 6 |
| 圖片 | 70 | 37 |
| 檔案 | 7 | 4 |
| 影片 | 13 | 8 |

## 1. GBK/GB2312 搜尋參數仍用 UTF-8：最高優先

`AnalyzeUrl.encodeParams` / `encodeComponent` 沒有使用已讀取的 `charset`，POST 表單也固定走 UTF-8。Legado-E 的 `encodeParams(params, charset, isQuery)` 會按照該字集編碼。`我的` 應為 `%CE%D2%B5%C4`，目前送成 `%E6%88%91%E7%9A%84`。

指定 GBK/GB2312 搜尋 charset 的 117 源中，113 源直接包含 `{{key}}`；另有寫死中文字或 JS 產生 body 的源，須分別核對。不能因為宣告 charset 就推定每個源都只卡這一處。

已直接向四站送出各兩次請求；八份回應全是 HTTP 200。把原始回應交給 App 原解析器得到：

| 源（原始索引） | UTF-8 請求回應解析書數 | GBK 請求回應解析書數 | 僅改編碼的全流程對照 |
|---|---:|---:|---|
| 🔞新御书屋3 (33) | 0 | 30 | detail: 搜尋《救命！我的厌女症总裁不仅碰瓷还装秒(1v1 调教高h)》；發現要求逾時。 |
| 📂桔纸书屋 (34) | 0 | 30 | content: 搜尋Fetched empty content |
| 🔞po18城 (490) | 0 | 30 | toc: 搜尋目錄失效；發現目錄失效 |
| ⚡📂笔趣阁 (635) | 0 | 30 | toc: 搜尋目錄失效 |

這四源對照只在測試材料中，把 `{{key}}` 換成 `{{Packages.java.net.URLEncoder.encode(key, "GBK")}}`；正式程式碼和原始凍結包沒有因此修改。對照使用新時間戳隔離搜尋快取。書數差異證明搜尋編碼有影響；全流程結果才表示這次能否一路走到正文。

代碼：[AnalyzeUrl.swift](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/URL/AnalyzeUrl.swift:633)、[Legado-E 對照](/Users/zhangruilin/Desktop/Yuedu-reader/legado-E/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt:302)。

## 2. URL 模板得到空值時沒有被消掉

`AnalyzeUrl.replaceDoubleBraceTemplates` 用了 `RuleAnalyzer.innerRule(inner:startStep:endStep:)`，該版本只接受非空字串替換。Legado-E 的 AnalyzeUrl 用的是接受空值的明確開始/結束符版本。

結果有兩種常見形狀：`cookie.removeCookie(...)` 沒有回傳值；或第 1 頁應該是空後綴的 `page == 1 ? '' : ...`。模板被原樣留在 URL，已有實際 404 請求紀錄，例如索引 241、360。47 源含這兩種候選形狀；不是 47 個都已個別證實卡在這裡。

用 App 的 JSCoreEngine 和 AnalyzeUrl 重現索引 13、93：JS 沒有錯誤，但 URL 仍保留模板。另一條 native 搜尋 URL 路徑還不處理 `<,page/{{page}}/>`：索引 40 恩京的頁面回應先前能離線解析 13 本，現在實際搜尋仍 404；這類 native 搜尋頁數區塊候選 4 源。

代碼：[AnalyzeUrl.swift](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/URL/AnalyzeUrl.swift:305)、[RuleAnalyzer.swift](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/RuleAnalyzer.swift:158)、[native URL renderer](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceURLRendering.swift:11)。

## 3. WebView 宣告讀進來，runtime 請求卻沒有採用

`AnalyzeUrl` 解析 `useWebView`、`webView`、`webJs`、延遲等欄位，但 `ModernParserBridge.fetch` 建構請求後直接走 URLSession；該路徑沒有依這些欄位切換 WebView。章節入口又先以 `shouldUseLegadoRuntimeFetch` 返回，帶 options 的 URL 會在後面 native 的 WebView 判斷前轉出。

44 源帶有 WebView 相關宣告（URL 字串/腳本含啟用宣告，或實際 ruleContent.webJs）。這是靜態候選，不代表每個宣告都會在此次首本首章被走到；有些站同時允許直接 HTTP，因此即使沒有採用仍可能通過。本次沒有製作 Android/iOS 成對 WebView 端到端對照，不能把這 44 個全判成已證實受損。

代碼：[runtime fetch](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift:2751)、[章節入口](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/BookSource/BookSourceFetcher+Chapter.swift:94)。

## 4. 表格修正還有普通 CSS 路由缺口

全本、奇書在新版已通過整條驗證，證明保留 DOM 元素的修改確實有收益。但 `tbody tr`、`ul li`、`dl dd` 這些沒有 class/id/其他特殊符號的普通 CSS，可能同時不被 CssExtractor 和 JsoupDefaultExtractor 認領，落到 LegacyFallbackExtractor。後者交回文字，後面的欄位規則失去 DOM。

本包搜尋/發現/目錄列表中，16 源有這種普通後代選擇器的形狀（含組合規則中的分支），仍是候選範圍。直接取網站的萬象、夜伴回應，把 `tbody tr` 改寫成等價的 `tbody > tr` 的離線對照如下。另一次只加 `@css:` 前綴的對照仍得到 0 本：SourceRule 剝掉前綴後，路由又回到同一個辨識缺口。

| 源 | 原規則書數 | 等價 CSS 書數 | 回應表格列數 |
|---|---:|---:|---:|
| ⚡📂万象书城 (155) | 0 | 429 | 429 |
| 📂夜伴书屋 (163) | 0 | 464 | 464 |

另一個更廣的 DOM 缺口是 XPath 列表：20 源的搜尋/發現/目錄列表以 XPath 開頭，本次 20 個都未全項通過。`ModernRuleEngine.extractElementsViaExtractor` 對 XPath 呼叫的是 `extractList`，而 `XPathExtractor` 將節點讀成 `stringValue`，後續 `a@href` 就沒有元素可讀。索引 635 的同一份真實目錄頁，原 XPath 列表映射得 0 項，等價 CSS 列表得 1104 項。此控制為重用列表診斷器，將 chapterList/name/url 映射到 search bookList/name/bookUrl，並清空詳情規則，排除空列表自動轉詳情頁。這證實該頁的節點傳遞缺口，不等於 20 個源已全部做過成對測試。

此外，8 源的目錄列表以 `+` 開頭，本次 8 個都未全過。Legado-E 在 BookChapterList/BookList 先移除 `+`；目前 iOS getElements 只處理 `-`。索引 490 在編碼控制後已可搜到 30 本，卻於 `+<js>` 目錄出現 `result.replace is not a function`。這是另一個已定位的列表語意差異。

代碼：[CSS 判斷](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/CssExtractor.swift:182)、[元素提取路由](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/ModernRuleEngine.swift:990)、[文字 fallback](/Users/zhangruilin/Desktop/Yuedu-reader/Modules/Core/RuleEngine/ModernParser/LegacyFallbackExtractor.swift:8)。

## 候選群與實測分開計數

| 規則候選群 | 包內源數 | 新版全項通過 | 新版未全項通過 |
|---|---:|---:|---:|
| 指定 GBK/GB2312 搜尋 | 117 | 7 | 110 |
| 空值 URL 模板形狀 | 47 | 4 | 43 |
| WebView 宣告 | 44 | 16 | 28 |
| native 搜尋分頁區塊 | 4 | 0 | 4 |
| XPath 列表 | 20 | 0 | 20 |
| 普通後代 CSS 列表 | 16 | 0 | 16 |
| 前置加號目錄列表 | 8 | 0 | 8 |
| 規則內容含 tr/td/tbody | 127 | 22 | 105 |
| ruleBookInfo.init | 118 | 52 | 66 |

群與群之間有重疊；表格、init 兩列包含已修部分，不能拿其全部失敗數當作尚未修的 bug 數。較早粗掃表格是對 JSON 序列化文字比對得到 130；本次改為對實際規則字串比對 tr/td/tbody，精確定義為 127。

你先前列的八個 java 方法，在凍結包中直接呼叫這八個名字的源合計 12 個。它們值得補，但目前已有證據顯示，共用請求和規則路由才是更大的排查入口。

## 驗證與材料

- 794 源：`BookSourceCompatibilityAuditTests`。政策為搜尋、發現、詳情、目錄、內容全檢，預設關鍵字「我的」，每源 180 秒。通過率是檢查器判定，不是每一本書/完整影片都人工讀過。
- 4 源編碼控制：同一 audit 類別，僅測試包搜尋編碼改寫。
- 14 份真實回應/控制：`CapturedBookSourceResponseAuditTests`；回應取自直接網站請求，沒有替換為假網頁。
- 7 筆請求診斷：`YCK1330RequestDiagnosticsTests`，使用實際 AnalyzeUrl、URLRequest、JSCoreEngine 和 native renderer，沒有發出其診斷 URL 的網路請求。
- 都以 `scripts/xctest.sh` 透過 iPhone 18 Pro Max / iOS 27.2 模擬器執行；詳細建置與測試結果在 log。正式程式碼未為此調查修改，新增的是 opt-in 診斷測試。
- 全量快取隔離只改 lastUpdateTime；驗證 794 份規則其餘內容完全一致。三次跨日結果不等於 Android/iOS 同時同網路的成對 oracle。
- `siteError` 是檢查器分類，可能包含錯誤 URL、TLS、反爬、網路與真正站點故障；本報告沒有把分類名直接當作網站已死的證據。

[完整 JSON](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/full-current.json)、[794 源 CSV](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/current-results.csv)、[候選群及原始索引](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/impact-analysis.json)、[編碼控制結果](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/gbk-control.json)、[最後回應解析結果](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/expanded-responses.json)、[請求診斷](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/request-diagnostics.json)、[直接網站比較](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/gbk-probes/results.json)、[全量日誌](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/full-current.log.gz)、[最後回應診斷日誌](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/expanded-responses-final.log.gz)、[編碼及請求診斷日誌](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/focused-diagnostics.log.gz)、[代碼快照](/Users/zhangruilin/Documents/Codex/Reports/yck1330-20261106-current/code-snapshot.json)。
