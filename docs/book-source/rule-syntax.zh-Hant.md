# 書源規則語法速查

> 其他章節：[快速開始](quickstart.zh-Hant.md) · [與 Legado 的差異](legado-differences.zh-Hant.md) · [常見症狀對照表](troubleshooting.zh-Hant.md)
> 简体中文：[规则语法速查](rule-syntax.zh-Hans.md)

一條「規則」告訴 App 從抓回來的網頁（HTML／JSON）裡取出哪個資料。規則可以串接、可以套正則、可以執行 JS。本頁是 Yuedu 規則引擎的語法速查，所有語法都與 Legado 3.0 相容。

## 1. 規則模式與前綴

引擎依前綴自動判斷規則的解析模式。前綴**大小寫不敏感**：

| 前綴 | 模式 | 說明 |
| --- | --- | --- |
| （無前綴） | JSOUP Default | 跟隨 Legado 的預設語法（`class.`/`tag.`/`id.`/`text.`…），或直接的 CSS 選擇器 |
| `@css:` | CSS | SwiftSoup（jsoup 相容）CSS 選擇器 |
| `@@` | CSS（強制） | 跟 Legado 一樣，`@@` 開頭強制用 CSS |
| `@xpath:`、`//…`、`/…` | XPath | XPath 1.0（libxml2） |
| `@json:`、`$.`、`$[` | JSONPath | 自實作 JSONPath，用於 JSON 響應 |
| `@js:`、`<js>…</js>` | JavaScript | 在 JavaScriptCore 執行，`result` 變數放上一段結果 |
| `##…##…##` | 正則 | 見下方「正則替換」 |

兩個特殊前綴：

- 清單規則**首字元 `-`**：結果反序（目錄倒序常用，如 `-tag.li`、`-:<li>…`）
- **`: ` 開頭**（正則 AllInOne）：整段是正則，用於搜索列表、發現列表、詳情預處理與目錄列表；搭配 `$1`、`$2` 群組引用

規則內含 `$N` 群組引用或 `{{…}}` 樣板時，該段會自動改用**正則模式**求值。

## 2. JSOUP Default 語法（無前綴）

Legado 經典寫法，用 `@` 分隔一段段「選擇步驟」，最後一段是取內容：

```
class.odd.0@tag.a.0@text
id.catalog@tag.li@tag.a@href
```

| 步驟 | 語法 | 示例 |
| --- | --- | --- |
| 選 class | `class.名稱` | `class.booknav2`（多個 class 用空格，如 `class.a b`） |
| 選 id | `id.名稱` | `id.content` |
| 選標籤 | `tag.名稱` | `tag.li`、`tag.a` |
| 依文字選 | `text.關鍵字` | `text.下一章`（`:containsOwn` 效果） |
| 子元素 | `children` | `head@children` |
| 位置 | `0`／`-1`／`!0:3` | `tag.a.0` 第一個、`tag.a.-1` 倒數第一個、`tag.dd.!0:3` 排除 0~3 |
| 陣列記法 | `[索引]` | `tag.div[0]`、`tag.div[-1]`、`tag.div[0,2,5]`、`tag.div[!0:3]`、`tag.div[0:10:2]`、`tag.div[-1:0]`（反轉） |

最後一段取內容（accessor）：

| 關鍵字 | 取回 |
| --- | --- |
| `@text` | 純文字（`ownText` 只取自身文字、`@textNodes` 取所有文字節點） |
| `@html`（`@innerhtml`） | 元素內部 HTML（自動移除 script/style） |
| `@outherhtml` | 元素包含自身的 HTML |
| `@all` | 所有匹配元素的外層 HTML，用換行連接 |
| `@href`、`@src`、`@action` | 屬性值，並**自動解析成絕對 URL** |
| `@class`、`@id`、`@title`、`@alt`、`@value`… | 任意屬性名 |
| `@attr(xxx)` | 屬性名有特殊字元時 |

## 3. CSS 規則

`@css:` 開頭，支援 jsoup／SwiftSoup 的選擇器，包括：`#id`、`.class`、`tag`、子代 `>`、後代（空格）、屬性選擇器（`[a=b]`、`[a^=x]`、`[a$=x]`、`[a*=x]`、`[a~=x]`、`[a!=b]`）、`:eq(n)`、`:lt(n)`、`:gt(n)`、`:first-child`、`:last-child`、`:nth-child(an+b)`、`:has(sel)`、`:not(sel)`、`:contains(text)`、`:containsOwn(text)`、`:matches(regex)`。

```
@css:.book-list li@text
@css:div[data-type="novel"] a@href
@css:#list li:has(a)@@a@text        ← @@ 鏈式：先選 #list li，再在每項內選 a
```

篩選結果再做第二層選擇：`A@@B`＝在 A 的每個匹配內再選 B。

## 4. XPath 規則

`@xpath:`（或直接 `//` 開頭）使用完整 XPath 1.0，支援 `|` 聯合、軸（`following-sibling::`、`preceding-sibling::`、`ancestor::`…）、`[position()>1]` 等。取多個規則用 `||`/`&&`/`%%` 連接也行。

```
@xpath://div[@class='book']/h3/a/text()
//*[@id="content"]/p[1]/text()
//li[4]/a/text()||//li[5]/a/text()
```

`/@attr` 結尾直接取屬性（會解析絕對 URL）；`text()`、`/html()` 結尾取文字／HTML。

## 5. JSONPath 規則

`@json:` 或 `$.`／`$[` 開頭的規則對 **JSON 響應**求值（搜索結果是 JSON 的書源必用）：

```
$.info.Datas             ← 鍵路徑
$['store']['book']       ← 括號記法
$..name                  ← 遞迴搜尋
$[0]  $[-1]  $[0:3]      ← 索引／切片（支援負數）
$[?(@.price < 10)]       ← 過濾器（支援 == != < > <= >= =~ 與 && || !）
$[0,1]  $['a','b']       ← 多索引／多鍵
$.books.length()         ← 長度
```

不支援 jayway 的腳本表達式（如 `@.length()-1`、`min()/max()`）。擋掉的方法見[差異章節](legado-differences.zh-Hant.md)。

## 6. JavaScript 規則

`<js>…</js>` 可在規則鏈任意位置，也是規則段的**分隔符**；`@js:` 只能作為整條規則的最後一段。

```js
@css:.book@html<js>result.replace(/<a.*?a>/g,'')</js>
@css:.cover@src@js:result.replace('http','https')
```

JS 中的可用變數與函式（`result`、`baseUrl`、`src`、`book`、`chapter`、`java.xxx`…）請見[與 Legado 的差異](legado-differences.zh-Hant.md)的完整清單。

## 7. 串接與多規則

| 語法 | 作用 |
| --- | --- |
| `<js></js>` | 切分規則段，前段輸出作為後段輸入 |
| `||` | 多條規則取**第一個非空**結果 |
| `&&` | 多條規則結果**合併**（換行連接） |
| `%%` | 多條規則結果**逐位交錯**（第 1 條的第 1 項、第 2 條的第 1 項…） |
| `@@` | CSS 鏈式選擇器 |
| `##…##…##` | 正則替換（見下） |
| `@put:{…}` | 求值後寫入變數（`@put:{bid:"//*[@bid-data]/@bid-data"}` 或 `@put:{key:value}`） |
| `@get:{key}` | 讀出先前 `@put` 的變數 |

## 8. 正則替換（`##`）

三種形態，跟 Legado 完全一致：

| 形態 | 語法 | 用途 |
| --- | --- | --- |
| 淨化 | `規則##正則##替換` | 跟在規則後面，對結果循環替換（去廣告最常用）；替換內容可留空但**結尾的 `##` 不能省** |
| OnlyOne | `##正則##替換###` | 獨立成條、只取並替換**第一個匹配**（詳情頁 meta 提取常用） |
| AllInOne | `:正則` 或 `-:正則` | 首字元 `:`；用群組取列表（`$1`、`$2`…） |

群組引用是 `$1`…（regex 模式時，規則含 `$N` 會自動切到正則模式）。

## 9. URL 模板與變數

搜索 URL、發現 URL、章節 URL、目錄 URL 等「網址類」欄位支援：

| 樣板 | 值 |
| --- | --- |
| `{{key}}`、`{{searchKey}}` | 搜索關鍵字 |
| `{{page}}` | 頁碼（從 1 起） |
| `{{pageIndex}}` | 頁碼 - 1 |
| `{{header}}` | 書源請求頭字串 |
| `{{speakText}}`、`{{speakSpeed}}` | 朗讀用（語音源） |
| `{{任意 JS 表達式}}` | 當 JS 執行，如 `{{(page-1)*20}}`、`{{java.base64Encode(key)}}` |
| `<值1,值2>` | 分頁規則：page=1 取逗號前，page>1 取逗號後；`<,{{page}}>` 表示第一頁留空 |
| `{$.欄位}` | 2.0 舊式 JSONPath（僅 JSON 情境） |

GET 的完整形態；URL 後可接字面 JSON 選項，逗號分隔：

```
https://example.com/search?q={{key}},{"charset":"gbk"}
https://example.com/search,{"method":"POST","body":"key={{key}}&page={{page}}","charset":"gbk"}
```

支援的選項：`method`、`body`、`charset`（如 `"gbk"`）、`headers`、`webView`／`useWebView`（使用無頭 WebView）、`webJs`、`bodyJs`、`webViewDelayTime`、`type`、`js`。請求頭欄位本身也可用 `<js>` 返回 JSON 字串。`retry` 與 `serverID` 目前只會被解析以保持格式相容，**不會自動重送或切換伺服器**。

**規則字串裡**的 `{{…}}` 語意不同：`{{@…}}`、`{{$.…}}`、`{{//…}}` 開頭＝嵌入另一條規則；其餘＝當 JS 執行（可用的變數只有 `baseUrl`／`baseURL`／`nextChapterUrl`／`src`／`result`）。URL 專用的 `{{key}}` 在這裏**不是**變數——需要搜索詞時用 `{{java.get('key')}}` 或 `java.get`。

### 9.1 正文圖片點擊與段評頁

Legado 正文常在圖片 URL 後附 `,{...}` 點擊設定。Yuedu 支援 `click`、`action`，以及相容分支使用的 `js` 鍵；點擊時會在**原書源的同一個 session** 執行原始 JS，並還原當時的 `book`、`chapter`、`result`、`src`、`baseUrl` 與非敏感運行變數。像 `showCmt(bookId, chapterId, paragraphId)` 這種參數不是 URL，App 不會自行猜 API 路徑。

來源呼叫 `java.showBrowser(baseUrl, html, preloadJS, configJSON)` 時，第四參數支援：

| 設定 | 說明 |
| --- | --- |
| `heightPercentage` | 展開高度，範圍 0–1 |
| `skipCollapsed` | 跳過中等高度，直接使用展開高度 |
| `isHideable` | 是否允許下拉關閉 |
| `expandedCornersRadius` | 展開狀態圓角，0–120 |
| `hardwareAccelerated` | 接受但不另行切換；WKWebView 本身使用加速合成 |

四參數 `showBrowser` 載入的書源自建頁面可同步呼叫 `java.ajax(url)`、`java.get(url, headers)`、`java.post(url, body, headers)`、`java.head(url, headers)` 與 `java.connect(url[, headers, timeout])`。請求仍走原書源的同一個 session，會套用書源標頭、登入標頭、cookie 與 URL 選項；回傳形狀依 Legado-E／MD3 的 `WebJsExtensions`，其中 `ajax`／`get`／`post` 是正文字串、`head` 是標頭 JSON 字串。頁面若要執行其他書源 JS，可用回傳 Promise 的 `run(script)`。

書源／登入瀏覽器會把 `java.copyText`、`navigator.clipboard.writeText` 與 `document.execCommand('copy')` 接到 iOS 系統剪貼簿。

## 10. 欄位對照：編輯器分頁 ↔ Legado JSON 欄位

App 的書源編輯器以「基本／搜索／發現／詳情／目錄／正文」六個分頁對應 Legado JSON 的 `rule*` 物件，欄位與 JSON 鍵一一對應：

| 編輯器分頁 | 欄位 | JSON 鍵 |
| --- | --- | --- |
| 基本 | 書源名稱／地址／分組／註釋 | 同名頂層鍵 |
| 基本 | 登入頁 URL／登入 UI／登入檢查 JS | `loginUrl`／`loginUi`／`loginCheckJs` |
| 基本 | 封面解密、書籍 URL 正則、請求頭、變量說明、並發率、jsLib | `coverDecodeJs`／`bookUrlPattern`／`header`／`variableComment`／`concurrentRate`／`jsLib` |
| 搜索 | 搜索 URL、校驗關鍵字 | `searchUrl`、`ruleSearch.checkKeyWord` |
| 搜索／發現 | 書籍列表／書名／作者／分類／字數／最新章節／簡介／封面／詳情頁 URL／更新時間 | `ruleSearch`、`ruleExplore` 內同名鍵 |
| 發現 | 發現地址規則 | `exploreUrl` |
| 詳情 | 預處理規則 | `ruleBookInfo.init` |
| 詳情 | 書名／作者／分類／字數／最新章節／簡介／封面／目錄 URL／允許修改書名作者／下載 URL／聽書骰子 | `ruleBookInfo` 內同名鍵（目錄 URL＝`tocUrl`） |
| 目錄 | 更新之前 JS | `ruleToc.preUpdateJs` |
| 目錄 | 章節列表／章節名稱／章節 URL／格式化／卷標識／章節信息／VIP 標識／購買標識／目錄下一頁 | `ruleToc` 內同名鍵 |
| 正文 | 正文規則／章節名稱／正文下一頁 URL／WebView JS／資源正則／替換規則／圖片樣式／圖片解密／購買操作 | `ruleContent` 內同名鍵 |

> 註：匯入的 JSON 偶爾會是「整段字串化」的（如 `"ruleSearch": "{...}"`），App 會自動解開，不需手動處理。

## 11. 常用可複製範例

```json
{
  "bookSourceName": "範例書源",
  "bookSourceUrl": "https://example.com",
  "searchUrl": "/search?q={{key}}",
  "ruleSearch": {
    "bookList": ".book-list li",
    "name": ".title@text",
    "author": ".author@text",
    "bookUrl": "a@href",
    "coverUrl": "img@src"
  },
  "ruleToc": {
    "chapterList": "#list a",
    "chapterName": "@text",
    "chapterUrl": "@href"
  },
  "ruleContent": {
    "content": "#content@html##<div class=\"ad\">[\\s\\S]*?</div>|本章未完，點擊下一頁##",
    "nextContentUrl": ".next-page@href"
  }
}
```

## 下一步

- [與 Legado 的差異](legado-differences.zh-Hant.md) — 哪些語法在 Yuedu 行為不同或不存在
- [常見症狀對照表](troubleshooting.zh-Hant.md) — 書源壞掉時對照症狀找解法
