# 书源规则语法速查

> 其他章节：[快速开始](quickstart.zh-Hans.md) · [与 Legado 的差异](legado-differences.zh-Hans.md) · [常见症状对照表](troubleshooting.zh-Hans.md)
> 繁體中文：[規則語法速查](rule-syntax.zh-Hant.md)

一条「规则」告诉 App 从抓回来的网页（HTML／JSON）里取出哪个资料。规则可以串接、可以套正则、可以执行 JS。本页是 Yuedu 规则引擎的语法速查，所有语法都与 Legado 3.0 相容。

> 说明：书源编辑器中各个字段的标签在 App 内固定显示繁体中文（不随系统语言变化），本页与下文使用 App 实际显示的标签名。

## 1. 规则模式与前缀

引擎依前缀自动判断规则的解析模式。前缀**大小写不敏感**：

| 前缀 | 模式 | 说明 |
| --- | --- | --- |
| （无前缀） | JSOUP Default | 跟随 Legado 的预设语法（`class.`/`tag.`/`id.`/`text.`…），或直接的 CSS 选择器 |
| `@css:` | CSS | SwiftSoup（jsoup 相容）CSS 选择器 |
| `@@` | CSS（强制） | 跟 Legado 一样，`@@` 开头强制用 CSS |
| `@xpath:`、`//…`、`/…` | XPath | XPath 1.0（libxml2） |
| `@json:`、`$.`、`$[` | JSONPath | 自实现 JSONPath，用于 JSON 响应 |
| `@js:`、`<js>…</js>` | JavaScript | 在 JavaScriptCore 执行，`result` 变量放上一段结果 |
| `##…##…##` | 正则 | 见下方「正则替换」 |

两个特殊前缀：

- 列表规则**首字符 `-`**：结果反序（目录倒序常用，如 `-tag.li`、`-:<li>…`）
- **`: ` 开头**（正则 AllInOne）：整段是正则，用于搜索列表、发现列表、详情预处理与目录列表；搭配 `$1`、`$2` 群组引用

规则内含 `$N` 群组引用或 `{{…}}` 模板时，该段会自动改用**正则模式**求值。

## 2. JSOUP Default 语法（无前缀）

Legado 经典写法，用 `@` 分隔一段段「选择步骤」，最后一段是取内容：

```
class.odd.0@tag.a.0@text
id.catalog@tag.li@tag.a@href
```

| 步骤 | 语法 | 示例 |
| --- | --- | --- |
| 选 class | `class.名称` | `class.booknav2`（多个 class 用空格，如 `class.a b`） |
| 选 id | `id.名称` | `id.content` |
| 选标签 | `tag.名称` | `tag.li`、`tag.a` |
| 依文字选 | `text.关键字` | `text.下一章`（`:containsOwn` 效果） |
| 子元素 | `children` | `head@children` |
| 位置 | `0`／`-1`／`!0:3` | `tag.a.0` 第一个、`tag.a.-1` 倒数第一个、`tag.dd.!0:3` 排除 0~3 |
| 数组记法 | `[索引]` | `tag.div[0]`、`tag.div[-1]`、`tag.div[0,2,5]`、`tag.div[!0:3]`、`tag.div[0:10:2]`、`tag.div[-1:0]`（反转） |

最后一段取内容（accessor）：

| 关键字 | 取回 |
| --- | --- |
| `@text` | 纯文字（`ownText` 只取自身文字、`@textNodes` 取所有文字节点） |
| `@html`（`@innerhtml`） | 元素内部 HTML（自动移除 script/style） |
| `@outherhtml` | 元素包含自身的 HTML |
| `@all` | 所有匹配元素的外层 HTML，用换行连接 |
| `@href`、`@src`、`@action` | 属性值，并**自动解析成绝对 URL** |
| `@class`、`@id`、`@title`、`@alt`、`@value`… | 任意属性名 |
| `@attr(xxx)` | 属性名有特殊字符时 |

## 3. CSS 规则

`@css:` 开头，支持 jsoup／SwiftSoup 的选择器，包括：`#id`、`.class`、`tag`、子代 `>`、后代（空格）、属性选择器（`[a=b]`、`[a^=x]`、`[a$=x]`、`[a*=x]`、`[a~=x]`、`[a!=b]`）、`:eq(n)`、`:lt(n)`、`:gt(n)`、`:first-child`、`:last-child`、`:nth-child(an+b)`、`:has(sel)`、`:not(sel)`、`:contains(text)`、`:containsOwn(text)`、`:matches(regex)`。

```
@css:.book-list li@text
@css:div[data-type="novel"] a@href
@css:#list li:has(a)@@a@text        ← @@ 链式：先选 #list li，再在每项内选 a
```

筛选结果再做第二层选择：`A@@B`＝在 A 的每个匹配内再选 B。

## 4. XPath 规则

`@xpath:`（或直接 `//` 开头）使用完整 XPath 1.0，支持 `|` 联合、轴（`following-sibling::`、`preceding-sibling::`、`ancestor::`…）、`[position()>1]` 等。取多个规则用 `||`/`&&`/`%%` 连接也行。

```
@xpath://div[@class='book']/h3/a/text()
//*[@id="content"]/p[1]/text()
//li[4]/a/text()||//li[5]/a/text()
```

`/@attr` 结尾直接取属性（会解析绝对 URL）；`text()`、`/html()` 结尾取文字／HTML。

## 5. JSONPath 规则

`@json:` 或 `$.`／`$[` 开头的规则对 **JSON 响应**求值（搜索结果是 JSON 的书源必用）：

```
$.info.Datas             ← 键路径
$['store']['book']       ← 括号记法
$..name                  ← 递归搜索
$[0]  $[-1]  $[0:3]      ← 索引／切片（支持负数）
$[?(@.price < 10)]       ← 过滤器（支持 == != < > <= >= =~ 与 && || !）
$[0,1]  $['a','b']       ← 多索引／多键
$.books.length()         ← 长度
```

不支持 jayway 的脚本表达式（如 `@.length()-1`、`min()/max()`）。挡掉的方法见[差异章节](legado-differences.zh-Hans.md)。

## 6. JavaScript 规则

`<js>…</js>` 可在规则链任意位置，也是规则段的**分隔符**；`@js:` 只能作为整条规则的最后一段。

```js
@css:.book@html<js>result.replace(/<a.*?a>/g,'')</js>
@css:.cover@src@js:result.replace('http','https')
```

JS 中的可用变量与函数（`result`、`baseUrl`、`src`、`book`、`chapter`、`java.xxx`…）请见[与 Legado 的差异](legado-differences.zh-Hans.md)的完整清单。

## 7. 串接与多规则

| 语法 | 作用 |
| --- | --- |
| `<js></js>` | 切分规则段，前段输出作为后段输入 |
| `||` | 多条规则取**第一个非空**结果 |
| `&&` | 多条规则结果**合并**（换行连接） |
| `%%` | 多条规则结果**逐位交错**（第 1 条的第 1 项、第 2 条的第 1 项…） |
| `@@` | CSS 链式选择器 |
| `##…##…##` | 正则替换（见下） |
| `@put:{…}` | 求值后写入变量（`@put:{bid:"//*[@bid-data]/@bid-data"}` 或 `@put:{key:value}`） |
| `@get:{key}` | 读出先前 `@put` 的变量 |

## 8. 正则替换（`##`）

三种形态，跟 Legado 完全一致：

| 形态 | 语法 | 用途 |
| --- | --- | --- |
| 净化 | `规则##正则##替换` | 跟在规则后面，对结果循环替换（去广告最常用）；替换内容可留空但**结尾的 `##` 不能省** |
| OnlyOne | `##正则##替换###` | 独立成条、只取并替换**第一个匹配**（详情页 meta 提取常用） |
| AllInOne | `:正则` 或 `-:正则` | 首字符 `:`；用群组取列表（`$1`、`$2`…） |

群组引用是 `$1`…（regex 模式时，规则含 `$N` 会自动切到正则模式）。

## 9. URL 模板与变量

搜索 URL、发现 URL、章节 URL、目录 URL 等「网址类」字段支持：

| 模板 | 值 |
| --- | --- |
| `{{key}}`、`{{searchKey}}` | 搜索关键字 |
| `{{page}}` | 页码（从 1 起） |
| `{{pageIndex}}` | 页码 - 1 |
| `{{header}}` | 书源请求头字符串 |
| `{{speakText}}`、`{{speakSpeed}}` | 朗读用（语音源） |
| `{{任意 JS 表达式}}` | 当 JS 执行，如 `{{(page-1)*20}}`、`{{java.base64Encode(key)}}` |
| `<值1,值2>` | 分页规则：page=1 取逗号前，page>1 取逗号后；`<,{{page}}>` 表示第一页留空 |
| `{$.字段}` | 2.0 旧式 JSONPath（仅 JSON 情境） |

GET 的完整形态；URL 后可接字面 JSON 选项，逗号分隔：

```
https://example.com/search?q={{key}},{"charset":"gbk"}
https://example.com/search,{"method":"POST","body":"key={{key}}&page={{page}}","charset":"gbk"}
```

支持的选项：`method`、`body`、`charset`（如 `"gbk"`）、`headers`、`webView`／`useWebView`（使用无头 WebView）、`webJs`、`bodyJs`、`webViewDelayTime`、`type`、`js`。请求头字段本身也可用 `<js>` 返回 JSON 字符串。`retry` 与 `serverID` 当前只会被解析以保持格式兼容，**不会自动重发或切换服务器**。

**规则字符串里**的 `{{…}}` 语义不同：`{{@…}}`、`{{$.…}}`、`{{//…}}` 开头＝嵌入另一条规则；其余＝当 JS 执行（可用的变量只有 `baseUrl`／`baseURL`／`nextChapterUrl`／`src`／`result`）。URL 专用的 `{{key}}` 在这里**不是**变量——需要搜索词时请在 URL 层面处理（如 `{{key}}` 放在搜索 URL），别在规则字符串里用。

### 9.1 正文图片点击与段评页

Legado 正文常在图片 URL 后附 `,{...}` 点击配置。Yuedu 支持 `click`、`action`，以及兼容分支使用的 `js` 键；点击时会在**原书源的同一个 session** 执行原始 JS，并恢复当时的 `book`、`chapter`、`result`、`src`、`baseUrl` 与非敏感运行变量。像 `showCmt(bookId, chapterId, paragraphId)` 这种参数不是 URL，App 不会自行猜测 API 路径。

来源调用 `java.showBrowser(baseUrl, html, preloadJS, configJSON)` 时，第四参数支持：

| 配置 | 说明 |
| --- | --- |
| `heightPercentage` | 展开高度，范围 0–1 |
| `skipCollapsed` | 跳过中等高度，直接使用展开高度 |
| `isHideable` | 是否允许下拉关闭 |
| `expandedCornersRadius` | 展开状态圆角，0–120 |
| `hardwareAccelerated` | 接受但不另行切换；WKWebView 本身使用加速合成 |

书源／登录浏览器会把 `java.copyText`、`navigator.clipboard.writeText` 与 `document.execCommand('copy')` 接到 iOS 系统剪贴板。

## 10. 字段对照：编辑器分页 ↔ Legado JSON 字段

App 的书源编辑器以「基本／搜索／发现／详情／目录／正文」六个分页对应 Legado JSON 的 `rule*` 对象，字段与 JSON 键一一对应（标签名 App 内固定繁体）：

| 编辑器分页 | 字段 | JSON 键 |
| --- | --- | --- |
| 基本 | 書源名稱／書源地址／書源分組／源註釋 | 同名顶层键 |
| 基本 | 登入頁 URL／登入 UI／登入檢查 JS | `loginUrl`／`loginUi`／`loginCheckJs` |
| 基本 | 封面解密、書籍 URL 正則、請求頭、變量說明、並發率、jsLib | `coverDecodeJs`／`bookUrlPattern`／`header`／`variableComment`／`concurrentRate`／`jsLib` |
| 搜索 | 搜索 URL、校驗關鍵字 | `searchUrl`、`ruleSearch.checkKeyWord` |
| 搜索／发现 | 書籍列表／書名／作者／分類／字數／最新章節／簡介／封面／詳情頁 URL／更新時間 | `ruleSearch`、`ruleExplore` 内同名键 |
| 发现 | 發現地址規則 | `exploreUrl` |
| 详情 | 預處理規則 | `ruleBookInfo.init` |
| 详情 | 書名／作者／分類／字數／最新章節／簡介／封面／目錄 URL／允許修改書名作者／下載 URL／聽書骰子 | `ruleBookInfo` 内同名键（目錄 URL＝`tocUrl`） |
| 目录 | 更新之前 JS | `ruleToc.preUpdateJs` |
| 目录 | 章節列表／章節名稱／章節 URL／格式化／卷標識／章節信息／VIP 標識／購買標識／目錄下一頁 | `ruleToc` 内同名键 |
| 正文 | 正文規則／章節名稱／正文下一頁 URL／WebView JS／資源正則／替換規則／圖片樣式／圖片解密／購買操作 | `ruleContent` 内同名键 |

> 注：导入的 JSON 偶尔会是「整段字符串化」的（如 `"ruleSearch": "{...}"`），App 会自动解开，不需手动处理。

## 11. 常用可复制范例

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

- [与 Legado 的差异](legado-differences.zh-Hans.md) — 哪些语法在 Yuedu 行为不同或不存在
- [常见症状对照表](troubleshooting.zh-Hans.md) — 书源坏掉时对照症状找解法
