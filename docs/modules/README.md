# 模組開發文件

模組是一個 JSON 檔：它告訴「閱讀」去哪個網站拿書單、怎麼搜尋、怎麼用 ISBN 補資料、怎麼一章一章讀。
它**不執行 JavaScript**，只用規則引擎的規則（CSS、XPath、JSONPath、正則，和 `||` `&&` `%%` `##`），
所以匯入前就能完整檢查：哪個欄位有問題，匯入畫面會直接說。

App 內建的官方模組（`Resources/Assets/official-module-<id>.json`）跟你寫的模組是**同一種檔案、同一個驗證器**，
官方模組做得到的，你的模組也做得到。下面的範例都取自這些檔案：

| 檔案 | 示範 |
|------|------|
| `official-module-narou.json` | 排行清單、`offset` 分頁、搜尋、`reading`（在 App 內讀書）、`singleChapter` |
| `official-module-bangumi.json` | POST + `bodyEncoding: json`、`tags`、`aliases`、`excludeTags`、`contentKind` |
| `official-module-anilist.json` | GraphQL（POST JSON）、`localizations` |
| `official-module-openbd.json` | `lookup`（以 ISBN 補資料）、`isbnPrefixes` |

本文件有測試把關（`ModuleFormatDocumentationTests`）：格式多了欄位而這裡沒寫，測試就會失敗。

---

## 1. 最小的模組

```json
{
  "id": "example.newbooks",
  "title": "新書速報",
  "version": "1.0",
  "hosts": ["example.com"],
  "modules": [
    {
      "id": "new",
      "title": "新書",
      "request": { "url": "https://example.com/new.html" },
      "list": { "items": "li.book", "title": "h3@text", "url": "a@href" }
    }
  ]
}
```

加入方式：資源庫 ••• → 新增模組（從網址／從檔案／從剪貼簿），或 `yuedu://module?src=<網址>` 連結，
或設定 → 來源配置管理 → 模組 → 右上角。加入前會先顯示模組的作者、清單和**會連線的網站**，按 ✓ 才寫入。

---

## 2. 頂層欄位

| 欄位 | 必填 | 說明 |
|------|------|------|
| `id` | ✓ | 代號，只能用 `A-Z a-z 0-9 . _ -`，最長 128 字。它是模組資料夾的名字，也是更新時認同一個模組的依據。官方模組的代號（`bangumi`、`anilist`、`openbd`、`narou`、`rakuten-books`）不能用。 |
| `title` | ✓ | 名稱。 |
| `description` |  | 一兩句說明，顯示在模組頁和倉庫列表。 |
| `author` |  | 作者。 |
| `site` |  | 網站首頁，顯示在模組頁。 |
| `version` | ✓ | 數字點分版本（`1.0`、`1.2.10`）。「檢查更新」只接受比已安裝的**更高**的版本。 |
| `requiredVersion` |  | 能讀這個檔案的最低 App 版本。用到 3.0 欄位（見 §8）時至少要寫 `3.0`。 |
| `hosts` | ✓ | 模組**唯一**能連線的主機名稱。每個 `request.url` 的主機都必須列在這裡，封面也只從這些主機載入。HTTP 轉址和頁面 `<head>` 裡的 `<meta http-equiv="refresh">`（GET 才跟、只跟一次）也只會跟到這些主機；轉到別的主機時就照原頁讀，封面則當作沒有封面。寫成 `*.archive.org` 的項目只放行**轉址**：那個網域本身和它底下所有主機（Open Library 的封面會轉到 `iaNNNNNN.us.archive.org`），`request.url` 不能直接連；至少兩段（`*.org` 會被拒絕）。3.0。 |
| `rateLimit` |  | 請求頻率，跟來源配置的 `concurrentRate` 同語法：`1/1000` 是每 1000 毫秒 1 次。 |
| `modules` | ✓ | 清單（§3），可以是空陣列；最多 50 個。 |
| `search` |  | 搜尋（§3，沒有 `id`），會加進統一搜尋。 |
| `lookup` |  | 以 ISBN 查一本書（§5），用來補資料。3.0。 |
| `reading` |  | 怎麼讀它的書（§6）。沒有它，模組的書只有資料、不能讀。3.0。 |
| `attribution` |  | 網站條款要求的署名（§7）。3.0。 |
| `localizations` |  | 其他語言的名稱和說明（§7）。3.0。 |

`modules`、`search`、`lookup` 至少要有一個，不然會被拒絕（「模組沒有任何清單」）。
檔案最大 256 KB。

---

## 3. 清單（`modules[]`、`search`）

| 欄位 | 必填 | 說明 |
|------|------|------|
| `id` | 清單 ✓ | 清單代號，同一模組內不能重複；`search` 沒有 `id`。首頁欄目用它記住是哪個清單。 |
| `title` | 清單 ✓ | 清單名稱。 |
| `description` |  | 說明。 |
| `cacheDuration` |  | 秒數：這段時間內同一頁直接用快取，不再請求。 |
| `params` |  | 參數（§3.1）。 |
| `request` | ✓ | 請求（§3.2）。 |
| `list` | ✓ | 從回應取出書的規則（§3.3）。 |
| `contentKind` |  | `text`（預設）或 `comic`：整個清單是漫畫。3.0。 |
| `excludeTags` |  | 這個網站的 `tags` 裡不算題材的字（如 `漫画`、`单行本`），使用標籤時排除。3.0。 |
| `isbnPrefixes` |  | 只用在 `lookup`（§5）。3.0。 |
| `detail` |  | 只用在 `search` 和 `lookup`：那本書自己的頁面，補清單沒給的簡介或標籤（§5.1）。3.0。 |
| `minKeywordLength` |  | 只用在 `search`：關鍵字至少幾個字才送出（Open Library 是 `3`）。更短的不送：搜尋時這個模組不出現，補資料時也不用書名查。3.0。 |

### 3.1 參數 `params[]`

| 欄位 | 必填 | 說明 |
|------|------|------|
| `name` | ✓ | 在 `request` 裡寫成 `{{name}}`。 |
| `title` |  | 首頁欄目設定畫面顯示的名稱。 |
| `type` | ✓ | 見下表。 |
| `description` |  | 說明。 |
| `value` |  | 預設值。數字會讀成文字。`page`／`offset` 參數的 `value` 是**第一頁的位置**（整數，3.0）；不寫時 `page` 從 1、`offset` 從 0 開始。 |
| `enumOptions` | `enumeration` ✓ | 選項陣列：`{ "title": "顯示名稱", "value": "送出的值" }`。 |

| `type` | 意思 |
|--------|------|
| `input` | 讀者在欄目設定裡自己輸入。 |
| `count` | 數字。 |
| `constant` | 固定值。 |
| `enumeration` | 從 `enumOptions` 選一個。 |
| `page` | 分頁頁碼，捲到底時自動加一。 |
| `offset` | 分頁位移，每次加上一頁的筆數。 |

`{{page}}`、`{{offset}}` 不必宣告就能用；`search` 另外可用 `{{keyword}}`，`lookup` 可用 `{{isbn}}`。
其他 `{{…}}` 都必須是宣告過的參數，否則拒絕。

### 3.2 請求 `request`

| 欄位 | 必填 | 說明 |
|------|------|------|
| `url` | ✓ | `http://` 或 `https://`，主機必須在 `hosts`。主機不能由參數組成（`https://{{site}}/` 會被拒絕）。不支援 Legado 的 `url,{…}` 選項尾巴——方法、內容、標頭各寫在自己的欄位。 |
| `method` |  | `GET`（預設）或 `POST`。 |
| `body` |  | POST 內容，可用 `{{…}}`。 |
| `headers` |  | 標頭物件，值可用 `{{…}}`。 |
| `charset` |  | 回應編碼（如 `gbk`），不寫就照回應自己說的。 |
| `bodyEncoding` |  | `form`（預設，百分號編碼）或 `json`（值會照 JSON 字串跳脫），例如 `{"keyword":"{{keyword}}"}`。3.0。 |

### 3.3 取書規則 `list`

每個值都是一條規則；`items` 先選出每一本書，其餘規則都在那一本的範圍裡讀。

| 欄位 | 必填 | 說明 |
|------|------|------|
| `items` | ✓ | 每一本書。 |
| `title` | ✓ | 書名。 |
| `author` |  | 作者。規則讀到好幾個值（例如 JSON 陣列）時是好幾位作者，最多 5 位。 |
| `cover` |  | 封面網址（只從 `hosts` 載入）。 |
| `intro` |  | 簡介。 |
| `url` |  | 書的網址。有 `reading` 時是書的目錄頁。 |
| `kind` |  | 分類。 |
| `language` |  | 語言。 |
| `aliases` |  | 其他書名（可多個值）。3.0。 |
| `tags` |  | 題材、標籤（可多個值）。3.0。 |
| `publisher` |  | 出版社。3.0。 |
| `isbn` |  | ISBN-10 或 -13；檢查碼不對的會被丟掉。可以讀到好幾個值（一個版本的 ISBN-10 和 -13），`lookup` 時任一個跟書架那本相同就算；搜尋結果最多留 5 個。3.0。 |
| `series` |  | 系列。3.0。 |
| `contentKind` |  | 讀到 `comic` 時這本是漫畫，其他值照清單的 `contentKind`。3.0。 |

規則裡的 `{{…}}` 只能放一條規則（例如 `https://ncode.syosetu.com/{{$.ncode}}/`），由規則引擎就地讀出；
不能放參數。

---

## 4. 不允許的寫法

驗證器會拒絕，並在匯入畫面說出是哪個欄位：

- `@js:`、`<js>…</js>`、`{{ }}` 裡的 JavaScript —— 模組不執行 JavaScript。
- `@get:`、`@put:` —— 模組沒有變數。
- 沒宣告的 `{{…}}`。
- `request.url` 連到 `hosts` 沒列的主機，或主機由參數組成。
- 非 `http`／`https` 網址、Legado 的 `,{…}` 網址選項。
- `GET`／`POST` 以外的方法。
- 不認得的 `type`、`contentKind`、`bodyEncoding`、`localizations` 語言標籤。
- 清單代號重複、超過 50 個清單、檔案超過 256 KB。
- 用了 3.0 欄位但 `requiredVersion` 低於 `3.0` 或沒寫。
- `requiredVersion` 比使用者的 App 版本新（會請使用者更新 App）。

---

## 5. 以 ISBN 補資料 `lookup`

書架上的書有 ISBN、但缺封面、簡介或出版社時，「閱讀」會用 `lookup` 查。
`lookup` 是一個清單（§3），另外：

- `request.url` 或 `request.body` 必須含 `{{isbn}}`。
- `list.isbn` 必填：回應裡的 ISBN 要跟書架那本一致才採用。
- `isbnPrefixes`：網站有的 ISBN-13 前綴（openBD 是 `9784`）。其他書的 ISBN **不會離開裝置**。

可以補的欄位：`cover`、`intro`、`publisher`、`series`、`tags`、`aliases`。模組的 `search` 也會用書名補資料。
使用者在 設定 → 聚合設定 → 資料來源 取消勾選就不會用它補資料（搜尋在同一頁的「搜尋來源」），或在模組頁按「停用」整個關掉。

### 5.1 書的詳情頁 `detail`

有些網站的搜尋結果沒有簡介，要再開那本書自己的頁面才有（Open Library 的簡介在 `/works/<編號>.json`）。
`search` 或 `lookup` 可以加 `detail`：

```json
"detail": {
  "request": { "url": "{{url}}.json" },
  "intro": "$.description.value||$.description",
  "tags": "$.subjects[*]"
}
```

- `request` 跟 §3.2 一樣，但只能用 `{{url}}`：那筆結果的 `url`（所以 `list.url` 必填）。
  放在網址開頭時照原樣代入，放在其他地方會百分號編碼。代入後的網址一樣只能連到 `hosts`。
- `intro`、`tags`：在詳情頁上直接讀的規則（沒有 `items`），至少要有一個。
- 只在補資料時、而且只對確定是那本書的那一筆結果請求一次，不會每一列都開；
  清單已經給了簡介和標籤、或書架那本不缺這兩項時就不請求。
- 首頁清單（`modules[]`）不能用 `detail`。舊版 App 會忽略它，只是補不到這兩項。

---

## 6. 在 App 內讀書 `reading`

有 `reading` 的模組，書可以加進書架、一章一章讀（`official-module-narou.json`）。
清單裡書的 `url` 是目錄頁。

| 欄位 | 必填 | 說明 |
|------|------|------|
| `headers` |  | 每一頁都帶的標頭（如 `User-Agent`），不能用 `{{…}}`。 |
| `charset` |  | 頁面編碼。 |
| `toc` | ✓ | 目錄規則，見下表。 |
| `content` | ✓ | 內文規則，見下表。 |

`toc`：

| 欄位 | 必填 | 說明 |
|------|------|------|
| `items` | ✓ | 每一章（或卷名）。 |
| `title` | ✓ | 章名。有章名沒網址的是卷名。 |
| `url` | ✓ | 章節網址。 |
| `nextPage` |  | 目錄下一頁的網址；空了、重複了、或讀滿 300 頁就停。 |
| `singleChapter` |  | 只有「整本只有一章」的頁面才對得上的規則（なろう的短篇：`.p-novel__body`）。先檢查它：一本書只有在頁面這麼說時才算單章，不會因為目錄讀空就當成單章。 |

`content`：

| 欄位 | 必填 | 說明 |
|------|------|------|
| `text` | ✓ | 內文，保留 HTML（`@html`），跟來源配置的正文規則一樣。 |
| `title` |  | 章名。 |
| `nextPage` |  | 一章分好幾頁時的下一頁。 |

---

## 7. 署名與多語言

`attribution`：網站條款要求的署名，顯示在模組頁。

| 欄位 | 必填 | 說明 |
|------|------|------|
| `text` | ✓ | 照網站的寫法，例如 `Supported by Rakuten Developers`。 |
| `url` |  | 署名連結，`http`／`https`。 |

`localizations`：以語言標籤（`en`、`zh-Hans`、`ja`）為鍵，值可以有 `title`、`description`，
以及 `entries`（以清單 `id` 為鍵，各自的 `title`、`description`）。App 用相同語言和文字（繁／簡）的那一份，
沒有就照原文：`zh-Hans` 不會代替 `zh-Hant`，`en` 也不會代替其他語言。`entries` 的鍵必須是存在的清單 `id`。

---

## 8. 版本

`version` 是你的模組版本；`requiredVersion` 是讀它需要的 App 版本。
下列欄位是格式 3.0 才有的，用到任何一個都要 `"requiredVersion": "3.0"` 以上，
否則舊 App 會匯入後讀錯（例如把 JSON 內容百分號編碼送出）：

`attribution`、`localizations`、`lookup`、`reading`、`contentKind`、`excludeTags`、`isbnPrefixes`、`detail`、
`minKeywordLength`、`hosts` 裡的 `*.` 項目、`bodyEncoding`、`page`／`offset` 參數的 `value`，以及 `list` 的 `aliases`、`tags`、`publisher`、`isbn`、`series`、`contentKind`。

---

## 9. 模組倉庫

倉庫是一個列出模組的 JSON 檔。使用者在 新增模組 → 從網址 貼上倉庫網址就能訂閱，之後在「模組」頁挑選安裝；
打開倉庫頁時會重新讀一次，有新版本的模組顯示「更新」，按了才換。更新若會連到新的網站，一定先讓使用者看過。

```json
{
  "name": "範例倉庫",
  "modules": [
    {
      "id": "example.newbooks",
      "title": "新書速報",
      "description": "範例網站的新書",
      "author": "範例作者",
      "version": "1.1",
      "url": "newbooks.json"
    }
  ]
}
```

| 欄位 | 必填 | 說明 |
|------|------|------|
| `name` | ✓ | 倉庫名稱。 |
| `modules` | ✓ | 模組陣列，最多 500 個；索引檔最大 1 MB。 |
| `modules[].id` | ✓ | 必須跟模組檔自己的 `id` 一樣，否則安裝時拒絕。同一倉庫不能重複。 |
| `modules[].title` | ✓ | 列表上的名稱。 |
| `modules[].description` |  | 說明。 |
| `modules[].author` |  | 作者。 |
| `modules[].version` | ✓ | 倉庫裡的版本，用來判斷「更新」；實際安裝的是模組檔自己的 `version`。 |
| `modules[].url` | ✓ | 模組檔網址，可以是相對於索引檔的路徑。安裝後它就是模組的訂閱網址，「檢查更新」讀它。 |

一個 JSON 若有 `modules` 而沒有 `id`，就當成倉庫；倉庫只能用網址加入（從檔案或貼上的文字沒有網址可以重新讀）。

---

## 10. 測試你的模組

1. 用 `python3 -m http.server 8000` 在電腦上開一個資料夾，模擬器的 App 可以用 `http://localhost:8000/…`
   （`127.0.0.1` 會被擋，要寫 `localhost`；`hosts` 也寫 `localhost`）。
2. 資源庫 ••• → 新增模組 → 從網址，看預覽列出的清單和網站對不對。
3. 探索 → 編輯首頁 → 新增欄目，選你的模組清單；搜尋頁試 `search`。
4. 改了檔案要提高 `version`，到模組頁按「檢查更新」。
