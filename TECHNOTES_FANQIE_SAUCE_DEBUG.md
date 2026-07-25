# 🌙 番茄酱 (Fanqie Sauce) iOS 適配 — 根因與修法

## 症狀

章節內容回傳錯誤文字（147–183 bytes），JS 沒有拋出例外（`jsError=none`）：

```
请求失败: undefined is not an object (evaluating 'f[(a-=78)- --O+76][t(A[r++]^66437-O+r,A[r++]^13170+O--+r)]')
```

## 結論：不是 JavaScriptCore 的問題

用 Node（V8）跑同一份 `to.js` + 同一份 jsLib，**得到完全相同的失敗**
（只是 V8 的訊息長相不同：`Cannot read properties of undefined (reading 'content')`）。
換句話說「Rhino → JSCore 的 try/catch/finally 堆疊差異」這個舊結論是錯的，
`to.js` 的 bytecode VM 在 JSCore 上跑得好好的。

`请求失败: …` 是 `to.js` 自己的 catch 印出來的字串，錯誤發生在**發任何 HTTP 請求之前**。

## 真正的根因：`source` 物件只暴露了 7 個欄位

`to.js` 一開始就做**防篡改自檢**：

```js
java.md5Encode(source.bookSourceComment + source.concurrentRate + source.ruleContent.content)
  === "c5ba548eec2b5d56ee344e7cd96cb1d1"
```

Legado（Android）跑在 Rhino 上，`source` **就是** BookSource 物件本身，
Java interop 讓書源 JS 可以讀到自己書源的任何欄位，包含巢狀規則群組。

我們的 `LegadoSourceBridge` 只暴露了 `bookSourceUrl / bookSourceName / bookSourceGroup /
bookSourceComment / loginUrl / header / loginCheckJs`。於是：

- `source.concurrentRate` → `undefined`
- `source.ruleContent` → `undefined` → `.content` **拋 TypeError**

自檢炸掉 → VM 進 catch → 寫出 `请求失败: …`。整條鏈就停在這裡。

## 修好自檢之後，下游還有兩個坑

追完整條資料流（Node harness 逐步 mock），`to.js` 的完整流程是：

1. `source` 自檢（md5）→ 解出可用的 API endpoint 清單
2. `java.hexDecodeToString(result)` → `bookId#chapterId`，取 `#` 後半段
3. `java.androidId()` + `Math.floor(Date.now()/1000)` →
   `java.HMacBase64(androidId + timestamp, "HmacSHA256", "skybbk-9527260510")` → `Authorization`
4. `java.ajax(backend + "/fq/content?item_id=…,{"headers":{UUID,Authorization,timestamp}}")`
5. **`java.getString("$..content", <上一步的 JSON 字串>)`** ← 兩參數形式
6. `<article>…</article>` 正則備援
7. **`org.jsoup.Jsoup.parse(html).select("body").html()`** ← 取正文

| # | 缺口 | 原本行為 |
|---|------|----------|
| 1 | `source` 欄位不全 | `source.ruleContent` undefined → 自檢 TypeError |
| 2 | `java.getString` 只吃 1 個參數 | 第 2 參數被靜默忽略 → 對錯的文件求值 → 回 `""` |
| 3 | `org.jsoup` polyfill 的 `select()` 永遠回空集合 | 正文變成空字串 |

## 修法

1. **`LegadoSourceBridge` 暴露完整 BookSource**（對齊 Legado）：所有純量欄位 +
   `ruleSearch/ruleExplore/ruleBookInfo/ruleToc/ruleContent/ruleReview` 以 `NSDictionary`
   曝給 JS，key 用 Legado 的 JSON 欄位名（例如 `ruleBookInfo.init`，不是 Swift 的 `initScript`）。
2. **`java.getString(rule, mContent)`**：改成 `getString(_ ruleStr: String, _ mContent: JSValue)`。
   JSCore 在 JS 只傳一個參數時會補 `undefined`，所以舊的單參數呼叫完全不受影響。
   `mContent` 有值時走 `ModernRuleEngine.getString(ruleStr:mContent:)`（per-call 輸入，不會
   污染外層規則鏈正在解析的內容）。
3. **`org.jsoup` 改由 SwiftSoup 支撐**（`LegadoJsoupBridge.swift`）。JS 端的 `Element` 只是
   原生節點的薄包裝，生命週期交給 JavaScriptCore 管理 —— **不能**在呼叫之間把節點序列化回字串，
   因為 HTML parser 對 `<body>` / `<td>` / `<li>` 這類片段是上下文敏感的，來回一趟就被改寫了。
   文件走既有的 `JsoupDocumentCache`，全 app 仍然只有一個 HTML parser。

## 驗證

- Node harness 用**修好後 bridge 完全相同的欄位集合**重跑：拿到完整章節（4822 字元，
  `<h1>` + 100 個 `<p>`）。
- Swift/JavaScriptCore probe：把真實書源值餵進新的 `LegadoSourceBridge` 形狀，
  在 JS 端算出的 `bookSourceComment + concurrentRate + ruleContent.content`
  md5 = `c5ba548eec2b5d56ee344e7cd96cb1d1`，與 `to.js` 內建的摘要一致 → 自檢會過。

## 已撤銷的錯誤修法

- `AnalyzeUrl` 把 query 裡的 `#` 編成 `%23`：實際 URL 只帶 `chapterId`，沒有 `#`。
  這個改動會影響所有書源，已撤回。
- `parseChapterResult` 傳 `mContent: html`：`engine.setContent(html, …)` 已經設過同一份內容，
  多此一舉，已撤回。
- `hexDecodeToString` 在輸入非 hex 時回傳原字串：那是為了掩蓋上面誤判而加的，已還原成回 `""`。
- `bodyForDataURI` 的 hex 行為（`type != nil` → hex）**是對的**，維持不變。

## 後續：標題重複（`ruleContent.replaceRegex` 從來沒生效）

正文能顯示之後，畫面上章節標題出現兩次：一個是 app 自己的章節標題，一個是書源回傳的
`<h1 class="chapterTitle1">第1章 …</h1>`。

書源本來就有清掉它的規則：

```
ruleContent.replaceRegex = ##<!DOCTYPE.*dtd">|<tt.*ad>|{{chapter.title}}|^第.{0,8}章
```

兩個獨立的問題讓它完全沒作用：

1. **`{{chapter.title}}` 沒被展開。** 我們把整串當正則丟給 `NSRegularExpression` —
   `{{…}}` 不是合法正則，**整個 pattern 編譯失敗**（`try?` → nil）→ 一條都沒替換。
   Legado 是先在 `makeUpRule` 展開 `{{}}`（JS 求值）再用 `##` 切，所以那裡會變成真的章節標題字串。
2. **就算展開了也照不到畫面。** `ChapterFetcher` 只把 replaceRegex 套在「純文字」那份 content 上；
   實際渲染 HTML 的那條分支吃的是 `parsed.content`（未處理的原始 HTML）。
   → 任何回傳 HTML 的書源，它自己的清理規則都被靜默丟掉。

**修法**：照 Legado `BookContent.analyzeContent` 的做法，在 `parseChapterResult` 內用規則引擎跑
`engine.getString(ruleStr: source.ruleContent.replaceRegex, mContent: content)`。
`SourceRule.makeUpRule` 會展開 `{{chapter.title}}`、切 `##`；`shouldPerformExtraction`
在 rule 為空時是 false，所以只做替換不做抽取。這樣 `parsed.content` 本身就乾淨了，
純文字與 HTML 兩條分支都吃得到。

替換後留下空的 `<h1 …></h1>`，`NodeAttributedStringRenderer.renderBlock` 對
`contentLength == 0` 且沒有背景/邊框/高度的 block 直接回空字串，不會多出空行。

## 注意事項

- 這個 md5 自檢代表：**書源 JSON 的 `bookSourceComment`、`concurrentRate`、
  `ruleContent.content` 一個字都不能動**，否則 `to.js` 直接罷工。匯入/同步流程若會改寫這三個
  欄位，番茄酱就會壞掉。
- `java.HMacBase64`、`java.androidId`、`java.md5Encode` 早就有了，不是缺口。
- 後端 `skybook.1113355.xyz` 沒有 Authorization 會回 `{"error":"Unauthorized"}`。
