# 與 Legado 的差異（書源為什麼壞掉）

> 其他章節：[快速開始](quickstart.zh-Hant.md) · [規則語法速查](rule-syntax.zh-Hant.md) · [常見症狀對照表](troubleshooting.zh-Hant.md)
> 简体中文：[与 Legado 的差异](legado-differences.zh-Hans.md)

Yuedu 的書源格式與 Legado 3.0 完全相容，但**底層引擎不同**。多數書源可以直接用，少數依賴 Legado 特有 API 或語法的書源會失效。改書源之前，先看這一頁——書源壞掉的主因 80% 集中在這裡。

## 0. 一句話總結

| Legado | Yuedu |
| --- | --- |
| Rhino（Java）JavaScript 引擎 | JavaScriptCore（Safari 同款） |
| jsoup HTML 解析 | SwiftSoup（jsoup 相容實作） |
| Java 正則引擎 | ICU 正則引擎（近親，細節不同） |
| Jayway JSONPath | 自實作 JSONPath |
| JsoupXpath | libxml2 XPath 1.0 |

**最大風險是 JS**：Legado 書源會呼叫 Android／Java API，Yuedu 用一個 `java.*` 相容層承接，**有一個白名單**——白名單外的呼叫會直接報 `ERROR`。書源在兩端行為不同，九成是 JS 用了白名單外的東西。

## 1. `java.*` API 對照

### 已支援（可直接使用）

| API | 說明 |
| --- | --- |
| `java.ajax(url)`、`java.ajaxAll([urls])` | 網路請求；`ajaxAll` 回傳陣列（取內容用 `.body()`） |
| `java.get(url, headers)`、`java.post(url, body, headers)` | 帶標頭的請求 |
| `java.get(變數名)` | **單參數**＝讀取先前存的變數（雙參數才是 HTTP GET） |
| `java.getString(rule)`、`java.getStringList(rule)`、`java.getElements(rule)`、`java.setContent(content, baseUrl)` | 在 JS 內再跑一條規則 |
| `java.base64Encode(s)`、`java.base64Decode(s)`、`java.base64DecodeToByteArray(s)` | Base64 |
| `java.md5Encode(s)`、`java.md5Encode16(s)` | MD5（32 位全小寫 hex／中間 16 位） |
| `java.HMacBase64(content, "SHA1|SHA256|SHA384|SHA512", key)` | HMAC，回傳 Base64 字串 |
| `java.aesEncryptHex(transformation, keyHex, ivHex, dataHex)`、`java.aesDecryptHex(...)` | AES/DES/3DES 加解密（hex 進出）——僅支援 ECB/CBC + PKCS5/PKCS7/NoPadding，其他組合回傳空字串 |
| `java.createSymmetricCrypto(...)`、`java.aesBase64Decode(...)`、`java.aesBase64DecodeToString(...)` | hutool 風格 AES 工具 |
| `java.hexEncodeToString(s)`、`java.hexDecodeToString(s)` | hex 編碼／解碼 |
| `java.encodeURI(s)`、`java.encodeURIComponent(s)` | URI 編碼 |
| `java.htmlFormat(s)` | HTML entity 解碼 |
| `java.t2s(s)`、`java.s2t(s)` | 繁簡轉換 |
| `java.timeFormat(ts)`、`java.timeFormatUTC(ts)` | 時間戳格式化 |
| `java.getCookie(url)`、`java.getCookie(url, key)` | 讀 cookie（寫入請用 `cookie.set`，見下） |
| `java.androidId()`、`java.deviceID()` | 裝置識別碼。注意：**不是真 ANDROID_ID**，是一串 16 位小寫 hex（SHA256 派生），細節見[快速開始](quickstart.zh-Hant.md)的「提供裝置識別碼」與下方說明 |
| `java.startBrowser(url)`、`java.startBrowserAwait(url)` | 開內建瀏覽器（等待返回）；`java.webView(url)` 是**無頭** WebView（載入後把 cookie 存下來，不給互動） |
| `java.log(msg)`、`java.toast(msg)`、`java.longToast(msg)` | 除錯輸出／提示（`log` 會進「網路日誌」） |
| `java.importScript(url)` | 引入遠端 JS |
| `java.searchBook(name)`、`java.open(url, "search")` | 交棒到搜索（其他 target 無動作） |
| `java.setResponseBase64(b64)` | 設定響應內容（TTS 登入檢查用） |
| `java.upLoginData(url)`、`java.reLoginView()` | 登入流程 |
| `java.axja(code)` | aaencode 混淆解碼 |
| `java.utf8ToGbk` — **沒有**（見下方清單） | — |

### 不存在／缺損（書源報 `ERROR` 的來源）

以下 Legado API **沒有對應實作**，呼叫即失敗：

| Legado API | 狀態 | 替代方案 |
| --- | --- | --- |
| `java2js` | 不存在 | 直接寫 JS |
| `java.appVersion` | 不存在 | 自己寫死版本字串 |
| `java.sha1`、`java.sha256`（單獨函式） | 不存在 | `java.HMacBase64(x, "SHA256", key)` 或改用其他簽名 |
| `java.md5` | 不存在 | 用 `java.md5Encode`（名稱不同！） |
| `java.rsa…`／RSA 加解密 | 整個 RSA 不存在 | 無替代，此類書源無法使用 |
| `java.gzipDecode`／gzip 工具 | 不存在 | 無替代 |
| `java.downloadFile` | 不存在 | 無替代 |
| `java.queryTTF`／`queryBase64TTF`／`replaceFont` | 不存在 | 無替代 |
| `java.getZipStringContent`／`getZipByteArrayContent` | 不存在 | 無替代 |
| `java.utf8ToGbk` | 不存在 | 需要 GBK 時在 URL 選項設 `"charset":"gbk"` |
| `java.getFile`／`readFile`／`readTxtFile`／`unzipFile`／`getTxtInFolder` | 不存在 | 無替代（本地檔案 API） |
| `java.aesDecodeToByteArray`／`aesDecodeToString`／`aesEncodeToBase64…` | 名稱不同 | 用 `java.aesDecryptHex`／`aesEncryptHex`／`aesBase64Decode` |
| `java.qread()` | **刻意 no-op** | 回傳空、不報錯。依賴它的書源會靜默失敗而非報 ERROR |
| `java.copyText` | stub（不實際複製） | — |
| `java.refreshExplore`／`refreshBookInfo`／`refreshBookToc`／`refreshContent` | no-op | — |
| `java.openVideoPlayer` | 退化成開瀏覽器 | — |

另外一個容易踩的：**`java.get` 的單參數／雙參數歧義**。Legado 靠 Java 多載，Yuedu 用參數數量分派：單參數＝讀變數，雙參數＝HTTP GET。呼叫前數清楚參數個數。

## 2. `Packages.*` 與 Java 類別白名單

書源 JS 常直接 import Java 類別（`importClass(Packages.java.security.MessageDigest)` 等）。Yuedu **只註冊了以下類別**，白名單外的 `new`／呼叫會拋 `UnsupportedLegadoAPIError`（調試日誌會看到 `ERROR:`）：

```
java.lang.String（含 getBytes）、java.lang.System（nanoTime/currentTimeMillis）
java.util：HashMap、LinkedHashMap、TreeMap、Hashtable、Properties、
           ArrayList、LinkedList、Vector、Arrays（copyOfRange）、Base64、UUID（randomUUID）
android.util.Base64（DEFAULT/NO_PADDING/NO_WRAP/CRLF/URL_SAFE、encodeToString/decode）
javax.crypto.Cipher（走 AES hex 通道）、javax.crypto.spec.SecretKeySpec、IvParameterSpec
cn.hutool：DigestUtil.md5Hex、StrUtil.reverse、Base64.encode/decode
```

`org.jsoup.*` 也有 polyfill，但**有損**：`Element.first()/last()` 回 null、`Connection.Response.headers()` 回 null、`statusCode()` 恆為 200。依賴 jsoup 物件導向操作的書源請改用規則引擎本身的功能。

## 3. 模板變數的語意差異（最容易踩）

| 位置 | Legado | Yuedu（相同） | 差異 |
| --- | --- | --- | --- |
| 搜索/發現 URL | `{{key}}`、`{{page}}`、`{{pageIndex}}`、`{{header}}`、`{{JS}}` | ✅ 完全支援 | 無 |
| 章節/目錄 URL | 同上 | ✅ 支援 | 無 |
| **規則字串**（如 chapterName、content） | `{{彈性規則}}` | ✅ | `{{key}}` **不是變數**——規則字串的 `{{…}}` 只認兩種：`@`/`$.`/`$[`/`//` 開頭＝嵌入規則，否則＝執行 JS，而 JS 綁定的變數只有 `baseUrl`/`baseURL`/`nextChapterUrl`/`src`/`result`。需要搜索詞就提早用 URL 模板處理，別在規則字串裡用 `{{key}}` |
| `{{js:…}}` 前綴 | Legado 有 | **不支援** | 前綴不會被剝除，`{{js:foo()}}` 會被當成 JS 標籤陳述句執行，行為不可預期。請直接把 `js:` 去掉寫成 `{{foo()}}` |

`@put`／`@get`、`$1` 群組引用、`{$.欄位}` 舊式 JSONPath 都與 Legado 一致。

## 4. Cookie

- 讀：`java.getCookie(url[,key])`、`cookie.get(url)`、`cookie.getKey(url,key)`
- 寫：`cookie.set(url, "k=v; k2=v2")`、`cookie.setCookie(...)`、`cookie.replaceCookie(...)`（合併語意）
- 刪：`cookie.remove(url)`、`java.removeCookie(url)`
- **Cookie 罐永遠啟用**：書源的 `enabledCookieJar` 開關只是「承載並透明化」欄位，沒有實際作用——所有書源的 cookie 都會自動保存、自動帶上。請求沒帶 Cookkie 時，引擎會自動附上該域已存的 cookie。
- `loginCheckJs`：搜索取得 HTML 後執行，回傳 true＝判定需要登入。搭配「登入頁 URL」＋「Cookie 驗證登入」使用。

## 5. 正則差異（ICU ≠ Java）

規則裡的 `##正則##` 用 **ICU 正則**執行。Legado 書源常見的 Java-only 語法會自動做近似轉換：

| Java 語法 | ICU | Yuedu 處理 |
| --- | --- | --- |
| `++`、`*+`、`?+`、`{n,m}+`（possessive） | 不支援 | 近似轉成一般量詞（語義不完全等價） |
| `(?>…)`（atomic group） | 不支援 | 近似轉換（語義不完全等價） |
| `\R`、`\e` | 不支援 | 轉換成等價寫法 |
| `(?d)` flag | 不支援 | 剝除 |
| `\p{javaXxx}` 類別 | 不支援 | 轉譯 |

使用注意：

- 每次正則執行有 **2 秒超時**：災難性回溯的規則會直接回傳原值（不會卡死，但等於沒處理）
- 依賴 possesive／atomic 精確語義的書源可能出現「結果跟 Legado 差一點」的情況，屬預期

## 6. JSONPath 差異

支援：點記法、括號記法、索引/切片（含負數）、`$..` 遞迴、過濾器（`== != < > <= >= =~`、`&&`、`||`、`!`）、多索引/多鍵、`length()`。

**不支援**：

- jayway 腳本表達式：`@.length()-1`、`@.price * 2` 這類運算
- `min()`/`max()`/`avg()` 等函式
- 過濾器比較時，運算子必須是 `== != <= >= < > =~` 其一（`=~` 是正則比對）

碰到就改寫成規則鏈或 `<js>` 處理。

## 7. XPath 差異

- 透過 libxml2 提供**完整 XPath 1.0**：`|` 聯合、軸（`following-sibling::` 等）、`[position()>1]`、`[text()="x"]` 都可用——這部分比 Legado 的 JsoupXpath 更標準
- **`!/` 前綴沒有任何語義**：Legado 的 `!/`（取非？）在 Yuedu 不會被解釋，等同查一條非法 XPath → 空結果。不要用
- `@xpath:` 以外的 `//…` 開頭（含沒有前綴的 `//`）會被正確路由到 XPath 模式

## 8. 其他注意事項

| 項目 | 說明 |
| --- | --- |
| HTML 大小上限 | 超過 **4 MB** 的網頁會被截斷再解析（防記憶體爆掉） |
| JS 執行 | JavaScriptCore；單次求值 30 秒超時，超時重置引擎；`eval()` 保留開啟（Legado 混淆 jsLib 需要）；每段 JS 結果會自動處理 `result` 包裝 |
| `setContent` | `java.setContent(content, baseUrl)` 可用，主路徑照樣執行 |
| Cloudflare 挑戰 | 請求遇 403/503/429 且帶 CF 特徵時，會跳出人機驗證頁，通過後自動重試一次 |
| 段落縮排 | Legado 在 `replaceRegex` 後會自動每行補全形空格縮排，Yuedu **刻意不做**（可自行在替換規則加 `　　`） |
| `respondTime`／`concurrentRate` | `respondTime` 作為 JS 網路請求（`java.ajax` 等）的超時（毫秒，下限 8 秒）；`concurrentRate` 做每源請求節流（SourceRateLimiter） |
| 書源類型 | `bookSourceType` 0=文字、1=聽書、2=漫畫，決定內容路由，不會因此改用 WebView 傳輸 |
| 章節 URL 帶選項 | `tag.a@href##$##,{"webView":true}` 這類「URL+選項」寫法支援（`chapterUrl`、`nextContentUrl`、`nextTocUrl`、`ruleContent.content` 為 URL 時） |

## 9. 書源壞掉的最常見 4 大原因

1. **JS 呼叫了白名單外的 API**（RSA／`java2js`／`sha256`／`gzipDecode`／檔案 API…）→ 調試日誌出現 `ERROR: UnsupportedLegadoAPIError` 或 `ERROR:`
2. **規則字串裡用了 `{{key}}` 等 URL 專用變數** → 得到空字串或 `undefined`
3. **用了 `{{js:…}}` 前綴** → JS 語法錯誤
4. **正則／JSONPath 用了 Java-only 語法** → 結果與 Legado 不同或為空

調試方法：把書源開進「調試規則」，逐段看日誌，`ERROR` 或「（空）」的那一段就是兇手。流程見[快速開始](quickstart.zh-Hant.md)。

## 下一步

- [常見症狀對照表](troubleshooting.zh-Hant.md) — 症狀 → 原因 → 解法