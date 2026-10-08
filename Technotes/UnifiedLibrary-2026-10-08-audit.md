# 統一書庫與探索：現況架構審計

> 日期：2026-10-08
> 基準：`main` @ `b24d525`，行號都以這個 commit 為準。
> 狀態：**只讀審計。** 沒有修改任何行為，也沒有在模擬器或真機上執行，結論全部來自讀程式碼。由程式碼推得、但沒有直接讀到的結論標「推論」。
> 起因：維護者〈Yuedu 下一代架構：統一探索、刮削與模組系統〉（2026-10-08）§14。該文主張先審計現有架構，再訂資料模型與遷移計畫，之後才分階段實作。
> 下一份：[資料模型與遷移計畫](UnifiedLibrary-2026-10-08-design.md)

## 0. 一句話

App 裡真正的實體只有一個，就是 `ReadingBook`。它同時扮演作品、版本、來源紀錄、取得方式與閱讀紀錄。它的 `id` 是 25 個以上儲存位置的鍵，也是 iCloud 的合併鍵。新架構不能取代它，只能把它定位為「閱讀副本」，在旁邊另加一層作品資料。

## 1. 結論

1. **書庫只有一種實體。**
   - `ReadingBook`（`Modules/Services/LibraryStore/Models.swift:203`）的 `id` 一律是 `UUID()`（`Models.swift:306`），沒有任何入口用推導或雜湊產生。
   - 本機檔案匯入完全不去重：同一個檔案匯入兩次會得到兩筆紀錄、兩份檔案。
   - 「同一本書」只在執行期以書名＋作者判斷：`SearchBook` 的 `nameKey`、`isLikelySameBook` 與 `makeKey`（`Modules/Services/Online/SearchAggregator.swift:75-131`）。它們用於搜尋合併、換源與「最近閱讀」，結果從不寫入書庫。
2. **`ReadingBook.id` 不能換。**
   - 閱讀位置、章節快取、離線下載、遠端快取、AI 索引與摘要、統計、Live Activity、iCloud 合併都以它為鍵（附錄 A）。
   - 新模型應把它當成「閱讀副本」的身分，往上加作品層，而不是重新編號。
3. **不能大量改寫 `ReadingBook` 的編碼。**
   - iCloud 以每本書的雜湊偵測修改（`Modules/Services/iCloud/ICloudSyncManager.swift:500-506`）。雜湊一變，該筆就被記為「現在修改」（`ICloudSyncManager.swift:870-903`），在合併時勝出。
   - 對每本書補寫一個欄位，等於讓這台裝置的舊進度蓋掉其他裝置的新進度。
   - 模型註解已寫明這條規則（`Models.swift:284-290`、`Models.swift:643-644`）。所以作品層必須存在 `ReadingBook` 以外的獨立儲存。
   - 同步本身以「整本書」為合併單位，詳見 §6.1。
4. **Metadata 沒有來源紀錄。**
   - 書名與作者只有一份，下列寫入者都直接覆寫它：
     - 使用者編輯（`BookStore.swift:1228-1234`）；
     - 線上書重新抓詳情：書源設有 `canReName` 時會覆寫（`BookStore.swift:2122-2131`、`Models.swift:816-848`），見 §7.2；
     - Calibre 回寫（`RemoteLibraryWritingService.swift:179-188`）；
     - WebDAV 改名（`RemoteLibraryWritingService.swift:222-235`）。
   - 只有封面有「手動」標記（`customCoverUrl`）與原圖備份（`originalCoverImagePath`）。
   - 簡介、分類、標籤、字數、語言、識別碼都不在 `ReadingBook` 上（`BookStore.swift:1890` 的註解直接寫「ReadingBook does not store an intro」）。
5. **WebDAV／OPDS／Calibre 已經有一半的 CollectionProvider。**
   - 已具備的部分：
     - `RemoteLibraryKind` 是類型，`OPDSCatalog` 是實例，Provider Type 與 Source Instance 的區分已經存在。
     - `RemoteLibraryService` 的閱讀管線不在乎書來自哪種書庫。
   - 缺的部分：
     - 統一的瀏覽模型：OPDS 有 `OPDSBrowseModel`，WebDAV 則由 view 直接呼叫網路。
     - 結構化 metadata：Calibre 瀏覽與搜尋只走 OPDS，不讀標籤、系列、ISBN。
     - 穩定身分：WebDAV 以檔案 URL 為身分，同一本書的每種格式各是一筆紀錄。
6. **探索頁已經有 HomeSection 的骨架，就是自訂探索頁。**
   - 排序、7 種版面、編輯器與持久化都已存在（`Modules/Services/Online/CustomExplorePageStore.swift`）。
   - 但版面以下的每個型別都綁網路書源：`ExploreCategoryReference`、`OnlineBook`、`BookSourceFetcher.shared`。
   - 公有書庫與書源是兩個根 view，以 `explore.mode` 切換，各有自己的 `NavigationStack`（`Modules/Features/Explore/ExploreTabRoot.swift:4-37`）。
7. **找書的搜尋分成五套，彼此不相通。**
   - 「搜索」分頁的 `SearchAggregator` 只搜網路書源。
   - 公有書庫、OPDS 與 Calibre 目錄、WebDAV 資料夾各有自己的頁內搜尋。
   - 書架本身沒有搜尋欄。
   - 「同一本書」至少有六套判斷規則，全部只看書名與作者，沒有繁簡轉換，也沒有 ISBN 等識別碼（§11.2）。
   - 原生搜尋路徑把 HTTP 失敗與解析失敗都當成「零筆結果」並記為成功（§11.3）。
   - 新的搜尋 UI 必須沿用 iOS 17 watchdog 結案的約束（§11.5）。
8. **既有的承諾比程式碼更難改。** 新首頁必須逐一繼承以下約束，不能只照搬 UI：
   - 中國區 storefront 隱藏公有書庫（`PublicLibraryAvailability`）；
   - Gutenberg「開首頁不發請求、不預抓、不背景爬取」的使用條款；
   - `docs/design.md` 的「發現」原型要求「尊重書源作者的分類與內容，**不擅自重組成平台推薦流**」；
   - iOS 17 的 Menu／sheet presentation 規則。

## 2. 範圍與方法

| §14 審計項目 | 本文章節 |
|---|---|
| 目前 Library 資料模型 | §4 |
| WebDAV／OPDS／Calibre 具體實作 | §8 |
| 公有書庫架構 | §9 |
| 現有網路書源解析機制 | §10 |
| 搜尋邏輯 | §11 |
| 探索頁與匯入 Sheet | §12、§8.6 |
| 書籍 Metadata 儲存方式 | §7 |
| 閱讀進度和書籍識別方式 | §5、§6 |

做法：

- 先依上表分成四個領域，各做一次唯讀走查。
- 再逐項對照原始碼，核實會影響設計決定的結論，例如 iCloud 雜湊合併、位置儲存、`canReName` 覆寫規則、遠端書身分。
- 外部條款與 API 的查證（App Store 4.7、各家 Metadata API）不屬於「現況」，放在設計文件。

## 3. 目標概念與現況對照

| 目標概念 | 現況最接近的東西 | 落差 |
|---|---|---|
| `Work` 抽象作品 | 沒有持久化的作品。只有執行期的書名＋作者比對（`SearchAggregator.swift:75-131`）。 | 沒有作品實體，也沒有「這兩本是同一部作品」的紀錄。 |
| `Edition` 版本 | 沒有。Calibre 同一本書的 EPUB 與 PDF 各是一筆 `ReadingBook`；Calibre 回寫時會一起改（`RemoteLibraryWritingService.swift:179-188`），這是唯一隱含「同一版本、不同檔案」的地方。 | 沒有語言、譯本、版本欄位。 |
| `SourceRecord` 來源紀錄 | 四種寫法：`RemoteBookReference`（`Modules/Services/RemoteLibrary/RemoteLibraryItem.swift:34-43`）、`(bookSourceId, bookInfoURL)`、`AozoraBookSource.catalogWorkID`（`Models.swift:619-646`）、`ChangeSourceCache`（換源候選，`Modules/Services/Online/ChangeSourceCache.swift:28-30`）。 | 散在 `ReadingBook` 的不同欄位。每本書同時只有一個「目前來源」。 |
| `Acquisition` 取得方式 | `RemoteLibraryFormat`（遠端格式）、`contentFilename`（本機檔）、線上書目錄（`BookChapterStore`）。 | 「加入書架」「下載」「線上閱讀」在遠端書已分開（`Technotes/RemoteLibraryReading.md`），其他來源沒有。 |
| `MetadataRecord` 欄位來源 | 只有封面：`customCoverUrl`＋`originalCoverImagePath`。線上書的簡介等只存在 `book_info_cache`（§7.3）。 | 沒有來源、可信度、手動鎖定。 |
| `CollectionProvider` | `RemoteLibraryKind`＋`OPDSCatalog`＋`OPDSBrowseModel`＋`WebDAVBrowseClient`（§8）。 | 瀏覽模型不統一，WebDAV 沒有 view model。 |
| `MetadataProvider` | `OnlineCoverSearchService`：以書名＋作者查詢兩個外部封面端點（§10.4）。`ChangeCoverView`：在網路書源中找同名書的封面。 | 只有封面，沒有簡介、分類、識別碼。 |
| `DiscoveryProvider`／`HomeSection` | 自訂探索頁的 `CustomExploreComponent`（§12.3）。 | 綁網路書源，沒有啟用開關與 schema 版本。 |
| `UnifiedSearchCoordinator` | `SearchAggregator`（只搜網路書源，§11）。 | 本機、遠端書庫、公有書庫各自搜尋。 |
| 統一作品詳情 | `BookDetailScaffold`／`BookDetailHero` 被四種詳情共用（§13）。 | 本機書的「書籍資訊」是另一個 `Form`。 |
| Module Runtime | Legado 書源：JSON 規則＋JavaScriptCore（§10）。 | 只有「書源」這一種能力組合。 |

## 4. 書庫資料模型：`ReadingBook`

### 4.1 欄位

`ReadingBook` 有自訂的 `init(from:)`（`Models.swift:336-392`），沒有自訂 `encode(to:)`，所以值為 nil 的 optional 欄位不會被寫出。必要鍵有七個：`id`、`title`、`author`、`source`、`contentFilename`、`currentPosition`、`addedDate`。任何一筆缺任何一個鍵，整個陣列都會解碼失敗。`books_meta.json` 是沒有版本號的 JSON 陣列。

| 分組 | 欄位 | 說明 |
|---|---|---|
| 身分 | `id: UUID`（`let`） | 主鍵。 |
| 顯示資料 | `title`、`author`、`group`（單一分組字串） | 書名、作者直接被各寫入者覆寫（§7.2）。 |
| 封面 | `coverImagePath`、`coverUrl`、`customCoverUrl`、`originalCoverImagePath` | 唯一有「手動 vs 來源」區分的資料（§7.1）。 |
| 來源 | `source` | `"local"`、`"local_epub"`、`"local_pdf"`、`"local_manga"`、`"local_audio"`，或線上書／網頁書的 URL。一個字串兼任格式標記與來源。 |
| 來源 | `isOnline`、`bookSourceId`、`bookInfoURL`、`tocURL`、`runtimeVariables` | 網路書源與瀏覽器匯入書。`bookSourceId == nil` 代表瀏覽器匯入。 |
| 來源 | `remoteSource: RemoteBookReference?` | OPDS／WebDAV／Calibre／Gutenberg 的檔案（§8.3）。 |
| 來源 | `aozora: AozoraBookSource?` | 青空轉檔的原檔、編碼與 `catalogWorkID`。 |
| 內容 | `contentFilename`、`contentPipelineKind` | Documents 中的檔名（獨立隨機 UUID，不等於 `id`），或 `__remote_cache__/…`。 |
| 進度 | `currentPosition`（0–1）、`lastOpenedDate`、`mangaChapterIndex`／`mangaPage`、`audioChapterIndex`／`audioTimeSeconds` | 文字書的精確位置**不在這裡**（§6）。 |
| 標註 | `bookmarks: [Bookmark]` | 書籤與劃線都在書籍紀錄裡。解碼用 `(try? …) ?? []`（`Models.swift:368`），一筆壞資料會使整本書的書籤全部消失。 |
| 每本書設定 | `rendererPreference`、`compatibilityState`、`audioPlayMode` 等 | 固定頁閱讀設定另存於 `books_meta.reader-settings.json`。 |
| 線上目錄 | `onlineChapters`（不編碼）、`totalChapterNum`、`latestChapterTitle`、`hasNewChapterUpdate` | 目錄存在 `BookChapterStore`，不進同步。 |
| 離線 | `offlineDownloadState`、`downloadedChapterCount`、`offlineDownloadTask` | |
| 書架 | `isInBookshelf` | `false` 代表只是閱讀紀錄，例如沒加入書架就開的遠端書或「立即閱讀」。 |

**沒有的欄位：** 簡介、分類／標籤、字數、連載狀態、語言、出版者、ISBN 等外部識別碼。

### 4.2 `BookStore` 與持久化

| 檔案（Application Support） | 內容 | 位置 |
|---|---|---|
| `books_meta.json` | 書架成員 | `StorageLocations.swift:61-63` |
| `books_meta.reading.json` | 不在書架上的閱讀紀錄 | `BookStore.swift:138-140` |
| `books_meta.reader-settings.json` | `{version: 1, books: […]}`，固定頁閱讀設定 | `BookReaderSettingsStore.swift:9-32` |
| `books_meta.chapters/<id>.json` | 線上書與固定頁書的目錄 | `BookChapterStore.swift:50-52` |
| `books_meta.corrupt-<mtime>.json` | 解碼失敗時保留的原檔 | `BookStore.swift:2854-2880` |
| UserDefaults `yd_off_shelf_read_records` | 最多 10 筆 `{書名, 作者, 封面網址, 最後閱讀}` | `Modules/Services/LibraryStore/OffShelfReadRecords.swift:12-22` |

記憶體與寫入：

- **記憶體：** 只有一個 published 陣列。`books` 是書架過濾後的檢視，`readingBooks` 是全部（`BookStore.swift:88-113`）。
- **寫入：**
  - `saveMeta` 以 2 秒去抖，最長 10 秒必寫（`BookStore.swift:2297-2327`）。
  - 匯入、換源、封面編輯改用 `saveMetaImmediately`。
  - 所有寫入走同一條序列佇列；只有當檔案內容仍是這個 store 上次寫的位元組時才覆寫（`BookStore.swift:2554-2672`）。
- **寫入預算：** 進度寫入另有門檻（`BookStore.swift:158-160`、`2513-2542`），測試為 `BookStoreMetadataWriteBudgetTests`。

可編輯的 metadata 只有四類：書名、作者（`updateBook`，`BookStore.swift:1228-1234`）、單一分組（`BookStore.swift:1243-1259`）、封面（`BookStore.swift:1463-1612`）。沒有簡介、標籤或系列的編輯。

### 4.3 新增欄位的既有慣例與原因

既有模型這樣加欄位：optional、預設值存成 nil、以 `try?` 或 `decodeIfPresent` 解碼，只在不是預設值時寫出。例子：

- `audioPlayMode`：見 `Models.swift:284-293`；
- `catalogWorkID`：見 `Models.swift:643-644`，註解寫「A missing ID must not change old books' stable hashes during sync」。

原因在 §1 第 3 點：iCloud 以 `stableHash(strippedForSync())` 偵測修改，雜湊一變就以「現在」為修改時間。所以新架構在 `ReadingBook` 上能加的，最多只有**平常為 nil、只在少數書上出現**的欄位。

## 5. 書籍識別

### 5.1 `id` 的產生

唯一的初始化子設定 `self.id = UUID()`（`Models.swift:302-333`）。其他 id 都是解碼來的：同步、還原、舊版本採用。內容檔名、封面檔名使用另一個隨機 UUID，無法由 `id` 推得。

### 5.2 各入口與去重

| 入口 | 程式 | `source` | 去重 |
|---|---|---|---|
| TXT、Markdown、JSON 網頁書 | `BookStore.importTxt` 等（`BookStore.swift:259-362`、`601-616`） | `"local"` | 無 |
| EPUB（固定版面轉 `.fixedPage`） | `BookStore.importEpub`（`BookStore.swift:630-758`） | `"local_epub"` | 無 |
| PDF／漫畫／有聲書 | `BookStore.swift:367-599` | `"local_pdf"`／`"local_manga"`／`"local_audio"` | 無 |
| 檔案、分享延伸、「打開方式」 | `LocalBookImportService`、`SharedImportQueueDrainer` | 同上 | 無 |
| 青空檔案 | `AozoraBookImporter.importBook`（`Modules/Services/LibraryStore/AozoraBookImporter.swift:45-74`） | `"local_epub"` | 無 |
| 青空目錄 | `AozoraLibraryDownloadService.addToShelf`（`Modules/Services/PublicLibrary/AozoraLibraryDownloadService.swift:34-79`） | `"local_epub"` | 只比對書架上的 `catalogWorkID` |
| Calibre 無線傳書 | `CalibreWirelessService.swift:269-327` | 經 `LocalBookImportService` | `(libraryID, calibreUUID, 副檔名)`＋SHA-256，檔案變了就拒收 |
| 網路書源結果加入書架 | `BookStore.addOnlineBook`（`BookStore.swift:1373-1408`） | 詳情 URL | 只在呼叫端以 `(bookSourceId, 正規化 URL)` 查找（`BookStore.swift:1006-1021`） |
| 瀏覽器匯入 | `addWebBrowsedBook`（`BookStore.swift:1621-1639`）、`importWeb` | 網頁 URL | 無 |
| 遠端書庫（含 Gutenberg） | `RemoteLibraryService.record`（`Modules/Services/RemoteLibrary/RemoteLibraryService.swift:45-71`） | 依格式 | `(connectionID, entryID, 副檔名)`，逐筆掃描（`RemoteLibraryService.swift:41-43`） |
| Legado 書架匯入 | `LegadoMigrationManager.swift:58-106` | | 無 |

兩件值得注意的事：

- 網路書源刻意不合併：「同一本書在兩個書源」會是兩筆紀錄（`BookStore.swift:1006-1012` 的註解）。這是作品層最需要的資訊，卻沒有留下任何關聯。
- `bookSourceId` 指向 `BookSource.id`，但書源的真實身分是 `bookSourceUrl`。Legado JSON 沒有穩定 id，每台裝置匯入時各自產生 UUID，`BookSourceStore.dedupedByURL` 會以 URL 收斂（`Modules/Core/BookSource/BookSourceStore.swift:639-665`）。所以來源紀錄的鍵應該用 URL，不該用 UUID；搜尋範圍的設計已採這個做法（`docs/superpowers/specs/2026-08-23-search-source-scope-design.md`）。

### 5.3 可取得卻被丟掉的外部識別碼

| 來源 | 可取得的穩定識別 | 現在保存了什麼 |
|---|---|---|
| EPUB OPF | `dc:identifier`（ISBN、UUID 等）、`dc:language`、`dc:description`、`dc:subject` | 只有書名、作者、封面（`BookStore.swift:696-736`）；identifier 只用於字型反混淆（`Modules/Core/EPUB/PublicationSession.swift:1154`） |
| OPDS 1／2 | Atom `<id>`／`metadata.identifier`、OPDS 2 `language` | `entryID` 存進 `RemoteBookReference`；`language` 讀了沒用（`Modules/Services/OPDS/OPDS2FeedParser.swift:248`） |
| Calibre 內容伺服器 | `urn:uuid:`、`/get/{fmt}/{id}/{library}` 裡的 book id | `entryID` 是 OPDS id；回寫時再從下載網址解析 book id（`CalibreServerAPI.swift:93-103`） |
| Calibre 無線傳書 | `uuid`、library UUID、`lpath`、完整 metadata | 書本身只拿書名、作者（`Modules/Services/Calibre/CalibreWirelessProtocol.swift:179-181`）；完整 metadata 只在 `calibre-wireless-device.json` |
| Gutenberg | `urn:gutenberg:<n>:<edition>` | 偏好版本的 entry id |
| 青空文庫 | 作品 ID、人物 ID、NDC、讀音 | 只有 `catalogWorkID` 與書名（`AozoraLibraryDownloadService.swift:69-72`） |
| 網路書源 | `bookSourceUrl`＋詳情 URL | `bookSourceId`（裝置本地 UUID）＋`bookInfoURL` |

## 6. 閱讀進度

| 資料 | 位置 | 同步 |
|---|---|---|
| 文字書精確位置 `CoreTextReadingPosition(spineIndex, charOffset, translationOffset?)` | `Application Support/reading_position/<id>.json`，`JSONFileReadingPositionStore`（`Modules/Core/ReaderCore/ReadingPositionStore.swift:10-62`），經 `AppDependencies.readingPositionStore` 注入 | **沒有任何管道同步。** Firestore 有 `readingPositions/<id>`，但 `dataSyncEnabled = false`（`Modules/Services/iCloud/FirestoreSyncManager.swift:43`） |
| 顯示用進度 `currentPosition`（0–1） | `ReadingBook` | 隨書籍紀錄同步 |
| 漫畫／PDF／固定版面位置、有聲書位置 | `ReadingBook` 的 `manga*`、`audio*` 欄位 | 隨書籍紀錄同步 |
| 書籤、劃線 | `ReadingBook.bookmarks`，以 `(spineIndex, charOffset)` 定位 | 隨書籍紀錄整筆同步，沒有逐筆合併（推論：兩台同時編輯時，較舊的一筆會整筆被覆蓋） |
| TXT 重新分章後的位置遷移 | `reading_position/<id>.txt-reindex.json` journal（`Modules/Core/TXT/TXTReaderIndexMigrationService.swift:15-35`） | 無 |
| Calibre 網頁閱讀器位置 | 推送 CFI 與 `pos_frac`（`Modules/Services/RemoteLibrary/CalibreProgressService.swift:174-184`） | 只寫不讀 |

同步管道：

| 管道 | 書籍鍵 | 內容 |
|---|---|---|
| iCloud 自動同步 | `id.uuidString`；雜湊 `stableHash(strippedForSync())`；時鐘 `lastOpenedDate ?? addedDate`（`ICloudSyncManager.swift:500-506`） | 只同步書架成員，逐本以「較新者勝」合併；不含目錄 |
| iCloud 書檔 | `"bookfile_" + SHA256(檔名)`（`ICloudSyncManager.swift:1240`） | 本機內容檔、青空原檔、`coverImagePath` |
| iCloud 手動備份 | 整個 `books_meta.json` | 覆寫後 `reloadFromDisk` |
| WebDAV 備份 | 整個 `/yuedu/books.json`（`Modules/Services/WebDAV/WebDAVManager.swift:176-221`） | 不合併、不含檔案與位置 |

### 6.1 iCloud 同步的結構

| 部分 | 現況 |
|---|---|
| 傳輸 | CloudKit 私有資料庫（`ICloudSyncManager.swift:223-235`）。每一種資料（書架、書源、取代規則、閱讀設定等）各是**一筆** `CKRecord`，內容是一個 JSON 檔（CKAsset）（`ICloudSyncManager.swift:163-175`、`ICloudSyncManager.swift:843`）。 |
| 合併單位 | 檔內每個項目是 `CloudSyncRecord { id, value, updatedAt, deleted }`（`ICloudSyncManager.swift:20-25`）。一本書就是一個項目：書名、分組、進度、書籤、封面、離線下載狀態全在同一個 `value` 裡。 |
| 偵測修改 | 本機保留一份 shadow，記錄每個 id 的雜湊與時間。雜湊與上次同步不同，就視為本機修改，時間記為「現在」（`ICloudSyncManager.swift:870-903`）。 |
| 雜湊的脆弱處 | 雜湊來自 `.sortedKeys` 的 JSON 編碼。註解記錄了 2026-09-23 的事故：鍵的順序不穩定，每次同步都把每本書當成修改，蓋掉了其他裝置較新的內容（`ICloudSyncManager.swift:847-855`）。 |
| 合併方式 | 每次同步都下載整個檔、逐項「較新者勝」、再上傳整個檔（`ICloudSyncManager.swift:554-597`）。 |
| 套用到本機 | 以遠端那一筆**整筆取代**本機紀錄，只保留本機的目錄（`BookStore.swift:2348-2405`）。 |
| 時機 | 開啟自動同步時，只在啟動與進入背景時同步，另外加上使用者手動（`yuedu_appApp.swift:226-228`、`263-265`）。沒有 CloudKit 訂閱或推播，所以另一台裝置要等下一次啟動或進入背景才會收到。 |
| 舊版本 | 2026-10-05 才把舊的 `books_meta`（整個陣列）拆成 `books_meta_v2`。新版本會收養舊版本裝置新增的書（`BookStore.swift:2413-2433`）。 |

由合併規則推得的後果（推論）：

- **不同欄位的修改會互相蓋掉。** A 讀了幾頁、B 加了一個書籤，同步後只留下較晚被標記修改的那一整筆，另一邊的修改消失。
- **裝置本地狀態也在同一筆裡。** 離線下載狀態與任務、相容性降級都會同步：
  - A 的下載進度一變，整本書就成了「現在修改」，可能在合併時蓋掉 B 較新的書籤或進度。
  - B 也會收到 A 的下載狀態；實際是否已下載，以磁碟為準（`Technotes/OfflineDownloadContract.md` 的不變量 3）。
- **打開一本書也會改變合併時鐘。** 合併時鐘是 `lastOpenedDate`，所以打開書本身就會讓這一整筆在合併時勝出。
- **精確位置不同步**（見上表）。
- **成本隨書架成長。** 每次同步都下載並上傳整個書架檔。

對新模型的意義有三點：

- **位置屬於具體副本。** `(spineIndex, charOffset)` 只在同一個檔案、同一份線上目錄裡才有意義。換源時，位置要靠章節標題對齊重新映射（`Modules/Features/Reader/ReaderView+SourceChange.swift:258-286`）。所以「閱讀進度」不能掛在作品上，只能掛在 `ReadingBook` 上。
- **作品頁的「繼續閱讀」要指向哪一份副本，必須另外決定。** 例如最近打開的那一份。
- **跨裝置精確位置同步不是現有功能。** 不要在本計畫中順手承諾。

## 7. Metadata 儲存

### 7.1 封面

| 種類 | 檔名 | 說明 |
|---|---|---|
| 匯入時抽出 | `<檔案UUID>_cover.jpg` | EPUB 封面重新編碼為 JPEG 0.85（`BookStore.swift:696-708`） |
| 線上書下載 | `<id>_cover.jpg`（`BookStore.swift:1475`） | 來源是 `coverUrl` |
| 使用者自選 | `CustomCovers/<id>_cover_custom_<8 hex>.jpg`（`BookStore.swift:1552-1554`） | 放在 `Covers` 以外，避免清快取時刪掉相簿來的圖（`StorageLocations.swift:75-83`） |
| 自選前的原圖 | `originalCoverImagePath` | 有「重設封面」；但同步只帶欄位，不帶檔案（`Models.swift:258-263`） |

「封面搜索」與「換封面」是現有唯一的「從其他來源補資料」功能，兩者都以書名＋作者比對：

- 「封面搜索」（`OnlineCoverSearchService`）查詢推書君與一片書喽兩個外部端點（§10.4）。
- 「換封面」（`ChangeCoverView`）從 `ChangeSourceCache` 與網路書源中找同名書的封面。

### 7.2 書名與作者：誰會覆寫

| 寫入者 | 位置 | 條件 |
|---|---|---|
| 書籍資訊（使用者） | `BookStore.updateBook`（`BookStore.swift:1228-1234`） | 空字串不覆寫 |
| 線上書重新抓詳情 | `BookStore.swift:2122-2131` | 書源的 `ruleBookInfo.canReName` 非空時，來源的書名會蓋過已知書名（`Models.swift:816-848`），使用者改過的書名也會被蓋掉。何時重新抓詳情見表下說明。 |
| Calibre 回寫 | `RemoteLibraryWritingService.swift:179-188` | 同一 Calibre 書的所有本機格式一起改 |
| WebDAV 改名 | `RemoteLibraryWritingService.swift:222-235` | 書名改成新檔名 |
| 匯入覆寫 | `LocalBookImportService.swift:51-54` | 匯入後套用呼叫端給的書名 |

線上書只有在 `forceInfoRefresh` 或目錄網址為空時才重新抓詳情（`BookStore.swift:1882`），實際發生在三種情況：

- 啟動刷新時，書沒有目錄網址或沒有章節（`Targets/Yuedu/SharedApp/yuedu_appApp.swift:325-334`）；
- 開書時需要修復（`ReaderView.swift:2980-3011`）；
- 連續幾章抓取失敗後（`ReaderView+OnlineChapterLoading.swift:95-104`）。

沒有任何一處記錄「這個值從哪裡來」，也沒有欄位可以讓使用者鎖定。

### 7.3 簡介、分類、字數等

| 來源 | 存在哪裡 |
|---|---|
| 網路書源 | `book_info_cache/<SHA256(sourceId\|正規化URL)>.json`（`Modules/Core/BookSource/BookSourceFetcher+Cache.swift:146-178`）的 `BookInfoPackage`（`Models.swift:768-849`），以及搜尋結果的 `BookOrigin`。書架本身不存。 |
| OPDS | 建立閱讀紀錄時丟掉 summary（`RemoteLibraryService.swift:62-67`）。 |
| EPUB | 不讀 OPF 的 description、subject、publisher、language。 |
| Legado 書架匯入 | 丟掉 `coverUrl`、`intro`、`kind` 與進度（`Modules/Services/Migration/LegadoMigrationManager.swift:6-17`、`79-99`）。 |
| Calibre 無線傳書 | 完整 metadata 只在 `calibre-wireless-device.json`；Calibre 之後送來的 metadata 更新只改這個檔，不改書（`CalibreWirelessService.swift:238-243`）。 |
| 青空目錄 | 目錄資料豐富（15 個欄位，`Modules/Services/PublicLibrary/AozoraCatalog.swift:34-54`），書只留書名與 `catalogWorkID`。 |

### 7.4 原始檔案

原始書檔從不被改寫，這點符合構想文件「不要直接、不可逆地覆蓋 EPUB 原始 Metadata」。唯一例外是青空轉檔的 EPUB 會重新產生（`Modules/Services/LibraryStore/AozoraBookRegenerator.swift:69`），它本來就是 App 自己的產物。

## 8. 遠端書庫：WebDAV／OPDS／Calibre

### 8.1 連線：類型與實例

| 概念 | 現況 |
|---|---|
| Provider Type | `RemoteLibraryKind { opds, webDAV, calibre }`（`Modules/Services/RemoteLibrary/RemoteLibraryConnection.swift:4-10`） |
| Source Instance | `OPDSCatalog`，別名 `RemoteLibraryConnection`。欄位為 `id`（隨機 UUID 字串）、`name`、`url`、`username`、`sortOrder`、`kind`、`syncProgress`（`Modules/Services/OPDS/OPDSCatalog.swift:4-36`）。 |
| 持久化 | `Library/opds_catalogs.json`。帳號與密碼存 Keychain：`opds_user_<id>`、`opds_pw_<id>`。不同步、不備份。 |
| 內建實例 | `builtin.gutenberg`（`Modules/Services/PublicLibrary/PublicLibrary.swift:3-14`），不寫入檔案、不能編輯刪除。`PublicLibraryID` 另預留 `builtin.aozora`，但青空不是 OPDS 連線。 |
| 註冊表 | `OPDSCatalogStore.shared`。它**不是** `@MainActor`，`clients` 字典也沒有鎖（`OPDSCatalog.swift:40-45`）；推論：目前安全，是因為所有呼叫都在主執行緒。 |

另有三點：

- 新增連線不檢查重複。OPDS 預設範例「Project Gutenberg」與內建連線是同一個網址（`OPDSCatalog.swift:47-49`），加入範例會得到第二個實例 id。
- WebDAV 備份帳號在 UserDefaults，瀏覽連線在 Keychain。第一次啟動時，會把備份帳號複製一份成瀏覽連線（`OPDSCatalog.swift:63-73`），之後兩者各自獨立。
- **WebDAV 備份的密碼以明文存在 UserDefaults**（`WebDAVManager.swift:61-63`），見 §16。

### 8.2 瀏覽

| 書庫 | 瀏覽 | 分頁 | 搜尋 | 狀態擁有者 |
|---|---|---|---|---|
| OPDS 1 | 導覽 entry | `rel=next`＋「載入更多」 | OpenSearch／模板，**每個 feed 各自決定** | `OPDSBrowseModel`（`Modules/Services/OPDS/OPDSBrowseModel.swift:6-98`） |
| OPDS 2 | `navigation`／`groups`／`publications` 攤平成 OPDS 1 模型（`OPDS2FeedParser.swift:64-213`） | `next` | URI 模板的 `query` | 同上 |
| Calibre 內容伺服器、Calibre-Web | 全走 OPDS | 同上 | OPDS 搜尋；404「No books found」視為空結果（`Modules/Services/OPDS/OPDSClient.swift:137-153`） | 同上 |
| WebDAV | `PROPFIND Depth:1`（`Modules/Services/WebDAV/WebDAVBrowseClient.swift:31-40`） | 無 | 只篩目前資料夾的名稱 | **view 自己呼叫網路**（`Modules/Features/Bookshelf/RemoteImportViews.swift:117-135`） |

瀏覽列是各書庫自己的型別：OPDS 用 `OPDSEntry`，WebDAV 用 `WebDAVBrowseClient.Entry`。進入詳情時才由 `RemoteLibraryBookRoute.init(entry:connectionID:)` 轉成共用的 `RemoteLibraryItem`（`Modules/Features/Bookshelf/RemoteLibraryBookDetailView.swift:10-41`）。轉換時會丟掉以下資料：

- `authorNames` 陣列；
- 作者目錄連結；
- WebDAV 的 ETag 與修改時間。

OPDS 模型沒有 facets、排序、`up`／`start`、分類標籤、系列、出版日期、語言、ISBN、間接取得、OPDS Authentication Document（`OPDSClient.swift:43-76`）。

### 8.3 身分與「是否已在書庫」

- **`RemoteBookReference`**（`RemoteLibraryItem.swift:34-43`）：
  - 欄位為 `connectionID`、`entryID`、`format`、`version`、`contentLength`、`entityTag`、`lastModified`、`cachedFilename`、`offlineFilename`。
  - 匹配鍵是 `(connectionID, entryID, 副檔名)`（`RemoteLibraryItem.swift:45-48`）。
- **各書庫的 `entryID`：**

  | 書庫 | `entryID` | 弱點 |
  |---|---|---|
  | OPDS 1 | Atom `<id>`；沒有時用第一個下載網址或導覽網址（`OPDSClient.swift:294`） | 退回網址時會隨伺服器網址變動 |
  | OPDS 2 | `metadata.identifier`，沒有時用網址 | 同上 |
  | Calibre | OPDS 的 `urn:uuid:…` | |
  | WebDAV | 檔案的完整 URL | 在 App 外改名或搬移就變成新的閱讀紀錄（推論） |
- **查找：** 只有 `RemoteLibraryService.book(for:format:store:)` 一個入口，它逐筆掃描全部閱讀紀錄（`RemoteLibraryService.swift:41-43`）。
- **書況顯示：** 只有詳情頁會顯示「已在書架／已下載」，瀏覽列表不會。
- **同一本書被拆成多筆的情況：**
  - 同一本書的 EPUB 與 PDF 是兩筆紀錄。
  - 同一伺服器加兩次是兩個實例。
  - Calibre 無線傳來的書與從 Calibre OPDS 瀏覽到的同一本書互不相關。
- **改了連線網址之後：** 已存的下載網址不會更新（推論，`OPDSCatalog.swift:90-105`），要從詳情頁重新打開才會換成新網址（`RemoteLibraryService.swift:47-60`）。

### 8.4 能力矩陣

| 書庫 | 每本書的 metadata | 回寫 | 進度同步 |
|---|---|---|---|
| WebDAV | 檔名當書名、大小。沒有作者、封面、簡介、識別碼。 | 上傳、新資料夾、改名。能力是假設的，沒有向伺服器探測（`RemoteLibraryWritingService.swift:85-87`）。 | 無 |
| OPDS 1／2 | 書名、作者、簡介、封面、網頁連結、`<id>` | 無 | 無 |
| Calibre 內容伺服器 | 同 OPDS。推論：標籤、系列、評分只以文字留在簡介裡。 | 上傳、書名與作者（`/cdb/add-book`、`/cdb/set-fields`） | 只寫 EPUB 位置（`/book-set-last-read-position`），每個連線各自開關 |
| Calibre-Web | 同 OPDS | 無（`/ajax/library-info` 回 404） | 無 |
| Calibre 無線傳書 | 完整 metadata 只進登記檔 | 書單、刪除、回傳檔案 | 無 |
| Gutenberg（內建） | 書名、作者含作者目錄、簡介。列表只用 feed 內嵌縮圖。 | 無 | 無 |

App 沒有呼叫 Calibre 的 `/ajax/books`、`/ajax/search`、`/interface-data`，所以讀不到結構化的作者、標籤、系列、評分、識別碼。

### 8.5 快取

| 內容 | 位置 |
|---|---|
| 自動快取 | `Caches/RemoteLibrary/<id>/<sha256(version)>/`（`Modules/Services/RemoteLibrary/RemoteLibraryCache.swift:28-32`） |
| 明確下載的離線副本 | `Documents/remote_<id>.<ext>` |
| feed 與資料夾列表 | 不落地。連線 session 是 ephemeral（`Modules/Services/RemoteLibrary/RemoteLibraryHTTPClient.swift:34`）。 |

### 8.6 使用流程與匯入 sheet

1. **入口：書架的「＋」。**
   - iOS 18 以上是原生 `Menu`：從裝置匯入／WebDAV 書庫／OPDS 書庫／Calibre 書庫（`Modules/Features/Bookshelf/HomeView.swift:644-688`）。
   - iOS 17 走 `DismissalSequencedActionChooser`，在 `onDismiss` 才開目的地（`HomeView.swift:473-505`、`626-641`）。
2. **每種書庫各開一個 sheet。** sheet 內是 `RemoteLibraryBrowserView(kind:)`，有自己的 `NavigationStack`（`Modules/Features/Bookshelf/OPDSImportView.swift:10-31`）。流程是：連線列表 → `OPDSFeedView`／`WebDAVDirectoryView` → `RemoteLibraryBookDetailView`。
3. **詳情頁的三個動作彼此獨立：** 開始閱讀、加入書架、下載（`RemoteLibraryBookDetailView.swift:113-175`）。
4. **「從裝置匯入」：** 開 `AddBookView`，只有檔案與網址兩個分頁，不連到遠端書庫。網址匯入的抓取、解析與儲存都寫在 view 裡（`Modules/Features/Bookshelf/AddBookView.swift:275-350`）。
5. **UI 測試：** `Tests/iOS-UI/RemoteLibraryNavigationUITests.swift` 固定了「＋」下的三個入口；改導覽時這支測試必須一起改。

也就是說，構想文件描述的「匯入 → 選擇來源 → 開啟獨立 Sheet → 瀏覽書籍 → 匯入」，在程式裡確實是三個分開的 sheet。但 sheet 裡的瀏覽、詳情與閱讀已經共用。要改的是**入口與導覽的歸屬**，網路與閱讀層不必重寫。

## 9. 公有書庫

| 部分 | 現況 |
|---|---|
| 精選書單 | `PublicLibraryCollection` 是 Swift 字面值：4 份書單、16 個 Gutenberg ID（`Modules/Services/PublicLibrary/PublicLibraryCollections.swift:6-35`）。不另附資料檔。 |
| 封面 | 不下載，執行期由 `GeneratedBookCover` 依書名畫出（`Modules/SharedUI/Components/GeneratedBookCover.swift`）。 |
| Gutenberg | 內建 OPDS 連線，與書架的 OPDS 共用 `OPDSBrowseModel`。後者有兩處特判 Gutenberg：資料來源與搜尋網址（`OPDSBrowseModel.swift:31-37`、`53-54`）。只在使用者明確要求時才取一頁。 |
| 青空文庫 | 自建目錄：`AozoraCatalogStore`，固定網址 `https://yuedureader.com/catalogs/aozora/v1/`，有 SHA-256 驗證，24 小時最多檢查一次（`Modules/Services/PublicLibrary/AozoraCatalogStore.swift`）。<br>`AozoraCatalogIndex` 在背景建立讀音、NDC 分組與搜尋索引（`AozoraCatalog.swift:64-151`）。<br>推論：目錄 release 尚未發布，正式使用者目前看不到青空區塊（`Technotes/PublicLibraries.md`）。 |
| 選書 | 點書時凍結 `PublicLibraryBookSelection`，以 `.sheet(item:)` 呈現。sheet 有雙檔位與橫向翻頁（`Modules/Features/Explore/PublicLibrary/PublicLibraryBookSheet.swift`）。 |
| 取書 | Gutenberg：`RemoteLibraryBookDetailView(storefront: true)`，經 `RemoteLibraryService` 走閱讀、加入書架與下載。<br>青空：`AozoraLibraryDownloadService` 下載官方 ZIP 後交給 `AozoraBookImporter`，沒有獨立的「只下載」。 |
| 搜尋 | 青空在本機邊打邊搜，最多 50 筆，計算寫在 view 的 `body` 裡（`Modules/Features/Explore/PublicLibrary/PublicLibrarySearchResults.swift:18`）。<br>Gutenberg 只在送出時搜，一次一頁。 |
| 區域 | `PublicLibraryAvailability`：`countryCode != "CHN"`，冷啟動沿用上次已知的國家碼（`Modules/Services/PublicLibrary/PublicLibraryAvailability.swift`）。**gate 只在 `ExploreTabRoot` 的模式判斷這一處**（`ExploreTabRoot.swift:11-23`）。 |

公有書庫是目前最接近「CollectionProvider＋DiscoveryProvider」的實作：

- Gutenberg 就是 OPDS provider 的一個內建實例。
- 青空是「自建目錄」型 provider，附帶本機搜尋。

## 10. 網路書源解析機制

### 10.1 書源模型與身分

`BookSource`（`Modules/Core/BookSource/BookSource.swift`）完整承接 Legado JSON：

- 每個欄位都容錯解碼，規則組可以是物件或雙重編碼的字串。
- 規則組有搜尋、發現、詳情、目錄、正文、段評。段評只保留、不執行（`BookSource.swift:264-269`）。
- `bookSourceType` 為 0 文字、1 有聲、2 圖片、3 檔案；3 會退回文字（`BookSource.swift:453-459`）。
- 詳情規則的 `downloadUrls` 可以編輯，但沒有任何取書路徑會執行它。

身分分成兩套：`id` 是 UUID，JSON 沒帶就隨機產生；`bookSourceUrl` 才是真正的身分（`BookSourceStore.swift:639-644` 的註解）。各子系統分別選用：

| 以 `id`（裝置本地 UUID）為鍵 | 以 `bookSourceUrl` 為鍵 |
|---|---|
| `SourceHealthStore`、目錄／詳情快取的雜湊、`ReadingBook.bookSourceId`、`OnlineBook`／`BookOrigin.sourceId`、`ChangeSourceCache` | session 快取（`url#lastUpdateTime`）、`SourceRateLimit`、`SearchSourceScope`、`SearchResultCache`、執行期變數與登入、匯入與同步去重 |

持久化是 `Application Support/book_sources.json` 單一陣列：

- 寫入時合併、在背景以 1 MiB 串流寫出，再原子置換（`BookSourceStore.swift:823-922`）。
- 依註解，5 萬個書源約 290 MB。

### 10.2 解析管線

- **session：** `BookSourceSession.session(for:)` 以 `(url, lastUpdateTime)` 為鍵，保留 32 筆 LRU 的 `ModernParserBridge`；同一書源的解析依優先序排隊（`Modules/Core/BookSource/BookSourceSession.swift:42-205`）。
- **原生與 runtime 分流：** `shouldUseLegadoRuntimeFetch` 決定請求走原生路徑還是 Legado runtime（`BookSource.swift:842-873`）。

| 階段 | 程式 | 快取 |
|---|---|---|
| 搜尋 | `BookSourceFetcher+Search.swift:48-230` | `SearchResultCache`：只存第 1 頁，預設 5 天，不存空結果 |
| 詳情 | `BookSourceFetcher+BookInfo.swift:27-112` | `BookInfoPackage`，與已知搜尋結果合併（`Models.swift:801-848`），6 小時 |
| 目錄 | `BookSourceFetcher+TOC.swift:60-297` | `TOCPackage`，6 小時 |
| 正文 | `BookSourceFetcher+Chapter.swift:22-389` | `ChapterCacheRepository`，以書籍 UUID＋章節序號為鍵 |
| 發現 | `BookSourceFetcher+Discover.swift:7-46` | `DiscoverKindsCache`，只存分類列表 |

與「一個書源一個 bridge」規則不一致的地方（推論）：

- `BookSourceURLRendering` 另外為每個書源保留一個載入 `jsLib` 的 JSContext。這些 context 只以 URL 為鍵，數量不設上限，也從不失效（`Modules/Core/BookSource/BookSourceURLRendering.swift:290-363`）。
- 一次搜上百個書源時，32 筆 LRU 會一邊用一邊淘汰再重建。

### 10.3 JavaScript

- **引擎：**
  - 每個 bridge 有一個 `JSCoreEngine`。
  - 30 秒 watchdog 只放棄卡住的佇列，腳本本身繼續執行（`Modules/Core/RuleEngine/ModernParser/JS/JSCoreEngine.swift:323-354`）。
- **JS 能碰到的能力：**
  - `java.*`：HTTP、`importScript`、背景 WebView、任意網址的 cookie、瀏覽器、驗證碼、`deviceID`。
  - `source.*`：登入資訊、headers、`evalJS`。
- **`eval` 刻意開啟。** 理由是沙盒邊界在橋接層（`JSCoreEngine.swift:913-919`）。
- **`JSSandbox` 沒用在書源上。** 它可以移除全域、停用 `eval`、限制網域，但目前只用在對話氣泡腳本匯入（`Modules/Core/ReaderCore/Customization/DialogueBubbleScriptImporter.swift`）。
- **網路防護不一致。** `safeURL` 會擋非 http(s) 與私有位址，但只用在原生路徑（`Modules/Core/BookSource/BookSourceFetcher.swift:42-60`）。runtime fetch 與 JS 的 `java.*` 都不經過它，也不受 `SourceRateLimit` 限速。

所以 Legado 書源本身就是一種模組格式：宣告式規則加上受信任的 JS，能力組合固定為「搜尋＋發現＋詳情＋目錄＋正文」。第三方模組 runtime 若要開放，不能沿用這個橋接面（見設計文件 §14.2）。

### 10.4 已有的 Metadata provider 雛形

- **合併規則：** `BookInfoPackage.merging(searchResult:canReName:)`（`Models.swift:801-848`）是現成的欄位合併規則。書名與作者需要 `canReName` 才能覆寫，其他欄位以「新值非空就採用」合併。
- **封面搜索：** `OnlineCoverSearchService` 直接查詢推書君與一片書喽兩個外部端點，等於 Legado 的預設封面規則。兩個端點各自失敗、各自記錄（`Modules/Services/Online/OnlineCoverSearchService.swift:3-30`、`88-109`）。它用 `URLSession.shared`，不經 `WebFetcher`。
- **換封面：** 以書源搜尋同名書取得封面（`Modules/Features/BookDetail/ChangeCoverView.swift`）。結果型別 `CoverCandidate(sourceId:providerName:)` 已經是不同提供者共用的格式（`Modules/Features/BookDetail/CoverCandidateGrid.swift:8-21`）。
- **沒有任何書目資料庫的程式碼：** 程式中找不到 Douban、Open Library、Google Books 或 ISBN。起點、番茄的程式全部是書源相容處理，例如 CSRF cookie、段評、android-id、番茄登入。
- **AI 整理書架：** 它讀 `BookInfoPackage` 快取裡的分類與簡介，而且不看快取多舊（`AIBookshelfOrganizerModel.swift:128-138`）。所以這個快取實際上已經是線上書的 metadata 儲存。

## 11. 搜尋

### 11.1 「搜索」分頁

- **狀態擁有者：** `BookSearchView` 擁有 `@StateObject SearchAggregator`（`Modules/Features/Search/BookSearchView.swift:125`）。
- **觸發：** 送出才搜，沒有 debounce；清空就取消並清除。
- **範圍：** 全部已啟用書源，或自選的書源 URL。
- **並行：** `TaskGroup` 上限 1–30，預設 16。每個書源 12 秒逾時，JS 型 30 秒（`SearchAggregator.swift:404-421`；`SearchAggregator.swift:362` 的註解仍寫 15 秒）。
- **暫停：** 支援暫停、繼續、自動暫停。「載入更多」最多 5 輪。
- **發布：** `SearchResultPublicationGate` 每 0.5 秒最多發布一次，場景不活躍時不發布。
- **合併：** 在主執行緒進行，每 200 本讓出一次。
- **呈現：**
  - iOS 17 用 UIKit 的 `IOS17SearchResultTable`，iOS 18 以上用 SwiftUI `List`。
  - 路由是 `SearchResultRoute(id, snapshot)`，凍結選取當下的快照。
  - 目的地是獨立的 `SearchResultDestination`。
- **列的元件：** `SearchBookListRowContent` 已經有三種建構方式：搜尋結果、書架上的書、不在書架上的閱讀紀錄（`Modules/Features/Search/SearchBookListRow.swift:24-64`）。

### 11.2 合併與排序

- **`SearchBook` 是 class。** `name` 與 `author` 由第一個到達的來源決定，之後不再補（`SearchAggregator.swift:42-67`）。
- **合併條件：** 正規化後書名相等；作者只要一方為空，或互相包含（至少 2 字），就視為同一本（`SearchAggregator.swift:88-131`）。
  - 正規化只做小寫、全形轉半形、去空白。**不去標點**，雖然註解這樣寫；**也不做繁簡轉換**，雖然 ICU 的 `Traditional-Simplified` 在 `LegadoJSBridge` 已經在用。
  - 推論：第一個來源沒有作者時，之後任何作者的同名書都會併進來。
- **排序：** 完全符合 3 分、前綴 2 分、包含 1 分；同分再比書名長度與來源數（`SearchAggregator.swift:1135-1180`）。只符合作者的結果是 0 分。

「同一本書」的判斷至少有六套規則：

| 情境 | 規則 | 位置 |
|---|---|---|
| 搜尋合併 | 書名正規化相等＋作者相容＋與關鍵字相關 | `SearchAggregator.swift:1075-1117` |
| 換源、換封面 | `isLikelySameBook`（解析時先篩，之後再篩一次） | `Modules/Services/Online/BookOriginSearchService.swift:28-167` |
| 封面搜索 | 本機書名包含遠端書名；作者互相包含；作者未知就通過 | `OnlineCoverSearchService.swift:137-156` |
| `checkKeyWord` | 書名或作者包含關鍵字 | `BookSourceFetcher+Search.swift:232-243` |
| 已在書架 | 同 `bookSourceId`＋正規化 `bookInfoURL` | `BookStore.swift:1006-1021` |
| 最近閱讀、不在書架的紀錄 | `makeKey(title, author)` 完全相等 | `OffShelfReadRecords.swift:37-40` |

### 11.3 錯誤隔離

- **原生搜尋路徑把錯誤轉成空結果。** 401／403／404／429／5xx、編碼錯誤、空內容與解析錯誤都會回傳 `[]`，而且沒有記錄（`BookSourceFetcher+Search.swift:117-145`）。
- **聚合器把空結果當成功。** 它照樣呼叫 `SourceHealthStore.recordSuccess`（`SearchAggregator.swift:609-615`）。
- **後果：**
  - 「合法的空」與「失敗」分不開。
  - 被封鎖或已失效的書源永遠不會進冷卻。
  - 這違反 `CLAUDE.md` Engineering Discipline 的「Root cause before fallback」與「Don't swallow errors」。

統一搜尋的參與者協定必須能區分三種結果：有結果、合法的空、失敗（含原因）。否則跨來源的錯誤隔離無從談起。

### 11.4 其他語料各自的搜尋

| 語料 | 在「搜索」分頁？ | 自己的搜尋 |
|---|---|---|
| 網路書源 | 是 | — |
| 書架 | 否。只在搜尋欄空白時顯示「最近閱讀」3 本 | 無，`HomeView` 沒有 `.searchable` |
| OPDS、Calibre | 否 | 單一 feed 內的 OpenSearch（`OPDSClient.swift:187-226`） |
| Gutenberg | 否 | 送出才搜 OPDS 搜尋網址 |
| 青空文庫 | 否 | 本機索引，每打一個字都在 view 的 `body` 裡計算 |
| WebDAV | 否 | 只篩目前資料夾 |

### 11.5 iOS 17 watchdog 結案留下的約束

依據：`Technotes/iOS17SearchWatchdogPostmortem.md` 與 `CLAUDE.md` 的「Freeze data at search navigation boundaries」。任何新的搜尋 UI 都要守住下列幾點：

1. 路由帶完整的凍結快照，等值與雜湊只看 id。不要改回只帶 id、再回頭讀即時結果的路由。
2. 目的地是獨立的 view，不擷取搜尋頁或聚合器。
3. 每頁只有一個以 item 驅動的目的地（`SearchPagePush`）。新的結果種類要加成它的 case，不能再加第二個 `navigationDestination(item:)`。
4. 來源控制的文字與封面網址在進 SwiftUI 前就先截短、清理。不在 `body` 裡解析 HTML。
5. iOS 17 繼續用 UIKit 表格與有界的值型別列。
6. 結果經可感知場景狀態的 gate 發布；合併與身分計算不放在主執行緒。
7. 內嵌搜尋的父頁，用同一條混合 `NavigationPath` 推入搜尋頁。

`SearchBook` 的作者在第一個來源到達後就固定、`OnlineBook` 只能表達網路書源；這兩點使「把非書源的結果塞進 `SearchAggregator`」不可行。比較自然的切點是：把 `searchSingleSource`＋`mergeBatch` 抽成參與者協定，網路書源成為其中一個參與者。詳見設計文件。

## 12. 探索頁

### 12.1 結構

| 部分 | 現況 |
|---|---|
| 分頁根 | `.explore` 分頁的內容是 `BrowserView`（`Targets/Yuedu/SharedApp/ContentView.swift:365-366`），由它擁有瀏覽器狀態並承載 `ExploreTabRoot`。 |
| 模式 | `explore.mode` 為 `"libraries"` 或 `"sources"`（`Modules/Services/Online/ExploreSettings.swift:65-86`）。沒有書源時一律是公有書庫；中國區一律是書源；兩者都可用時，右上角選單切換。 |
| 升級遷移 | 啟動時只寫一次：已有書源的使用者是書源模式，新安裝是公有書庫（`Targets/Yuedu/SharedApp/yuedu_appApp.swift:92`）。 |
| 導覽 | 每種模式各有自己的 `NavigationStack`，切換時捨棄（`ExploreTabRoot.swift:4`）。<br>書源模式用 `ExploreNavigationPath`，是混合的 `NavigationPath`，內嵌的 `SearchView` 與其 `SearchResultRoute` 共用同一條 path，這是搜尋 watchdog 結案的要求。<br>公有書庫首頁與書籍 sheet 又各有一條 path。 |
| 標題與搜尋 | 兩個根都用 `.rootTabTitle(localized("探索"), onScroll: .minimizesBar)`。<br>書源模式的搜尋欄只篩書源磚塊；公有書庫的搜尋欄搜青空與 Gutenberg。 |
| 首次匯入提示 | TipKit `ExploreModeTip`（`Modules/Features/Explore/ExploreModeTip.swift`）。若統一首頁取代模式選單，這組旗標與除錯重設就不再需要。 |

### 12.2 書源的「發現」

- `DiscoverViewModel` 以 `BookSourceSession.session(for:)` 取分類，只快取健康的分類列表（`Modules/Services/Online/DiscoverViewModel.swift:414-480`）。
- 每個分類第一頁依序載入，一次一個（`DiscoverViewModel.swift:592-615`）。書單只存在記憶體。
- 分類快取在 `Caches/DiscoverKindsCache/`，沒有到期（`Modules/Services/Online/DiscoverKindsCache.swift`）。
- 分類勾選以書源 UUID 為鍵（`discover.categorySelection.<UUID>`），其他設定以 URL 為鍵，所以書源重新匯入後勾選會遺失。
- 第二頁以後的載入有三份實作：
  - `DiscoverViewModel.swift:625-673`；
  - `Modules/Features/Explore/DiscoverShowcaseView.swift:742-787`：寫在 view 裡，違反「view 不負責協調」；
  - `Modules/Services/Online/CustomExplorePageModel.swift:100-127`。

### 12.3 自訂探索頁：現有的「欄目」系統

| 部分 | 現況 |
|---|---|
| 頁 | `CustomExplorePage { id, name, components }`（`CustomExplorePageStore.swift:136-147`） |
| 元件 | `CustomExploreComponent { id, kind, title, categories: [ExploreCategoryReference] }`。`isComplete` 要求**單一書源**（`CustomExplorePageStore.swift:41-132`）。 |
| 版面 | 7 種：推薦卡片、排行榜、宮格、左右滑動、網絡排行榜、多分類排行榜、錯位瀑布流（固定最後）。 |
| 資料綁定 | `ExploreCategoryReference { sourceURL, title, url }`，只能指向書源的發現分類。 |
| 載入 | `CustomExplorePageModel`：一條序列 task 依序載入每一塊，直接呼叫 `BookSourceFetcher.shared.discoverBooks`。少了 `DiscoverViewModel` 會先做的起點 cookie 預熱（`DiscoverViewModel.swift:435`）。 |
| 持久化 | `Application Support/custom_explore_pages.json`，合成的 `Codable`，沒有 schema 版本。<br>**讀取失敗時 `pages` 維持空陣列；下一次任何修改都會把記憶體中的內容寫回，原有的頁就此被覆蓋**（`CustomExplorePageStore.swift:272-289`）。 |
| 編輯 | 原生 `List`：點一下改、左滑刪、拖曳排序、＋新增。新增流程是先選版面，再選書源與發現項。 |

它已經具備 HomeSection 需要的順序、版面、編輯器與持久化，缺的是：

- 啟用開關；
- provider 識別；
- 可容納非書源資料的綁定型別；
- 通用的區塊狀態（現在是 `DiscoverShowcaseSection` 裝 `OnlineBook`）；
- schema 版本與容錯解碼；
- 可用性 gate。

### 12.4 規範約束

- **`docs/design.md` §10「發現」原型：**「尊重書源作者的分類與內容，**不擅自重組成平台推薦流**」。構想文件的「為你推薦」若要跨來源重組內容，需要先修改這條規範，或者限定推薦只用本機書庫訊號。
- **分頁根白名單：** `docs/design.md` 與 `CLAUDE.md` 都明列五個分頁根 view，新的探索首頁要同步更新這份清單。
- **Gutenberg 的承諾：** 開首頁不發 Gutenberg 請求（`Technotes/PublicLibraries.md`）。會自己載入的 Gutenberg 欄目會違反這條。

## 13. 詳情頁

| 詳情 | 實作 | 共用元件 |
|---|---|---|
| 網路書源書 | `OnlineBookView`／`OnlineBookDetailDestination` | `BookDetailScaffold`、`BookDetailHero`、`BookDetailInfoStrip`、`BookDetailIntroSection`、章節區（`Modules/Features/BookDetail/BookDetailComponents.swift`） |
| 有聲書 | `AudiobookDetailView` | 同上 |
| 遠端書庫與 Gutenberg | `RemoteLibraryBookDetailView` | 同上 |
| 青空作品 | `AozoraWorkDetailView`（`Modules/Features/Explore/PublicLibrary/AozoraCatalogViews.swift`） | 同上 |
| 書架上的書 | `EditBookSheet`「書籍資訊」（`HomeView.swift:1248-1634`） | 不共用。是 `Form`：封面、書名、作者、分組、進度、來源。 |

`docs/design.md` 的「詳情」原型已要求共用 `BookDetailComponents.swift`、不另畫一份。統一作品詳情頁可以在這個 scaffold 上加「可用來源」區塊；不必另起爐灶。

「書籍資訊」的「來源」列只判斷 `book.source == "local"`（`HomeView.swift:1389`），所以本機 EPUB／PDF／漫畫／有聲書、遠端書都會被標成「網頁匯入」。這是 `source` 字串一欄多義的直接後果（§16）。

## 14. 跨領域觀察

| 主題 | 現況 | 對新架構的意義 |
|---|---|---|
| 持久化技術 | 全部是 JSON 檔與 UserDefaults；App 程式碼沒有 SQLite、Core Data 或 SwiftData（SQLite.swift 只是 Readium 的傳遞依賴）。 | 作品層第一版沿用 JSON 最一致。全文索引若要上 SQLite，是新技術，應等量測證明需要。 |
| 依賴注入 | `AppDependencies` 有 `remoteLibrary`、`aozoraLibrary`、`readingPositionStore` 等（`Targets/Yuedu/SharedApp/AppDependencies.swift:350-397`）。探索、OPDS 瀏覽、自訂頁仍直接用 `BookSourceFetcher.shared`、`OPDSCatalogStore.shared`、`CustomExplorePageStore.shared`。 | 新的 provider registry 應從 DI 注入，不再加 singleton。 |
| 並行 | `RemoteLibraryService`、`OPDSBrowseModel`、`CustomExplorePageStore` 是 `@MainActor`；`OPDSCatalogStore` 不是；`ChapterFetchManager` 是 actor。 | registry 應明確標 `@MainActor`。網路與解析在背景完成，結果回主執行緒。 |
| 錯誤處理 | `DiscoverKindsCache` 以 `try?` 吞錯；發現頁的錯誤只顯示不記錄。 | 新 provider 的失敗一律經 `AppLogger`。 |
| 效能量測 | `SourcePerfTrace` 已有 `publicLibrary.opds.load`、`aozora.catalog.load` 等 span。 | 統一搜尋與作品比對要先加 span，再談最佳化。 |
| 區域 gate | 只在 `ExploreTabRoot`。 | 必須移進 provider 可用性，並套用到新增欄目、搜尋與背景載入。 |
| iOS 17 | Menu 啟動的 modal 要用 `DismissalSequencedActionChooser`；書源管理與書籍資訊在 iOS 17 要 push；搜尋路由要凍結快照。 | 新首頁、新搜尋、新詳情都要遵守，不能只在 iOS 18 以上驗證。 |

## 15. 可以直接沿用的資產

| 資產 | 用在 |
|---|---|
| `RemoteLibraryService`（閱讀、加入書架、下載、資源生命週期） | 所有檔案型來源的 Acquisition |
| `OPDSClient`＋`OPDS2FeedParser`＋`OPDSBrowseModel` 的過期回應保護與分頁去重 | OPDS／Calibre／Gutenberg 的 CollectionProvider |
| `WebDAVBrowseClient.list`／`parseListing`、`RemoteLibraryWritingService` | WebDAV CollectionProvider |
| `CalibreServerAPI`（不會默默換書庫）、`CalibreProgressService` | Calibre provider |
| `RemoteBookReference` 的匹配與網址輪替處理 | 檔案型 SourceRecord |
| `AozoraCatalogStore`／`AozoraCatalogIndex`／`AozoraLibraryDownloadService` | 自建目錄型 provider |
| `PublicLibraryAvailability` | provider 可用性 |
| `CustomExplorePageStore` 的排序規則、版面列舉、編輯器列表 | HomeSection |
| `BookDetailScaffold` 系列元件 | 統一作品詳情 |
| `SearchBook.makeKey`、`isLikelySameBook` | 作品比對的第一層正規化 |
| `OnlineCoverSearchService`、`ChangeSourceCache` | 封面候選、多來源候選 |
| `GeneratedBookCover` | 沒有封面時的一致外觀 |

## 16. 審計中發現、不在本分支修正的問題

這些問題不屬於本計畫的範圍，列出來供維護者決定是否另開工作。

1. **WebDAV 備份密碼以明文存在 UserDefaults。**
   - 位置：`WebDAVManager.swift:61-63`、`113-118`。
   - 同一個 App 的書庫連線已改用 Keychain（`OPDSCatalog.swift:151-171`）。
2. **「書籍資訊」的來源列標錯。**
   - `HomeView.swift:1389` 只認 `"local"`，`"local_epub"`、`"local_pdf"`、`"local_manga"`、`"local_audio"` 與遠端書都顯示「網頁匯入」。
3. **iOS 17：選單裡的 `ShareLink`。**
   - `RemoteLibraryBookDetailView` 的公有書庫版面（`storefrontBody`）在工具列 `Menu` 裡放了 `ShareLink`（`RemoteLibraryBookDetailView.swift:279-291`）。這個版面本身就呈現在公有書庫的書籍 sheet 裡。
   - `Technotes/iOS17MenuModalPresentation.md` 明文禁止這種寫法：會產生呈現的 `ShareLink` 不能放在 iOS 17 的 SwiftUI `Menu` 裡；已經是 sheet 的畫面應把連結移出選單。
   - 公有書庫尚未在 iOS 17 runtime 上實測（`Technotes/PublicLibraries.md`）。
4. **自訂探索頁讀取失敗後，下一次修改會覆蓋原檔。** 解碼失敗只記錄，不保留原檔；之後任何新增或刪除都會把記憶體中剩下的內容寫回（`CustomExplorePageStore.swift:272-289`）。
5. **刪書只清一部分。** `BookStore.delete`（`BookStore.swift:1279-1368`）留下以下資料：
   - `reading_position/<id>.json`；
   - `manga/<id>`；
   - AI 摘要、翻譯、索引、角色卡與對話；
   - `ChangeSourceCache`；
   - 封面檔。
6. **合約測試過期。**
   - `Tests/Contracts/ExploreMixedNavigationPathContract.swift:12` 使用已不存在的 `.search(String)` 路由。
   - 推論：若單獨編譯會失敗。
7. **舊匯入流程留下的無呼叫程式：**
   - `OPDSClient.download`（`OPDSClient.swift:175-185`）；
   - `searchFeedURL(descriptionURL:)`（`OPDSClient.swift:204-207`）；
   - `WebDAVBrowseClient.download`（`WebDAVBrowseClient.swift:63-73`）。
8. **書籤解碼失敗會整批消失。** 一筆格式錯誤的書籤就讓整本書的書籤變成空陣列（`Models.swift:368`）。
9. **原生搜尋把失敗記為成功。** 見 §11.3：被封鎖的書源不會進冷卻，使用者也看不到原因。
10. **HTTP 防護與限速不一致。**
    - `safeURL` 的協定與私有位址檢查，以及 `SourceRateLimit`，只用在原生路徑。
    - runtime fetch 與 JS `java.*` 不經過它們。
    - 封面搜索直接用 `URLSession.shared`。
11. **註解與實作不符：**
    - 逾時寫 15 秒，實際 12 秒（`SearchAggregator.swift:362`）；
    - 正規化寫「strip punctuation」，實際不去標點（`SearchAggregator.swift:88`）；
    - 寫「eval is disabled」，實際開啟（`JSCoreEngine.swift:922`）。

## 附錄 A：以 `ReadingBook.id` 為鍵的儲存

| 類別 | 儲存 |
|---|---|
| 書庫附屬 | `books_meta.chapters/<id>.json`、`BookReaderSettings.bookID`、UserDefaults `fixedPage.readingMode.<id>`（舊） |
| 位置 | `reading_position/<id>.json`、`<id>.txt-reindex.json`、`txt_chapter_cache/<id>.json` |
| 線上與離線內容 | `online_cache/<id>/…`（`Modules/Services/Online/ChapterCacheRepository.swift:368-390`）、離線章節（`Modules/Services/Offline/OfflineChapterStore.swift:14-32`）、`local_manga/<id>/`、`manga/<id>/` |
| 遠端書庫 | `Caches/RemoteLibrary/<id>/…`、`Documents/remote_<id>.<ext>` |
| 換源 | `Caches/ChangeSourceCache/<id>.json` |
| 封面 | `Covers/<id>_cover.jpg`、`CustomCovers/<id>_cover_custom_*`、App Group `DownloadActivityCovers/<id>.jpg`；預設封面的挑選以 `id` 為種子（`Modules/Features/Bookshelf/BookshelfCoverArtwork.swift:195`） |
| AI | `AIBookIndexes/<id>.json`、`AICharacterCards/<id>.json`、`AICharacterMemory/<id>/`、`AIBookSummaries/<id>.json`、`AITranslations/<id>/…`；UserDefaults `yd_ai_chats.<id>` 等 |
| 朗讀 | `yd_tts_role_voices` 的鍵 `"<id>\u{1F}<角色>"`（`Modules/Core/TTS/TTSRoleVoiceCast.swift:124-132`） |
| 統計 | `Library/reading_stats.json` 的 `ReadingSession.bookId`（`Modules/Services/Stats/ReadingStats.swift`） |
| Calibre | `calibre-wireless-device.json` 的 `bookID`、`CalibreProgress/pending.json` |
| 同步 | iCloud `books_meta_v2` 的項目 id 與 shadow、WebDAV `books.json` |
| 系統整合 | Live Activity 的 `Book.id` 與暫停 intent、區網伺服器 `GET /book/<id>` |
| 檔案內嵌 | `ChapterPackage.bookId`、TXT journal、AI 索引載入時核對 `bookID` |

## 附錄 B：回歸測試對照

改動對應領域時，至少執行下列類別（`Tests/iOS/yuedu appTests/`，UI 測試在 `Tests/iOS-UI/`）。

| 領域 | 測試類別 |
|---|---|
| 書庫與身分 | `BookStoreMetadataWriteBudgetTests`、`RemoteReadingRecordTests`、`LocalBookImportServiceTests`、`BookmarkStablePositionTests`、`ICloudAudioSyncExclusionTests` |
| 遠端書庫 | `RemoteLibraryServiceTests`、`RemoteLibraryConnectionTests`、`RemoteLibraryHTTPTests`、`RemoteLibraryWritingTests`、`RemoteLibraryBrowsePresentationTests`、`RemoteLibraryReadFailureTests`、`RemoteEPUBPublicationTests`、`RemotePDFReaderTests`、`CacheManagementServiceTests` |
| OPDS | `OPDSParserTests`、`OPDS2ParserTests`、`GutenbergOPDS2FixtureTests` |
| Calibre | `CalibreProgressTests`、`CalibreWirelessProtocolTests`、`CalibreWirelessReceiverTests`；連線實測（需 `YUEDU_LIVE_CALIBRE_URL`）：`LiveCalibre*Tests` |
| 公有書庫 | `PublicLibraryRegistryTests`、`PublicLibraryStorefrontTests`、`PublicLibraryAvailabilityTests`、`AozoraCatalogTests`、`AozoraCatalogStoreTests`、`AozoraLibraryDownloadServiceTests`、`AozoraBookImportTests` |
| 探索 | `ExploreModeTests`、`ExploreHomeLogicTests`、`ExploreNavigationAndMetadataTests`、`ExploreSettingsTests`、`CustomExplorePageTests`、`DetailReaderStackTests` |
| UI | `RemoteLibraryNavigationUITests`、`PublicLibraryExploreUITests`、`PublicLibraryStorefrontUITests`、`PublicLibraryLiveUITests`（opt-in） |

`CustomExplorePageModel` 的載入、`DiscoverViewModel.reload` 與 `DiscoverKindsCache` 目前沒有單元測試，自訂頁也沒有 UI 測試。把它們改成 HomeSection 之前，應先補上描述現況的測試。
