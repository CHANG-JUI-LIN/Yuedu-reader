# 与 Legado 的差异（书源为什么坏掉）

> 其他章节：[快速开始](quickstart.zh-Hans.md) · [规则语法速查](rule-syntax.zh-Hans.md) · [常见症状对照表](troubleshooting.zh-Hans.md)
> 繁體中文：[與 Legado 的差異](legado-differences.zh-Hant.md)

Yuedu 的书源格式与 Legado 3.0 完全相容，但**底层引擎不同**。多数书源可以直接用，少数依赖 Legado 特有 API 或语法的书源会失效。改书源之前，先看这一页——书源坏掉的主因 80% 集中在这里。

## 0. 一句话总结

| Legado | Yuedu |
| --- | --- |
| Rhino（Java）JavaScript 引擎 | JavaScriptCore（Safari 同款） |
| jsoup HTML 解析 | SwiftSoup（jsoup 相容实现） |
| Java 正则引擎 | ICU 正则引擎（近亲，细节不同） |
| Jayway JSONPath | 自实现 JSONPath |
| JsoupXpath | libxml2 XPath 1.0 |

**最大风险是 JS**：Legado 书源会调用 Android／Java API，Yuedu 用一个 `java.*` 相容层承接，**有一个白名单**——白名单外的调用会直接报 `ERROR`。书源在两端行为不同，九成是 JS 用了白名单外的东西。

## 1. `java.*` API 对照

### 已支持（可直接使用）

| API | 说明 |
| --- | --- |
| `java.ajax(url)`、`java.ajaxAll([urls])` | 网络请求；`ajaxAll` 回传数组（取内容用 `.body()`） |
| `java.get(url, headers)`、`java.post(url, body, headers)` | 带标头的请求 |
| `java.get(变量名)` | **单参数**＝读取先前存的变量（双参数才是 HTTP GET） |
| `java.getString(rule)`、`java.getStringList(rule)`、`java.getElements(rule)`、`java.setContent(content, baseUrl)` | 在 JS 内再跑一条规则 |
| `java.base64Encode(s)`、`java.base64Decode(s)`、`java.base64DecodeToByteArray(s)` | Base64 |
| `java.md5Encode(s)`、`java.md5Encode16(s)` | MD5（32 位小写 hex／中间 16 位） |
| `java.HMacBase64(content, "SHA1|SHA256|SHA384|SHA512", key)` | HMAC，回传 Base64 字符串 |
| `java.aesEncryptHex(transformation, keyHex, ivHex, dataHex)`、`java.aesDecryptHex(...)` | AES/DES/3DES 加解密（hex 进出）——仅支持 ECB/CBC + PKCS5/PKCS7/NoPadding，其他组合回传空字符串 |
| `java.createSymmetricCrypto(...)`、`java.aesBase64Decode(...)`、`java.aesBase64DecodeToString(...)` | hutool 风格 AES 工具 |
| `java.hexEncodeToString(s)`、`java.hexDecodeToString(s)` | hex 编码／解码 |
| `java.encodeURI(s)`、`java.encodeURIComponent(s)` | URI 编码 |
| `java.htmlFormat(s)` | HTML entity 解码 |
| `java.t2s(s)`、`java.s2t(s)` | 繁简转换 |
| `java.timeFormat(ts)`、`java.timeFormatUTC(ts)` | 时间戳格式化 |
| `java.getCookie(url)`、`java.getCookie(url, key)` | 读 cookie（写入请用 `cookie.set`，见下） |
| `java.androidId()`、`java.deviceID()` | 设备识别码。注意：**不是真 ANDROID_ID**，是一串 16 位小写 hex（SHA256 派生），细节见下方说明 |
| `java.startBrowser(url)`、`java.startBrowserAwait(url)` | 开内置浏览器（等待返回）；`java.webView(url)` 是**无头** WebView（载入后把 cookie 存下来，不提供互动） |
| `java.log(msg)`、`java.toast(msg)`、`java.longToast(msg)` | 调试输出／提示（`log` 会进「网络日志」） |
| `java.importScript(url)` | 引入远端 JS |
| `java.searchBook(name)`、`java.open(url, "search")` | 交棒到搜索（其他 target 无动作） |
| `java.setResponseBase64(b64)` | 设定响应内容（TTS 登录检查用） |
| `java.upLoginData(url)`、`java.reLoginView()` | 登录流程 |
| `java.axja(code)` | aaencode 混淆解码 |
| `java.utf8ToGbk` — **没有**（见下方清单） | — |

### 不存在／缺损（书源报 `ERROR` 的来源）

以下 Legado API **没有对应实现**，调用即失败：

| Legado API | 状态 | 替代方案 |
| --- | --- | --- |
| `java2js` | 不存在 | 直接写 JS |
| `java.appVersion` | 不存在 | 自己写死版本字符串 |
| `java.sha1`、`java.sha256`（单独函数） | 不存在 | `java.HMacBase64(x, "SHA256", key)` 或改用其他签名 |
| `java.md5` | 不存在 | 用 `java.md5Encode`（名称不同！） |
| `java.rsa…`／RSA 加解密 | 整个 RSA 不存在 | 无替代，此类书源无法使用 |
| `java.gzipDecode`／gzip 工具 | 不存在 | 无替代 |
| `java.downloadFile` | 不存在 | 无替代 |
| `java.queryTTF`／`queryBase64TTF`／`replaceFont` | 不存在 | 无替代 |
| `java.getZipStringContent`／`getZipByteArrayContent` | 不存在 | 无替代 |
| `java.utf8ToGbk` | 不存在 | 需要 GBK 时在 URL 选项设 `"charset":"gbk"` |
| `java.getFile`／`readFile`／`readTxtFile`／`unzipFile`／`getTxtInFolder` | 不存在 | 无替代（本地文件 API） |
| `java.aesDecodeToByteArray`／`aesDecodeToString`／`aesEncodeToBase64…` | 名称不同 | 用 `java.aesDecryptHex`／`aesEncryptHex`／`aesBase64Decode` |
| `java.qread()` | **刻意 no-op** | 回传空、不报错。依赖它的书源会静默失败而非报 ERROR |
| `java.copyText` | stub（不实际复制） | — |
| `java.refreshExplore`／`refreshBookInfo`／`refreshBookToc`／`refreshContent` | no-op | — |
| `java.openVideoPlayer` | 退化成开浏览器 | — |

另外一个容易踩的：**`java.get` 的单参数／双参数歧义**。Legado 靠 Java 多载，Yuedu 用参数数量分派：单参数＝读变量，双参数＝HTTP GET。调用前数清楚参数个数。

## 2. `Packages.*` 与 Java 类白名单

书源 JS 常直接 import Java 类（`importClass(Packages.java.security.MessageDigest)` 等）。Yuedu **只注册了以下类**，白名单外的 `new`／调用会抛 `UnsupportedLegadoAPIError`（调试日志会看到 `ERROR:`）：

```
java.lang.String（含 getBytes）、java.lang.System（nanoTime/currentTimeMillis）
java.util：HashMap、LinkedHashMap、TreeMap、Hashtable、Properties、
           ArrayList、LinkedList、Vector、Arrays（copyOfRange）、Base64、UUID（randomUUID）
android.util.Base64（DEFAULT/NO_PADDING/NO_WRAP/CRLF/URL_SAFE、encodeToString/decode）
javax.crypto.Cipher（走 AES hex 通道）、javax.crypto.spec.SecretKeySpec、IvParameterSpec
cn.hutool：DigestUtil.md5Hex、StrUtil.reverse、Base64.encode/decode
```

`org.jsoup.*` 也有 polyfill，但**有损**：`Element.first()/last()` 回 null、`Connection.Response.headers()` 回 null、`statusCode()` 恒为 200。依赖 jsoup 面向对象操作的书源请改用规则引擎本身的功能。

## 3. 模板变量的语义差异（最容易踩）

| 位置 | Legado | Yuedu（相同） | 差异 |
| --- | --- | --- | --- |
| 搜索/发现 URL | `{{key}}`、`{{page}}`、`{{pageIndex}}`、`{{header}}`、`{{JS}}` | ✅ 完全支持 | 无 |
| 章节/目录 URL | 同上 | ✅ 支持 | 无 |
| **规则字符串**（如 chapterName、content） | `{{弹性规则}}` | ✅ | `{{key}}` **不是变量**——规则字符串的 `{{…}}` 只认两种：`@`/`$.`/`$[`/`//` 开头＝嵌入规则，否则＝执行 JS，而 JS 绑定的变量只有 `baseUrl`/`baseURL`/`nextChapterUrl`/`src`/`result`。需要搜索词就提早用 URL 模板处理，别在规则字符串里用 `{{key}}` |
| `{{js:…}}` 前缀 | Legado 有 | **不支持** | 前缀不会被剥除，`{{js:foo()}}` 会被当成 JS 标签语句执行，行为不可预期。请直接把 `js:` 去掉写成 `{{foo()}}` |

`@put`／`@get`、`$1` 群组引用、`{$.字段}` 旧式 JSONPath 都与 Legado 一致。

## 4. Cookie

- 读：`java.getCookie(url[,key])`、`cookie.get(url)`、`cookie.getKey(url,key)`
- 写：`cookie.set(url, "k=v; k2=v2")`、`cookie.setCookie(...)`、`cookie.replaceCookie(...)`（合并语义）
- 删：`cookie.remove(url)`、`java.removeCookie(url)`
- **Cookie 罐永远启用**：书源的 `enabledCookieJar` 开关只是「承载并透明化」字段，没有实际作用——所有书源的 cookie 都会自动保存、自动带上。请求没带 Cookie 时，引擎会自动附上该域已存的 cookie。
- `loginCheckJs`：搜索取得 HTML 后执行，回传 true＝判定需要登录。搭配「登录页 URL」＋「Cookie 验证登录」使用。

## 5. 正则差异（ICU ≠ Java）

规则里的 `##正则##` 用 **ICU 正则**执行。Legado 书源常见的 Java-only 语法会自动做近似转换：

| Java 语法 | ICU | Yuedu 处理 |
| --- | --- | --- |
| `++`、`*+`、`?+`、`{n,m}+`（possessive） | 不支持 | 近似转成一般量词（语义不完全等价） |
| `(?>…)`（atomic group） | 不支持 | 近似转换（语义不完全等价） |
| `\R`、`\e` | 不支持 | 转换成等价写法 |
| `(?d)` flag | 不支持 | 剥除 |
| `\p{javaXxx}` 类 | 不支持 | 转译 |

使用注意：

- 每次正则执行有 **2 秒超时**：灾难性回溯的规则会直接回传原值（不会卡死，但等于没处理）
- 依赖 possessive／atomic 精确语义的书源可能出现「结果跟 Legado 差一点」的情况，属预期

## 6. JSONPath 差异

支持：点记法、括号记法、索引/切片（含负数）、`$..` 递归、过滤器（`== != < > <= >= =~`、`&&`、`||`、`!`）、多索引/多键、`length()`。

**不支持**：

- jayway 脚本表达式：`@.length()-1`、`@.price * 2` 这类运算
- `min()`/`max()`/`avg()` 等函数
- 过滤器比较时，运算符必须是 `== != <= >= < > =~` 其一（`=~` 是正则比对）

碰到就改写成规则链或 `<js>` 处理。

## 7. XPath 差异

- 通过 libxml2 提供**完整 XPath 1.0**：`|` 联合、轴（`following-sibling::` 等）、`[position()>1]`、`[text()="x"]` 都可用——这部分比 Legado 的 JsoupXpath 更标准
- **`!/` 前缀没有任何语义**：Legado 的 `!/`（取非？）在 Yuedu 不会被解释，等同查一条非法 XPath → 空结果。不要用
- `@xpath:` 以外的 `//…` 开头（含没有前缀的 `//`）会被正确路由到 XPath 模式

## 8. 其他注意事项

| 项目 | 说明 |
| --- | --- |
| HTML 大小上限 | 超过 **4 MB** 的网页会被截断再解析（防内存爆掉） |
| JS 执行 | JavaScriptCore；单次求值 30 秒超时，超时重置引擎；`eval()` 保留开启（Legado 混淆 jsLib 需要）；每段 JS 结果会自动处理 `result` 包装 |
| `setContent` | `java.setContent(content, baseUrl)` 可用，主路径照样执行 |
| Cloudflare 挑战 | 请求遇 403/503/429 且带 CF 特征时，会跳出人机验证页，通过后自动重试一次 |
| 段落缩排 | Legado 在 `replaceRegex` 后会自动每行补全形空格缩排，Yuedu **刻意不做**（可自行在替换规则加 `　　`） |
| `respondTime`／`concurrentRate` | `respondTime` 作为 JS 网络请求（`java.ajax` 等）的超时（毫秒，下限 8 秒）；`concurrentRate` 做每源请求节流 |
| 书源类型 | `bookSourceType` 0=文字、1=听书、2=漫画，决定内容路由，不会因此改用 WebView 传输 |
| 章节 URL 带选项 | `tag.a@href##$##,{"webView":true}` 这类「URL+选项」写法支持（`chapterUrl`、`nextContentUrl`、`nextTocUrl`、`ruleContent.content` 为 URL 时） |

## 9. 书源坏掉的最常见 4 大原因

1. **JS 调用了白名单外的 API**（RSA／`java2js`／`sha256`／`gzipDecode`／文件 API…）→ 调试日志出现 `ERROR: UnsupportedLegadoAPIError` 或 `ERROR:`
2. **规则字符串里用了 `{{key}}` 等 URL 专用变量** → 得到空字符串或 `undefined`
3. **用了 `{{js:…}}` 前缀** → JS 语法错误
4. **正则／JSONPath 用了 Java-only 语法** → 结果与 Legado 不同或为空

调试方法：把书源开进「调试规则」，逐段看日志，`ERROR` 或「（空）」的那一段就是凶手。流程见[快速开始](quickstart.zh-Hans.md)。

## 下一步

- [常见症状对照表](troubleshooting.zh-Hans.md) — 症状 → 原因 → 解法