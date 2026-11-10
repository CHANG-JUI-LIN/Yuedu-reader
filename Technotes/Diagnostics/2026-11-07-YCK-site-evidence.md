# YCK 精校源：網站端失敗的證據（2026-11-07）

目標：1330 ≥ 700/794、1331 ≥ 417/463、1329 ≥ 288/320。只有網站確實壞掉（或需要登入、
反機器人牆、網站已改版而規則在 Legado 也一樣失敗）才算不可修；其餘一律修適配。

每一筆都是從本機（台灣網路）直接請求的結果；`curl` 用該源自己的 header／UA。
「連不上」（TCP／DNS）不算證據——可能只是本機網路到不了，下表不收。

## 1330（索引＝pack 陣列位置）

| # | 源 | 證據 | 類別 |
|---|----|------|------|
| 2 | 📂顶点小说xsbook | 搜尋頁 `/search7b.html` 404，首頁 403 | 網站壞 |
| 9 | ⚡📂笔趣全家桶（m.xzdzn.com） | nginx 403，首頁也 403 | 網站擋 |
| 17 | 📂58小说网（m.xbfdc.net） | nginx 403，首頁也 403 | 網站擋 |
| 19 | 🔞🎬黄区（鏡像 zwtoacvqie3.hq777.icu） | TCP 443 連得上，送出 TLS Client hello 後 15 秒、40 秒都沒有 Server hello；鏡像網址寫死在 `jsLib` 的 `HQ_HOST`，主站 huangqu.top 回 403 | 網站壞（TLS 無回應） |
| 20 | 📂玄幻文学（m.xhwx8.com） | 正文規則自己的 `##` 正則把第一章整段正文刪光，只剩空字串；Legado 照同一條規則也一樣是空 | 源本身 |
| 26 | 🔞艾利浩斯学院（alhs.xyz） | 404「暂时无法打开此页面」 | 網站壞 |
| 42 | 📂种田小说（m.zhongtianwen.cn） | 正文頁回登入牆 | 需登入 |
| 50 | ⚡📂书城免费小说（wzyjxf） | API 回 `{"request_id":"mock",…,"data":{}}`，帶或不帶源的 header 都一樣 | 網站壞 |
| 55 | 🔞肉文屋（m.rouwenwu14.com） | 搜「我的」（Legado 預設的檢查詞，源沒設 `checkKeyWord`）時網站回 PHP Warning「Query execution was interrupted, maximum statement execution time exceeded」，沒有結果；換「赌」有 46 筆。發現、詳情、目錄、正文都通過 | 網站壞（搜尋逾時） |
| 58 | 🏷 起点小说 | 騰訊 EdgeOne WAF 挑戰頁（HTTP 202，186 位元組，載入 95 KB 混淆的 `probe.js` VM 後才設 cookie 重新載入）。源用 `webView:true`；我們的 WebView 跟 Legado `BackstageWebView` 一樣在頁面載完 1 秒後讀 HTML，讀到的是挑戰頁。不去繞反機器人牆 | 反機器人 |
| 70 | 📂神文小说（shenwen.org） | 目錄規則開頭 `-` 反轉後第一章是一頁純文字的最後一章，頁面沒有規則要的 `qsbs.bb`；Legado 的順序一樣，選到同一章 | 網站改版 |
| 76 | 🎨漫画团（manhuatuan.com） | 網站現在把 `params` 做 JS 字串跳脫（含 `\/`），源把它交給 `java.base64Decode`，Java 的 Base64 遇到 `\` 一樣丟例外 | 網站改版 |
| 84 | ⚡📂思路客（szndz） | Cloudflare「Attention Required」403 | 反機器人 |
| 92 | 📷🎨🔞三四娱乐（3004gg） | Cloudflare「Just a moment」 | 反機器人 |
| 107 | 🏷微信读书二合一本地源 | 搜尋 JS `wrCredentials` 直接丟「缺少 APP 登录参数」；Legado 一樣 | 需登入 |
| 109 | 🏷晋江 | 規則讀 `JSON.parse(source.getLoginHeader())[e]`；沒登入時 `getLoginHeader()` 是 null，Legado 一樣丟 TypeError | 需登入 |
| 113 | 🎭🎬露西弗同人站（newlucifer） | 回 `token.len应该大于或等于32` | 需登入 |
| 114 | 🎭🎬露西弗俱乐部 | 登入頁 | 需登入 |
| 116 | 🎨🔞漫蛙（manwa.me） | 各頁 404 | 網站壞 |
| 123 | 🎨🔞禁漫天堂（jmcomicui.net） | 404，只剩發布頁 | 網站壞 |
| 128 | 📘幻梦轻小说（huanmengacg） | Cloudflare「Just a moment」 | 反機器人 |
| 132 | ⚡📂盗版顶点（daislou） | API 回 `{"request_id":"mock",…,"data":{}}` | 網站壞 |
| 141 | ⚡📂久久小说（23fgh） | 網站改版成 `div#post-…`，規則 `ul@li` 在 Legado 也選不到 | 網站改版 |
| 148 | 📂🔐完本神站（sososhu） | 回「需要登录」 | 需登入 |
| 162 | 📂盗墓笔记（daomubiji） | `searchUrl` 是 `-`，Legado 一樣失敗 | 源本身 |
| 167 | 📂阅宝书屋（yuezibaomush1） | Cloudflare「Just a moment」 | 反機器人 |

不是證據、已排除的：
- 143 🔊书音M、157 ⚡📂全本小说：「我的」沒結果是關鍵字問題，發現正常——不是網站壞。
- 30 ⚡📂笔趣阁（biquge.company）：時好時壞，診斷重跑時五項全過。
- 129 📂一笔阁（m.yibige.org）：原本記成反機器人。它的「访问验证」頁由源自己的
  `loginCheckJs` 處理（`java.connect(source.key + java.ruleUrl)`），失敗是因為我們的
  `java.ruleUrl` 是 `undefined`（請求變成 `m.yibige.orgundefined`）——是我們的缺口，
  11-07 已補（`LegadoAnalyzeUrlScriptView`）。

## 1331（索引＝pack 陣列位置；診斷批次 d1）

台灣本機是 App 的診斷紀錄（`BookSourceDiagnosticDumpTests`），香港是主機上 `curl` 同一網址、同一 UA。

| # | 源 | 證據 | 類別 |
|---|----|------|------|
| 0 | 墨辰整理书源系列7.5版 | 沒有書源網址，`<meta>` 指向 bilibili 的說明頁，不是書源 | 源本身 |
| 9 | 蓝批小说（pixiv） | 發現讀 `pixivCookie.match(…)`，沒登入時是 null；`follow_latest` 回 `{"error":true}` | 需登入 |
| 16, 19, 83, 103, 170, 176 | 轻之文库、神凑轻说、沱书文存、国学经典、神凑轻说（m.）、秋风书屋 | Cloudflare「Just a moment」挑戰頁 | 反機器人 |
| 18 | 白羽轻说（xiaoxiaoshuo8） | 搜尋走 `m.` 站、書頁連結是相對的 `/0_120/`，Legado 也解析到 `m.` 站；`m.` 書頁（Legado 桌面 UA，香港 6225 B）沒有目錄規則要的 `div#wrapper > div.box_con`，那是 `www.` 站的版面。發現走 `www.` 正常 | 網站改版 |
| 21 | 异轻纵然（esjzone） | 第一個有網址的發現分類是「我的收藏」`/my/favorite`，回 `window.location.href='/my/login'`；Legado 檢查也取第一個有網址的分類 | 需登入 |
| 25 | 得间小说 | 騰訊 EdgeOne WAF 挑戰頁（HTTP 202 + `probe.js`） | 反機器人 |
| 32 | 得奇小说 | 搜尋結果改成 `.item`，規則要 `.bookbox` | 網站改版 |
| 36, 38, 39, 139 | 速读谷子×3、天天书吧 | HTTP 500 | 網站壞 |
| 41 | 错层小说 | 目錄頁回 `<ApiError><code>swq-003</code><message>书籍目录页访问次数受限制，请60秒后重试。` 400。同 pack 的 #40 也是 cuoceng，稽核並發時兩個一起打；香港單獨請求同一網址、同一組 header 回 200 | 網站限頻（單獨跑會過） |
| 42, 43, 44, 57 | 可乐小说×3、爱书库子 | 搜尋要 rrssk.com 的 `signJs` 簽名；`window.__SIGN.f` 在 `_ab1615!==1` 時回 `00000000`，而 `_ab1615` 只在 `isTrusted` 的 pointerdown／touchstart／keydown／mousedown 事件裡設成 1——要真人操作，背景 WebView（Legado 的 `BackstageWebView` 也一樣）永遠拿不到簽名。香港主機被 rrssk 直接 403 | 反機器人（要真人輸入） |
| 45, 46 | 笔趣全桶×2 | nginx 403 | 網站擋 |
| 54, 55 | 猫眼看书×2 | API 回 `request_id: mock` 的空資料 | 網站壞 |
| 59 | 黑白中文 | 搜尋頁 Cloudflare 挑戰（`cf-mitigated: challenge`，香港也是）；源的 `loginCheckJs` 呼叫 `startBrowserAwait` 要人去過 | 反機器人 |
| 63 | 西瓜免费 | API 回「接口鉴权不合法」 | 網站壞 |
| 68 | 安分短文（asianfanfics） | 正文頁 Cloudflare「Just a moment」（香港 403） | 反機器人 |
| 73, 80, 146 | 二八看书、皮皮小说、百合爱会 | 登入牆 | 需登入 |
| 74 | 八零小说 | 301 搬到新網域，POST 內容被丟掉；新網域直接帶關鍵字也回空 | 網站改版 |
| 81 | 话本小说 | 回 `{}`，源寫死的 token 已過期 | 網站改版 |
| 86, 140 | 馊虎系列、零点文学 | GoEdge WAF 驗證碼頁 | 反機器人 |
| 93 | 抖趣小说 | 網站回「关键字最少 10 个字符」 | 網站限制 |
| 106 | 古龙武侠 | 書頁 `http`→301→`https`，兩地都是 IIS「403 - 禁止访问: 访问被拒绝」 | 網站擋 |
| 115, 116 | 古诗文网×2 | 頁面只剩 JS 轉址 | 網站改版 |
| 138 | 五二书库（52shuku） | 正文規則 `#nr1@html`；網站正文現在在 `article.article-content`，頁面沒有 `#nr1`（UA 跟源 header 相同） | 網站改版 |
| 158, 159 | 狸猫故事×2 | 503「访问限制」 | 網站擋 |
| 160 | 思路客子（isiluke） | 書頁從台灣本機是 Cloudflare「Just a moment」403；香港 200——Cloudflare 依來源 IP 挑戰 | 反機器人 |
| 164 | 爱去小说 | 404 | 網站壞 |
| 179 | 七百小说 | `webView` 搜尋落在一個很小的導向頁，沒有結果 | 網站改版 |
| 245 | 蓝批漫画（pixiv） | 規則本身的錯（同 #9 的登入前提） | 源本身 |

d1 這批查出的我們的缺口（11-07 已補）：#13 拷贝轻说（不送 `Accept`）、#144 福书网吧（頁面宣告的
編碼優先於 `charset` 選項）、#155 精品小说（`headers(name)`）、#56 三爱小说（`loginCheckJs` 每次一個
作用域）、#60 台湾小说（`result.body.call(result)`）、#66 黄金书屋（正文續頁的 404 照樣解析）。

## 兩地都連不上（台灣本機＋香港主機 43.129.29.13，2026-11-07）

探測只連來源網址的首頁（DNS → TCP → TLS → GET /，各 12–20 秒；腳本 `probe_sites.py`，原始結果在
`/tmp/yuedu-yck1330/run-1107/`，不進 repo）。只收稽核失敗訊息也是網路錯誤的源
（逾時、連線失敗、找不到主機、憑證、HTTP 錯誤、空正文）；API 另有主機而有回應的不收，那些照常修。
「憑證無效」單獨標出：Legado 的 OkHttp 信任所有憑證，這些在 Legado 能連；我們依 11-06 決定維持系統驗證。

### 1329（100 個：網站連不上 89、憑證無效 11）

| # | 源 | 主機 | 台灣 | 香港 | 稽核訊息 | 類別 |
|---|----|------|------|------|----------|------|
| 3 | 🔞🎨天脉漫画 | www.tnmm.cc | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 4 | 🔞爱丽丝书屋 | xn--vcsx64d.alicesw12.xyz | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「xn--vcsx64d.alicesw12.xyz」 | 憑證無效 |
| 7 | 🎨七七漫画 | hqqh.cc | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 8 | 🎨新新漫画 | www.xxim.cc | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 13 | ⚡📂醉读小说 | www.imaxreader.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 14 | ⚡📂香书小说 | www.ibiqugu.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 16 | 🎨漫画台💓 | m.manhuatai.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.manhuatai.com」的伺服器，並且可能會 | 憑證無效 |
| 17 | 📂阁笔趣网 | www.gashuw.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 18 | 📂爱书包 | www.shubaoge.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 27 | ⚡📂蚂蚁文学 | www.mayiwsk.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.mayiwsk.info/modules/ | 網站連不上 |
| 32 | 📂达文小说 | www.dawenks.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.dawenks.com/search.ph | 網站連不上 |
| 36 | ⚡📂笔趣阁 | www.biqugere.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 40 | ⚡📂若雨中文 | www.3yt.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 41 | ⚡📂笔趣阁 | m.xbiqukun.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 44 | ⚡📂9559小说 | www.95590.org | HTTP 無回應 | HTTP 無回應 | 網路連線中斷。  | 網站連不上 |
| 45 | ⚡📂小说网 | www.shukuge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 46 | ⚡📂键盘小说 | www.janpn.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 47 | ⚡📂鬼吹灯 | www.gdbzkz.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 49 | 📂三九小说 | www.sanjiusk.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 50 | ⚡📂亿软小说 | m.iyruan.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 53 | ⚡📂神藏小说 | www.swangwx.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 61 | 📂八一中文 | www.81shuku.info | TCP 連不上 | TCP 連不上 | 無法找到指定主機名稱的伺服器。 連線失敗 · www.81shuku.info | 網站連不上 |
| 62 | 📂三五文学 | www.35wx.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.35wx.info/modules/art | 網站連不上 |
| 67 | ⚡📂玄幻阁吧 | www.xuanhuange.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 76 | ⚡📂永恒小说 | wap.4pan.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.4pan.org/s.php · 連線逾時 | 網站連不上 |
| 81 | ⚡📂悠久小说 | www.ujxsw.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 82 | ⚡📂必去网站 | www.ibiquw.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 84 | 📂️帝书阁 | m.xdishuge.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.xdishuge.org/search/ ·  | 網站連不上 |
| 87 | 📂雨鹿小说 | novel.yulu.local | DNS 查無 | DNS 查無 | 搜尋Fetched empty content  | 網站連不上 |
| 88 | ⚡📂必去吧楼 | m.bequ6.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 90 | ⚡📂笔趣阁 | m.biqusk.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 98 | ⚡📂手机小说 | www.sjshuku.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 101 | 📂女生文学 | www.xwenxuem.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 110 | ⚡📂就爱文学 | www.92xs.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.92xs.info/modules/art | 網站連不上 |
| 111 | ⚡📂平凡文学 | www.pksge.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 121 | ⚡📂文UU小说网 | m.uuwx.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.uuwx.la/search.php · 連線 | 網站連不上 |
| 123 | 📂美艺言情小说书馆 | m.meiyeewk.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.meiyeewk.com/search.php | 網站連不上 |
| 130 | ⚡📂未来天王 | www.weilaitianwang.info | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 134 | 📂人人小说 | apk.renrenapi.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 135 | ⚡📂阴阳代理 | www.xyinyangdailiren.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 136 | ⚡📂武道文学 | www.bookwenxue.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 154 | 📂爱笔楼 | m.biqutu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 160 | ⚡📂4电子书 | www.4020xs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 163 | 📂️三叉小说 | m.xxxbiquge.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.xxxbiquge.net · 連線逾時 | 網站連不上 |
| 166 | 🌸爱丽丝书屋(免翻) | xn--vcsx64d.alicesw12.xyz | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「xn--vcsx64d.alicesw12.xyz」 | 憑證無效 |
| 167 | ⚡📂飘天文学 | m.piaotianwxz.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.piaotianwxz.com/so/ · 連 | 網站連不上 |
| 169 | 📂云中书库 | www.yunxs.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 171 | 📂鸟书网 | wap.99wx.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.99wx.info/search.php  | 網站連不上 |
| 174 | 最终小说网 | www.zuizhong.net | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.zuizhong.net/ · 連線逾時 | 網站連不上 |
| 187 | 📂飘天文学手机版 | m.ptwxz.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.ptwxz.org/so/ · 連線逾時 | 網站連不上 |
| 189 | ⚡📂️快眼小说 | www.kyxsw.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 194 | ⚡📂大帝小书库 | www.aikushuge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 198 | ⚡📂键盘小说 | www.janpn.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.janpn.org/search.php  | 網站連不上 |
| 200 | ⚡📂民国奇人 | www.minguoqiren.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 202 | ⚡📂无双小说 | www.buxia.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.buxia.la/modules/arti | 網站連不上 |
| 205 | 📂八一中文 | www.wangshuwx.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 207 | ⚡📂火高小说 | www.00shu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 212 | 📂️绾书文学 | api.wanshu.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 216 | ⚡📂️读趣网站 | www.xduqu.com | TCP 連不上 | TCP 連不上 | 無法找到指定主機名稱的伺服器。 連線失敗 · www.xduqu.com | 網站連不上 |
| 218 | ⚡📂️唐三中文 | www.xtangsanshu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 219 | ⚡📂梦幻小说 | www.pan5.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 222 | 📂K小说 | www.2kzw.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 223 | 📂梦书中文 | www.mcxs.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 225 | 📂书出荒慌 | m.shuhuanghuang.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 229 | ⚡📂幻影小说网 | www.huiysj.com | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.huiysj.com/search.htm | 網站連不上 |
| 233 | 📂五五读书 | www.changduge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 238 | 📂被电子书 | www.iwurexs.info | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.iwurexs.info」的伺服器，並且可能 | 網站連不上 |
| 243 | 📂九五看书 | www.95ks.org | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.95ks.org/search.html  | 網站連不上 |
| 245 | 📂夜读居网 | www.yeduju.com | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.yeduju.com/search.htm | 網站連不上 |
| 250 | ⚡📂笔趣阁 | www.xbiquge.la | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.xbiquge.la」的伺服器，並且可能會對 | 網站連不上 |
| 251 | 📂小说阅读 | www.xiaoshuoge.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 252 | ⚡📂思路客# | www.shuqusk.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.shuqusk.net/modules/a | 網站連不上 |
| 255 | 📂️醉读小说️# | wap.maxreader.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 259 | 📂橘子小说 | www.shugelou.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 261 | ⚡📂笔趣阁 | www.tianxiabachang.cn | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.tianxiabachang.cn/cse | 網站連不上 |
| 262 | ⚡📂全本小说 | www.xs5300.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 265 | 📂爱看书/零点小说#书源.com | www.lingdxsw.org | HTTP 無回應 | HTTP 無回應 | 網路連線中斷。  | 網站連不上 |
| 267 | ⚡📂丁丁小说 | www.idingdiange.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 268 | 📂明月小说 | wap.kanxs.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.kanxs.info/s.php · 連線 | 網站連不上 |
| 272 | 📂明月小说 | wap.aishuge.org | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「wap.aishuge.org」的伺服器，並且可能會 | 網站連不上 |
| 277 | ⚡📂️笔下文学 | www.duquxs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 278 | ⚡📂键盘小说 | www.jianpan.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 280 | ⚡📂笔趣阁 | www.ibiquge.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 284 | ⚡📂笔趣阁 | www.biqusa.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 289 | ⚡📂黄易小说[hy] | www.huangyixiaoshuo.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.huangyixiaoshuo.la/in | 網站連不上 |
| 292 | ⚡📂黑岩阅读 | www.xheiyan.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 295 | ⚡📂爱笔趣阁 | www.ibiquges.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 300 | 看书网 | www.kanzh.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 302 | 神漫画 | m.taomanhua.com已整理 | DNS 查無 | DNS 查無 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.taomanhua.com」的伺服器，並且可能會 | 網站連不上 |
| 303 | ㊣ 绾书文学 1101 | api.wanshu.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 306 | 爱优漫吧 | m.iyouman.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.iyouman.com」的伺服器，並且可能會對你 | 憑證無效 |
| 308 | 绾书文学 | api.wanshu.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 309 | 神漫画网 | m.taomanhua.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.taomanhua.com」的伺服器，並且可能會 | 憑證無效 |
| 311 | 爱优漫 | m.iyouman.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.iyouman.com」的伺服器，並且可能會對你 | 憑證無效 |
| 313 | 爱优漫吧 | m.iyouman.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.iyouman.com」的伺服器，並且可能會對你 | 憑證無效 |
| 314 | ㊣ 绾书文学  | api.wanshu.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 315 | ✐ 神漫画 | m.taomanhua.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.taomanhua.com」的伺服器，並且可能會 | 憑證無效 |
| 316 | 神漫画  | m.taomanhua.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.taomanhua.com」的伺服器，並且可能會 | 憑證無效 |
| 317 | 🎨 爱优漫 | m.iyouman.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.iyouman.com」的伺服器，並且可能會對你 | 憑證無效 |
| 318 | 神漫画 | m.taomanhua.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.taomanhua.com」的伺服器，並且可能會 | 憑證無效 |

### 1331（46 個：網站連不上 39、憑證無效 7）

| # | 源 | 主機 | 台灣 | 香港 | 稽核訊息 | 類別 |
|---|----|------|------|------|----------|------|
| 24 | 梦幻小说（优+++） | www.pan5.net* | DNS 查無 | DNS 查無 | 要求逾時。  | 網站連不上 |
| 52 | 篱笆文学（优+++） | m.libahao2.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 53 | 篱笆文学（优+++） | m.libahao.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 61 | 越网小说（优+++） | www.sjwx.la | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 76 | 追书大师（优++） | s.pjxhmy.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 90 | 纸间阅读（优++） | www.zjread.cc | 5xx | 5xx | Error: 站点错误 503：網站維護中  | 網站連不上 |
| 94 | 影书文学（优++） | www.yingsx.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.yingsx.com/cse/search | 網站連不上 |
| 96 | 爱下电子（优++） | apiv2hans.aixdzs.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「apiv2hans.aixdzs.com」的伺服器， | 憑證無效 |
| 117 | 小说网吧（优+） | www.shukuge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 122 | 有度中文（优+） | www.yodu.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 125 | 天域小说（优+） | www.tycqzw.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 126 | 天域小说（优+） | www.zmccx.com | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.zmccx.com」的伺服器，並且可能會對你 | 網站連不上 |
| 127 | 天域小说️（优+） | www.tycqzw.net | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 128 | 天域小说（优+） | www.tycqzw.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 129 | 天域小说（优+） | www.tycqzw.la | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.tycqzw.la」的伺服器，並且可能會對你 | 網站連不上 |
| 131 | 笔趣阁子（优+） | www.yingsx.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.yingsx.com/cse/search | 網站連不上 |
| 133 | 新电子书（优+） | www.iwurexs.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 134 | 晚班小说（优+） | www.99mk.info | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 135 | 丁丁小说（优+） | api.xingliangglobal.com | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 137 | 黄易天地（优+） | www.xhytd.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.xhytd.com/search.html | 網站連不上 |
| 142 | 悠久小说（优+） | wap.ujxsw.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.ujxsw.org/searchbooks | 網站連不上 |
| 143 | 蚂蚁文学（优+） | m.mayiwsk.com | HTTP 無回應 | HTTP 無回應 | Request timed out 連線失敗 · m.mayiwsk.com/s.php · 連線逾 | 網站連不上 |
| 147 | 宝来小说（优+） | m.xinbaolaixsw.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.xinbaolaixsw.com · 連線逾時 | 網站連不上 |
| 148 | 蚂蚁阅读（优+） | www.mayitxt.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 149 | ️达文小说（优+） | wap.dawensk.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.dawensk.com/s.php · 連 | 網站連不上 |
| 152 | 全本小说（优+） | www.jwdushu.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 154 | 笔架公站（优+） | www.xbiquge.laa | DNS 查無 | DNS 查無 | 要求逾時。  | 網站連不上 |
| 157 | 新电子书（优+） | www.wurexs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 163 | 阅读库子（优+） | www.yuedsk.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 174 | 有度中文（优+） | www.yodu.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.yodu.org/sa · 連線逾時 | 網站連不上 |
| 192 | 文桑小说（优） | www.wensang.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 199 | 就爱文学（优） | www.92xs.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.92xs.info/modules/art | 網站連不上 |
| 201 | 零零小说（优） | www.00shu.la | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 213 | 双零电子（优） | www.wrlwx.com | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 218 | 阅读书库（优） | www.yeudusk.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 220 | 歌书网吧（优） | www.gashuw.com | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 229 | 爱去小说（导） | www.aiqu999.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.aiqu999.com」的伺服器，並且可能會 | 憑證無效 |
| 248 | 爱看漫画（优+++） | www.0592cr.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.0592cr.com」的伺服器，並且可能會對 | 憑證無效 |
| 266 | 爱优漫吧（优+） | m.iyouman.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.iyouman.com」的伺服器，並且可能會對你 | 憑證無效 |
| 267 | 爱优漫吧（优+） | m.iyouman.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「m.iyouman.com」的伺服器，並且可能會對你 | 憑證無效 |
| 303 | 猫耳有声（优+） | www.hhlqilongzhu.cn | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.hhlqilongzhu.cn」的伺服器，並 | 憑證無效 |
| 306 | 猫耳广播（优+） | www.hhlqilongzhu.cn | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.hhlqilongzhu.cn」的伺服器，並 | 憑證無效 |
| 372 | 起点小说（优++） | xdian.com | DNS 查無 | DNS 查無 | 搜尋Fetched empty content  | 網站連不上 |
| 377 | 起点小说（优++） | 7xdian.com | DNS 查無 | DNS 查無 | 搜尋Fetched empty content  | 網站連不上 |
| 409 | 纵横中文（优+） | m.zongheng.com | 5xx | 5xx | Request timed out 連線失敗 · m.zongheng.com/search · 連 | 網站連不上 |
| 440 | 经致文学（优） | www.jingzhi5.com | TCP 連不上 | HTTP 無回應 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |

### 1330（143 個：網站連不上 137、憑證無效 6）

| # | 源 | 主機 | 台灣 | 香港 | 稽核訊息 | 類別 |
|---|----|------|------|------|----------|------|
| 49 | ⚡📂醉读小说 | www.imaxreader.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 51 | ⚡📂香书小说 | www.ibiqugu.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 60 | 📂阁笔趣网 | www.gashuw.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 61 | 📂爱书包 | www.shubaoge.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 77 | 📂篱笆好文学 | m.libahao2.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 82 | ⚡📂蚂蚁文学 | www.mayiwsk.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.mayiwsk.info/modules/ | 網站連不上 |
| 99 | 📂达文小说 | www.dawenks.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.dawenks.com/search.ph | 網站連不上 |
| 111 | ⚡📂笔趣阁 | www.biqugere.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 121 | ⚡📂黄易小说 | wap.aihytd.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.aihytd.com/SearchBook | 網站連不上 |
| 124 | ⚡📂若雨中文 | www.3yt.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 126 | ⚡📂笔趣阁 | m.xbiqukun.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 131 | ⚡📂9559小说 | www.95590.org | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 135 | ⚡📂小说网 | www.shukuge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 139 | ⚡📂键盘小说 | www.janpn.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 140 | ⚡📂鬼吹灯 | www.gdbzkz.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 146 | 📂三九小说 | www.sanjiusk.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 147 | ⚡📂亿软小说 | m.iyruan.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 153 | ⚡📂7766小说网 | m.qiliuzw.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 156 | ⚡📂神藏小说 | www.swangwx.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 168 | 📂八一中文 | www.81shuku.info | TCP 連不上 | TCP 連不上 | 無法找到指定主機名稱的伺服器。 連線失敗 · www.81shuku.info | 網站連不上 |
| 169 | 📂三五文学 | www.35wx.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.35wx.info/modules/art | 網站連不上 |
| 176 | 📂爱下小说（优） | apiv2hans.aixdzs.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「apiv2hans.aixdzs.com」的伺服器， | 憑證無效 |
| 180 | ⚡📂玄幻阁吧 | www.xuanhuange.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 183 | ⚡📂阅读书库 | www.yeudusk.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 193 | 📂棉花糖 | www.mhtxs.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.mhtxs.info · 連線逾時 | 網站連不上 |
| 203 | ⚡📂永恒小说 | wap.4pan.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.4pan.org/s.php · 連線逾時 | 網站連不上 |
| 218 | ⚡📂百草露小说 | m.baicaolu.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 219 | ⚡📂悠久小说 | www.ujxsw.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 220 | ⚡📂必去网站 | www.ibiquw.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 227 | 📂️帝书阁 | m.xdishuge.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.xdishuge.org/search/ ·  | 網站連不上 |
| 232 | 📂雨鹿小说 | novel.yulu.local | DNS 查無 | DNS 查無 | 搜尋Fetched empty content  | 網站連不上 |
| 233 | ⚡📂必去吧楼 | m.bequ6.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 239 | ⚡📂笔趣阁 | m.biqusk.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 247 | ⚡📂飞速小说网 | www.feisuwx.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.feisuwx.org/modules/a | 網站連不上 |
| 256 | ⚡📂手机小说 | www.sjshuku.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 259 | 📂女生文学 | www.xwenxuem.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 268 | ⚡📂八一中文网 | m.zwduxs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 271 | ⚡📂就爱文学 | www.92xs.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.92xs.info/modules/art | 網站連不上 |
| 274 | ⚡📂平凡文学 | www.pksge.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 277 | ⚡📂求书网 | www.qiushu.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.qiushu.info/search.ph | 網站連不上 |
| 291 | ⚡📂看书网 | www.kanzh.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 295 | ⚡📂文UU小说网 | m.uuwx.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.uuwx.la/search.php · 連線 | 網站連不上 |
| 297 | 📂美艺言情小说书馆 | m.meiyeewk.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.meiyeewk.com/search.php | 網站連不上 |
| 301 | ⚡📂书趣阁 | wap.xshuquge.net | TCP 連不上 | TCP 連不上 | 無法找到指定主機名稱的伺服器。 連線失敗 · wap.xshuquge.net | 網站連不上 |
| 310 | ⚡📂三五中文 | www.xkushu.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.xkushu.org/modules/ar | 網站連不上 |
| 311 | ⚡📂未来天王 | www.weilaitianwang.info | HTTP 無回應 | HTTP 無回應 | 要求逾時。  | 網站連不上 |
| 318 | 📂人人小说 | apk.renrenapi.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 323 | 📂零点小说 | www.lingdxsw.com | HTTP 無回應 | HTTP 無回應 | 網路連線中斷。  | 網站連不上 |
| 324 | ⚡📂阴阳代理 | www.xyinyangdailiren.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 329 | ⚡📂武道文学 | www.bookwenxue.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 338 | 📂以太小说网 | m.ethxs.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 348 | 📂影书小说 | wap.yingsx.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.yingsx.com/s.php · 連線 | 網站連不上 |
| 373 | 📂爱笔楼 | m.biqutu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 385 | ⚡📂4电子书 | www.4020xs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 395 | 📂️三叉小说 | m.xxxbiquge.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.xxxbiquge.net/{{url=sou | 網站連不上 |
| 408 | ⚡📂飘天文学 | m.piaotianwxz.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.piaotianwxz.com/so/ · 連 | 網站連不上 |
| 413 | 📂云中书库 | www.yunxs.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 415 | 📂鸟书网 | wap.99wx.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.99wx.info/search.php  | 網站連不上 |
| 432 | ⚡📂衍墨轩 | www.ymxshuwu.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.ymxshuwu.com/search.h | 網站連不上 |
| 448 | 📂飘天文学手机版 | m.piaotianbiquge.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.piaotianbiquge.com/so/  | 網站連不上 |
| 450 | ⚡📂️快眼小说 | www.kyxsw.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 460 | ⚡📂大帝小书库 | www.aikushuge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 468 | ⚡📂键盘小说 | www.janpn.org | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.janpn.org/search.php  | 網站連不上 |
| 471 | ⚡📂民国奇人 | www.minguoqiren.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 474 | ⚡📂无双小说 | www.buxia.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.buxia.la/modules/arti | 網站連不上 |
| 477 | 📂八一中文 | www.wangshuwx.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 486 | ⚡📂火高小说 | www.00shu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 489 | 🔞肉文屋 | www.po18e.vip | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.po18e.vip/modules/art | 網站連不上 |
| 496 | 🔞新御书屋 | www.xyushuwu.one | 5xx | 5xx | 搜尋失效 HTTP 500 · www.xyushuwu.one/sort/0/1.html | 網站連不上 |
| 499 | 🔞辣妹小说 | m.lamei2.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.lamei2.com/s.php · 連線逾時 | 網站連不上 |
| 512 | ⚡📂乐库小说 | m.6lk.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.6lk.la/s.php · 連線逾時 | 網站連不上 |
| 515 | ⚡📂️读趣网站 | www.xduqu.com | TCP 連不上 | TCP 連不上 | 無法找到指定主機名稱的伺服器。 連線失敗 · www.xduqu.com | 網站連不上 |
| 517 | ⚡📂八月文学 | www.jiuxs.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.jiuxs.la/modules/arti | 網站連不上 |
| 518 | 📂乐文阁网 | www.lewendu8.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.lewendu8.net/modules/ | 網站連不上 |
| 521 | ⚡📂️唐三中文 | www.xtangsanshu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 522 | ⚡📂梦幻小说 | www.pan5.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 536 | ⚡📂搜读中文 | m.soduzw.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 543 | ⚡📂茂鑫小说 | www.tcmaoxin.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 544 | 📂K小说 | www.2kzw.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 547 | 📂梦书中文 | www.mcxs.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 550 | 📂书出荒慌 | m.shuhuanghuang.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 552 | 📂无忧小说 | www.51eshu.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.51eshu.com · 連線逾時 | 網站連不上 |
| 555 | 📂最终小说网 | www.zuizhong.net | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.zuizhong.net/ · 連線逾時 | 網站連不上 |
| 557 | ⚡📂幻影小说网 | www.huiysj.com | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.huiysj.com/search.htm | 網站連不上 |
| 560 | 📂二三中文 | m.ersanwx.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 566 | 📂五五读书 | www.changduge.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 578 | 📂零点小书 | www.ldxsw.co | HTTP 無回應 | HTTP 無回應 | 網路連線中斷。  | 網站連不上 |
| 582 | 📂读万卷书 | wap.duwanjuan.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 586 | 📂九五看书 | www.95ks.org | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.95ks.org/search.html  | 網站連不上 |
| 595 | 🔞海棠书屋 | m.5haitang.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.5haitang.com/s.php · 連線 | 網站連不上 |
| 599 | 📂夜读居网 | www.yeduju.com | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.yeduju.com/search.htm | 網站連不上 |
| 600 | 📂读趣小说 | www.duqu.la | TCP 連不上 | HTTP 無回應 | Request timed out 連線失敗 · www.duqu.la/search.html · | 網站連不上 |
| 601 | 📂书包书库 | www.shubaoku.org | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 612 | ⚡📂星空小说 | wap.aixszw.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.aixszw.net/s.php · 連線 | 網站連不上 |
| 615 | ⚡📂爱笔趣阁# | www.ibiquge.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 617 | 📂小说77 | www.xs177.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.xs177.com/search.html | 網站連不上 |
| 619 | ⚡📂笔趣阁 | www.xbiquge.la | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.xbiquge.la」的伺服器，並且可能會對 | 網站連不上 |
| 621 | 📂小说阅读 | www.xiaoshuoge.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 622 | 📂九五书包 | www.95dushu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 624 | ⚡📂思路客# | www.shuqusk.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.shuqusk.net/modules/a | 網站連不上 |
| 626 | 📂️醉读小说️# | wap.maxreader.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 628 | 📂笔仙阁子 | 209.74.107.162 | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「209.74.107.162」的伺服器，並且可能會對 | 憑證無效 |
| 636 | 📂橘子小说 | www.shugelou.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 639 | ⚡📂爱乐文学 | www.ailewx.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.ailewx.com/search.htm | 網站連不上 |
| 640 | ⚡📂笔尖中文 | www.xbiquwk.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 641 | 📂猪猪小说 | www.zzs5.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 644 | 📂蚂蚁阅读# | wap.mayitxt.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 645 | ⚡📂笔趣阁 | www.tianxiabachang.cn | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.tianxiabachang.cn/cse | 網站連不上 |
| 646 | ⚡📂全本小说 | www.xs5300.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 648 | ⚡📂笔趣阁 | www.bbiquge8.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 657 | 📂爱看书/零点小说#书源.com | www.lingdxsw.org | HTTP 無回應 | HTTP 無回應 | 網路連線中斷。  | 網站連不上 |
| 658 | 🔞肉文屋 | wap.powenwu6.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「wap.powenwu6.com」的伺服器，並且可能 | 憑證無效 |
| 663 | 📂必去书库 | m.biqusk.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.biqusk.info/s.php · 連線逾 | 網站連不上 |
| 667 | ⚡📂丁丁小说 | www.idingdiange.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 669 | 🔞爱去耽美站 | www.asw228.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.asw228.com」的伺服器，並且可能會對 | 憑證無效 |
| 672 | 📂五六书库 | wap.56pinshu.net | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 673 | 📂文学爱度 | m.wenxuedu.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 677 | 📂️斗破苍穹cc | m.xdoupocangqiong.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 678 | 📂明月小说 | wap.kanxs.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.kanxs.info/s.php · 連線 | 網站連不上 |
| 679 | ⚡📂文桑小说 | www.wensang.net | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.wensang.net/home/sear | 網站連不上 |
| 685 | 📂艺佳中文网 | www.yijiazf.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.yijiazf.com/search.ht | 網站連不上 |
| 689 | 📂明月小说 | wap.aishuge.org | HTTP 無回應 | HTTP 無回應 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「wap.aishuge.org」的伺服器，並且可能會 | 網站連不上 |
| 699 | ⚡📂️笔下文学 | www.duquxs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 705 | ⚡📂键盘小说 | www.jianpan.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 707 | 📷🔞秀人集 | www.quanjixiu.com | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「www.quanjixiu.com」的伺服器，並且可 | 憑證無效 |
| 711 | 📂神书网 | wap.shenshuzw.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.shenshuzw.info/search | 網站連不上 |
| 716 | ⚡📂笔趣阁 | www.ibiquge.la | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 730 | ⚡📂笔趣阁 | www.biqusa.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 740 | 📂草屋小说 | www.caowuxs.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.caowuxs.com/search.ht | 網站連不上 |
| 747 | 📂书海小说（发现） | www.shuhai.com | HTTP 無回應 | HTTP 無回應 | 搜尋Fetched empty content  | 網站連不上 |
| 750 | ⚡📂黄易小说[hy] | www.huangyixiaoshuo.la | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · www.huangyixiaoshuo.la/in | 網站連不上 |
| 751 | ⚡📂清风小说网 | www.qf917.com | DNS 查無 | DNS 查無 | 無法找到指定主機名稱的伺服器。  | 網站連不上 |
| 757 | ⚡📂星星小说网 | m.xiifan.com | HTTP 無回應 | HTTP 無回應 | 網路連線中斷。  | 網站連不上 |
| 758 | ⚡📂无极小说 | wujiwx.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 759 | 🔞爱丽丝书屋 | xn--vcsx64d.alicesw12.xyz | 憑證無效 | 憑證無效 | 此伺服器的憑證無效。你所連接的伺服器可能是冒用「xn--vcsx64d.alicesw12.xyz」 | 憑證無效 |
| 762 | 🔞PO18文学 | m.po18q.com | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · m.po18q.com/s.php · 連線逾時 | 網站連不上 |
| 765 | 📂溜达小说 | m.liudatxt.la | HTTP 無回應 | HTTP 無回應 | Request timed out 連線失敗 · m.liudatxt.la/search.php  | 網站連不上 |
| 766 | ⚡📂黑岩阅读 | www.xheiyan.org | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 775 | ⚡📂超凡小说 | wap.pan6.info | TCP 連不上 | TCP 連不上 | Request timed out 連線失敗 · wap.pan6.info/s.php · 連線逾 | 網站連不上 |
| 779 | ⚡📂鬼吹灯 | www.cxzz958.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 781 | ⚡📂爱笔趣阁 | www.ibiquges.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 785 | ⚡📂七酷读书 | www.77shuku.info | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |
| 786 | 📂爱奇小说 | m.bingfengxs.com | TCP 連不上 | TCP 連不上 | 要求逾時。  | 網站連不上 |

