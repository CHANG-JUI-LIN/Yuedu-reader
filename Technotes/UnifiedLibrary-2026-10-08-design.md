# 統一書庫與探索：資料模型與遷移計畫

> 日期：2026-10-08
> 狀態：**設計，尚未實作。** 需要維護者拍板的事項集中在 §17；拍板前不開工。
> 依據：
> - [現況架構審計](UnifiedLibrary-2026-10-08-audit.md)，下文以〈審計〉§x 引用；
> - 維護者〈Yuedu 下一代架構：統一探索、刮削與模組系統〉（2026-10-08），下文稱「構想文件」；
> - §11 的外部查證。
> 範圍：書庫資料模型、作品與來源的身分、Metadata 合併、來源能力協定、統一搜尋、探索首頁、作品詳情，以及從現況走到那裡的遷移步驟。閱讀器排版引擎不在範圍內（構想文件 §12）。

## 0. 一句話

作品是新加的一層，存在 `ReadingBook` 旁邊的獨立檔案裡，分成「可整個刪掉重建的索引」與「使用者的決定」兩份。`ReadingBook` 不改名、不換 id、不批次補欄位，成為作品底下的「閱讀副本」。所有來源只透過能力協定提供資料，既有的網路、認證、下載與閱讀管線全部沿用。iCloud 同步則改成以「實體」為合併單位（§15 的 Phase S）：書籍資料、閱讀狀態、每一筆書籤與使用者決定分開合併，裝置本地的狀態不再同步。

## 1. 目標與非目標

**目標**

1. 「同一部作品」成為可持久化的實體。系統依證據強弱自動歸併，使用者可以確認、合併或拆開。
2. 每個 Metadata 欄位都知道值從哪裡來。使用者可以修改並鎖定欄位，刷新不再蓋掉使用者改過的值。
3. 下列來源依各自具備的能力，透過同一組協定提供「瀏覽」「搜尋」「Metadata」「首頁欄目」，並回報可用的取得方式：
   - 書架
   - WebDAV
   - OPDS
   - Calibre
   - Gutenberg
   - 青空文庫
   - 網路書源
   - 書目資料庫
4. 達成構想文件 §14 的最小可行驗證：同一個搜尋框搜尋書架、Calibre、OPDS 與一個網文 Metadata 來源，並把同一部作品合併成統一詳情頁（驗收條件見 §16）。
5. 沒用過新功能的使用者，升級後的畫面與閱讀進度完全不變；同步的改變只有「不再互相蓋掉」，不會遺失資料。
6. iCloud 同步改以實體為單位：不同欄位、不同書籤的修改不再互相覆蓋；裝置本地狀態不再同步；另一台裝置不必重啟就能收到更新（§15 的 Phase S）。

**非目標**

- 不重新編號 `ReadingBook.id`，不改 `books_meta.json` 的格式。
- 精確閱讀位置現在完全不同步（〈審計〉§6）。它放在 Phase S3，前提是位置先帶上座標版本；在那之前不承諾。
- 不做段評、付費章節、帳號池或段落比對（構想文件 §6.5）。
- 第一版不開放下載第三方 JavaScript 模組（§14）。
- 不做演算法式的個人化推薦（構想文件 Phase 7）。跨來源的聚合首頁則在範圍內（§13）。
- 不把書架改成以作品分組；書架仍然顯示副本。

## 2. 與構想文件的差異

審計後，有幾處建議與構想文件的字面安排不同。每一處都附理由，維護者可以推翻。

| 構想文件 | 本計畫 | 理由 |
|---|---|---|
| §7「書籍作品應成為第一級實體」 | 作品是**旁邊**的一層。`ReadingBook` 保留為副本，不被作品取代。 | 25 個以上的儲存以 `ReadingBook.id` 為鍵；iCloud 以每本書的雜湊合併（〈審計〉§1 第 2、3 點）。 |
| §6.4「寫入統一作品資料庫」 | 拆成「可重建索引」與「使用者決定」兩個檔案 | 索引壞了就刪掉重建，不必遷移；只有使用者的決定需要妥善保存。 |
| §6.2「起點、番茄、晉江」 | 第一個網文 Metadata 來源，用**使用者自己的書源**的詳情規則；內建網文平台解析要等條款審查完成（§17 第 4 項） | 書源詳情規則已能產出簡介、分類、字數與封面（〈審計〉§10.4），而且不必由 App 內建爬蟲。 |
| §8.2「已建立索引的 WebDAV 書籍」 | 第一版不爬 WebDAV。統一搜尋只查各來源本身支援的搜尋，加上本機已知的紀錄。 | WebDAV 沒有伺服器端搜尋，建索引等於遞迴 PROPFIND（〈審計〉§8.2）；量測前不承諾。 |
| §11 Phase 1 → 7 依序進行 | 前面加一個 Phase 0（補描述現況的測試、修錯誤語意），並以一條橫切各階段的「MVP 切片」先打通驗證 | 審計發現：搜尋把失敗當成功、WebDAV 瀏覽寫在 view 裡、自訂頁讀檔失敗會覆寫原檔。這些不先修，新層會建在錯的訊號上。 |
| §3.1「為你推薦」 | 首頁參照 Jellyfin：跨來源聚合的「繼續閱讀」「最新」，加上每個來源各自的列；可切換成只看單一來源。「相關」v1 只用書架上的訊號 | 維護者 2026-10-08 決定：首頁可以像 Emby 一樣聚合（§13.1）。演算法推薦仍留在 Phase 7。 |
| §12「不丟失閱讀進度和使用者設定」，沒有提到同步 | 新增 Phase S：把 iCloud 同步改成以實體為單位（維護者 2026-10-08 提議納入本次改版） | 現在的同步以「整本書」為合併單位，不同欄位的修改會互相蓋掉，裝置本地狀態也被同步（〈審計〉§6.1）。作品層的決定也需要一個可靠的同步通道。 |

## 3. 決定

**D1　`ReadingBook` 是閱讀副本（Copy）。**
- 不換 id。換 id 要改寫 25 個以上的儲存，卻解決不了任何問題；問題出在合併單位，不在 id。
- `ReadingBook` 型別暫時保留，Phase S1 之後改成由各實體組合出來的檢視（§15 的 Phase S）。
- 只要 `books_meta_v2` 還在同步，就不新增非 optional 欄位，也不為所有書批次寫入新欄位（〈審計〉§4.3）。
- 進度、書籤、快取、離線下載、每本書設定，繼續掛在副本上。
- 理由：位置 `(spineIndex, charOffset)` 只在同一個檔案或同一份線上目錄裡才有意義（〈審計〉§6）。

**D2　作品層存在獨立檔案，分成「索引」與「決定」。**
- 索引（Work、Edition、SourceRecord、識別碼與比對證據）完全由既有資料推導，可以隨時刪除重建，不同步。
- 決定（手動合併、拆開、欄位覆寫、鎖定、選用的候選）是唯一的權威資料，量小。Phase S2 起以 v3 同步的 `WorkDecision` 實體同步（§15 的 Phase S）。

**D3　決定綁在來源項目的鍵上，不綁在作品 id 上。**
- 決定引用 `SourceItemKey`，例如「這兩個項目是同一部」「這兩個項目不是同一部」「這個項目的書名改成 X」。
- 所以重建索引不會遺失決定；作品 id 只需要在單次執行內保持穩定。
- 畫面的路由一律凍結快照（〈審計〉§11.5），不靠作品 id 回頭查詢。

**D4　來源的鍵使用可攜的身分，不用裝置本地的 UUID。**
- 網路書源用 `bookSourceUrl`，不用 `BookSource.id`（〈審計〉§5.2、§10.1）。
- 書目與公有書庫用它們自己的編號。
- 遠端書庫暫時用 `OPDSCatalog.id`，它是裝置本地的 UUID。作品決定在 Phase S2 開始同步之前，必須先定出可攜鍵（§17 第 3 項）。

**D5　保守去重。**
- 只有共同的外部識別碼，或同一個來源項目，才算確定是同一部作品。
- 書名＋作者完全相符、而且內容形態與語言相容時，自動歸併，但標示「依書名與作者判斷」，使用者可以拆開。
- 只有書名相同時，只顯示建議。
- 譯本、漫畫改編與有聲版不會自動歸併（§7）。

**D6　Metadata 由單一 resolver 決定生效值。**
- 每個欄位保留所有來源的值與來源資訊。
- 優先序：使用者覆寫 > 使用者鎖定 > 使用者選用的候選 > 欄位的來源優先序 > 檔案原始值。
- `ReadingBook.title`／`author`／封面，繼續作為「這份副本的顯示值」。只有在使用者明確套用時才寫回，以維持既有的畫面與同步不變。
- 既有的覆寫路徑都要先檢查鎖定：線上書刷新、Calibre 回寫、WebDAV 改名（〈審計〉§7.2）。

**D7　依能力拆成多個小協定，不做一個大協定。**
- 瀏覽、搜尋、Metadata、首頁欄目各一個協定。
- 取得不另立協定：仍由既有服務執行，provider 只回報有哪些取得方式（§5）。
- 內建來源以 adapter 包既有服務，不新增 HTTP client、快取或解析器。
- 這符合 `CLAUDE.md` 的「One path per concern」。

**D8　統一搜尋是新的協調器，加上參與者協定。**
- `SearchAggregator` 的行為不變，被包成「網路書源」參與者。它的並行、暫停、快取、健康度與 iOS 17 路由規則都沿用。

**D9　探索首頁是「一頁由欄目組成」。**
- 把自訂探索頁的模型一般化，探索首頁就是其中一個特別的頁。
- 中國區的 gate 移到來源的可用性判斷。
- `explore.mode` 轉成預設的欄目順序，保留一個版本供回退。

**D10　沿用 JSON 持久化。**
- App 目前沒有任何資料庫（〈審計〉§14）。
- 只有在量測顯示 JSON 載入或查詢超過預算時，才引入 SQLite（§10.4）。

## 4. 概念模型

術語對照 FRBR，與構想文件 §7 的名稱一致：

| 名稱 | 意思 | 例子 |
|---|---|---|
| `Work` 作品 | 抽象作品 | 《三體》 |
| `Edition` 版本 | 語言或文字系統、內容形態（文字／漫畫／有聲）、譯者 | 簡體中文文字版、繁體中文文字版 |
| `SourceRecord` 來源紀錄 | 某個來源實例對某個版本的描述 | 「我的 Calibre」裡 uuid 為 X 的那本 |
| `Acquisition` 取得方式 | 開啟副本、線上閱讀、下載某個格式、只有書目資料 | Calibre 的 EPUB 下載 |
| `Copy` 閱讀副本 | 就是 `ReadingBook`：進度、書籤、快取都在這裡 | 書架上那本 |
| `MetadataRecord`（型別草案中的 `MetadataValue`） | 欄位值＋來源＋取得時間 | 簡介來自 Open Library |

```
Work《三體》
├─ Edition：zh-Hans · 文字
│  ├─ SourceRecord  library/local · <Copy A 的 id>      → Copy A（ReadingBook，本機檔，有進度）
│  ├─ SourceRecord  calibre/<連線> · urn:uuid:X         → 取得：線上讀 EPUB／下載 EPUB、PDF
│  └─ SourceRecord  bookSource/<書源 URL> · <詳情 URL>  → Copy B（ReadingBook，線上書）
├─ Edition：zh-Hant · 文字
│  └─ SourceRecord  opds/<連線> · <entry id>            → 取得：線上讀／下載
└─ MetadataRecord × N（書名、作者、封面、簡介、分類 × 各來源）
```

幾條不變量：

- 一份副本在任何時刻只有一個「目前來源」。網路書換源時，是同一份副本改指向另一個來源，id 不變，位置以章節標題對齊重新映射（〈審計〉§6）。
- 一個來源紀錄可以沒有副本，例如搜尋結果裡的 Calibre 書。這類紀錄只存在於那一次搜尋；使用者對它做過動作（打開詳情、加入書架）才寫進索引（§7.3）。
- 閱讀進度只屬於副本。作品頁的「繼續閱讀」指向最近打開的副本。
- 書目資料庫的來源紀錄只有 `.viewOnly` 取得方式，永遠不顯示成可以閱讀。

## 5. 型別草案

以下是方向，不是最終 API；名稱以實作時的 code review 為準。全部是值型別、`Sendable`，可以凍結進路由。

```swift
/// 構想文件 §4.3 的「Provider Type」。
enum ProviderType: String, Codable, Sendable {
    case library                       // 書架與閱讀紀錄（本機）
    case opds, webDAV, calibre         // = RemoteLibraryKind
    case gutenberg, aozora             // 內建公有書庫
    case bookSource                    // Legado 書源
    case bibliographic                 // 書目資料庫（Open Library…）
}

/// 構想文件 §4.3 的「Source Instance」。
struct SourceInstanceKey: Hashable, Codable, Sendable {
    var type: ProviderType
    /// library: "local"；opds/webDAV/calibre: OPDSCatalog.id；
    /// gutenberg/aozora: PublicLibraryID；bookSource: bookSourceUrl；bibliographic: provider id
    var id: String
}

/// 來源內的一個項目。決定（D3）只引用這個鍵。
struct SourceItemKey: Hashable, Codable, Sendable {
    var instance: SourceInstanceKey
    /// library: ReadingBook.id；OPDS/Calibre: entryID；WebDAV: 相對於連線根目錄的路徑；
    /// bookSource: 正規化的詳情 URL；aozora: 作品 ID；gutenberg: 電子書編號；bibliographic: 該庫的 work id
    var item: String
}

struct ExternalIdentifier: Hashable, Codable, Sendable {
    enum Scheme: String, Codable, Sendable {
        case isbn13, calibreUUID, gutenberg, aozoraWork, openLibraryWork, openLibraryEdition, wikidata
        case epubUniqueIdentifier   // OPF 的 dc:identifier，只在同一 scheme 內比對
    }
    var scheme: Scheme
    var value: String               // 正規化：ISBN-10 轉 13、去連字號、uuid 小寫
}

enum ContentKind: String, Codable, Sendable { case text, comic, audio }

/// 搜尋結果、首頁欄目、作品頁共用的顯示摘要。建構時就截短與清理（〈審計〉§11.5 第 4 點）。
struct WorkSummary: Hashable, Sendable {
    var title: String               // ≤ 500 字
    var authors: [String]           // ≤ 20 位，每位 ≤ 200 字
    var cover: CoverReference?      // .copyFile(String) / .remote(URL, headers) / .generated(seed)
    var blurb: String?              // ≤ 300 字，純文字，不保留 <usehtml> 等腳本前綴
    var language: String?           // BCP 47，例如 zh-Hans
    var contentKind: ContentKind
}

struct SourceRecord: Hashable, Codable, Sendable {
    var key: SourceItemKey
    var title: String
    var authors: [String]
    var language: String?
    var contentKind: ContentKind
    var identifiers: Set<ExternalIdentifier>
    var copyID: UUID?               // 已有閱讀副本時
    var acquisitions: [AcquisitionOption]
}

enum AcquisitionOption: Hashable, Codable, Sendable {
    case openCopy(UUID)             // 打開既有副本
    case readRemote(format: String) // RemoteLibraryService.read
    case download(format: String)   // RemoteLibraryService.downloadOffline、AozoraLibraryDownloadService
    case readOnline                 // 網路書源
    case viewOnly                   // 書目資料庫：只有資料
}

enum MetadataField: String, Codable, Sendable {
    case title, authors, cover, intro, tags, series, seriesIndex, language, publisher, publishedDate,
         wordCount, serialStatus
}

struct MetadataValue: Hashable, Codable, Sendable {
    var field: MetadataField
    var value: MetadataPayload      // 文字、文字陣列、數字、日期、封面參照
    var provider: SourceInstanceKey // 使用者覆寫時是 .library/"user"
    var sourceItem: SourceItemKey?
    var fetchedAt: Date
}

/// works.decisions.json 的一筆。全部只引用 SourceItemKey（D3）。
enum WorkDecision: Codable, Sendable {
    case sameWork(SourceItemKey, SourceItemKey, decidedAt: Date)
    case differentWorks(SourceItemKey, SourceItemKey, decidedAt: Date)
    case override(anchor: SourceItemKey, field: MetadataField, value: MetadataPayload, decidedAt: Date)
    case lock(anchor: SourceItemKey, field: MetadataField, decidedAt: Date)
    case chooseCandidate(anchor: SourceItemKey, field: MetadataField, from: SourceItemKey, decidedAt: Date)
}
```

能力協定：

```swift
@MainActor
protocol SourceProvider: AnyObject {
    var instance: SourceInstanceKey { get }
    var displayName: String { get }
    /// 可用：.available / .hiddenInRegion（中國區 gate）/ .needsSetup / .catalogNotReady
    var availability: ProviderAvailability { get }
}

/// WebDAV、OPDS、Calibre、Gutenberg、青空、書架分組、書源發現分類。
protocol CollectionBrowsing: SourceProvider {
    /// Calibre 與 Calibre-Web 要等 /ajax/library-info 回來才分得出來（〈審計〉§8.4），所以能力是 async。
    func capabilities() async -> CollectionCapabilities
    func browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws -> CollectionPage
}

protocol CatalogSearching: SourceProvider {
    /// .asYouType：本機或本機索引（書架、青空）；.onSubmit：遠端（OPDS、Calibre、書源、書目資料庫）；
    /// .onExplicitRequest：每次搜尋都要使用者明確要求（Gutenberg 條款，〈審計〉§9）
    var searchPolicy: SearchPolicy { get }
    func search(_ query: SearchQuery) -> AsyncStream<SearchParticipantEvent>
}

enum SearchParticipantEvent: Sendable {
    case candidates([SearchCandidate])   // 已在背景截短、清理
    case finished(SearchOutcome)
}

/// 三態，對應〈審計〉§11.3：合法的空與失敗必須分開。
enum SearchOutcome: Sendable {
    case found(Int)
    case empty
    case failed(SourceFailure)           // 認證、網路、逾時、解析、被拒（HTTP 狀態）
}

protocol MetadataProviding: SourceProvider {
    func candidates(for query: MetadataQuery) async throws -> [MetadataCandidate]   // 書名、作者、識別碼
    func values(for candidate: MetadataCandidate) async throws -> [MetadataValue]
}

protocol HomeSectionProviding: SourceProvider {
    func templates() -> [HomeSectionTemplate]
    /// .serialPerSource：書源（共用 JS 狀態）；.parallel；.onDemandOnly：Gutenberg
    var loadPolicy: SectionLoadPolicy { get }
    func load(_ binding: HomeSectionBinding, page: Int) async throws -> HomeSectionPage
}
```

`Acquisition` 不另立協定：取得動作仍由既有服務執行，provider 只回報有哪些 `AcquisitionOption`。執行的服務如下：

- 遠端書庫：`RemoteLibraryService` 的 `read`、`addToShelf`、`downloadOffline`；
- 青空：`AozoraLibraryDownloadService`；
- 網路書源：`OnlineBookDetailDestination`。

## 6. 與現有型別的對應

| 現有 | 新模型 | 怎麼接 |
|---|---|---|
| `ReadingBook` | 副本，加上它目前來源的 `SourceRecord` | 純函式推導；不改型別 |
| `ReadingBook.remoteSource: RemoteBookReference` | `SourceItemKey(opds/webDAV/calibre, connectionID, entryID)`＋格式 | WebDAV 的 entryID 是絕對 URL，推導時轉成相對路徑 |
| `ReadingBook.bookSourceId`＋`bookInfoURL` | `SourceItemKey(bookSource, bookSourceUrl, 正規化 URL)` | 由 `BookSourceStore` 查 URL。查不到時保留 `bookSourceId` 的字串，標記為「書源已不存在」 |
| `ReadingBook.aozora.catalogWorkID` | `SourceItemKey(aozora, builtin.aozora, 作品 ID)`＋識別碼 `aozoraWork` | |
| 本機匯入的 `ReadingBook` | `SourceItemKey(library, local, id)` | 本機檔沒有外部身分。識別碼來自 OPF（Phase 1b） |
| `RemoteLibraryItem`、`OPDSEntry`、`WebDAVBrowseClient.Entry` | `SourceRecord`＋`WorkSummary`；導覽 entry 是 `CollectionEntry.folder` | `RemoteLibraryBookRoute.init(entry:)` 的轉換提前到瀏覽層，保留 `authorNames`、ETag |
| `OnlineBook`、`BookOrigin` | `SourceRecord(bookSource)` | |
| `SearchBook` | 「網路書源」參與者內部的合併結果，對外轉成 `SearchCandidate` | 不改 `SearchAggregator` 的合併規則 |
| `AozoraWork`、`GutenbergBook`、`PublicLibraryBook` | `SourceRecord(aozora / gutenberg)` | |
| `BookInfoPackage` | 多筆 `MetadataValue`，provider 是該書源 | 合併規則沿用 `merging(searchResult:canReName:)` 的精神 |
| `customCoverUrl`／`originalCoverImagePath` | `MetadataValue(cover, provider: user)`＋原始值 | 檔案位置不變 |
| `CustomExploreComponent` | `HomeSection(binding: .bookSourceCategories([ExploreCategoryReference]))` | §13 |
| `ChangeSourceCache` | 同一版本的其他來源紀錄候選 | 先唯讀引用 |
| `CoverCandidate` | `MetadataCandidate`，欄位是 `cover` | |
| `OffShelfReadRecords` | 不變 | 以後可由副本的閱讀紀錄推導 |

## 7. 身分解析與去重

### 7.1 單一正規化：`WorkMatchKey`

用來取代〈審計〉§11.2 的六套規則。先只用在新的作品層與統一搜尋；舊的搜尋合併與換源要等 Phase 4，有測試護欄後才換。

1. Unicode NFKC，包含全形轉半形；轉小寫。
2. 繁轉簡，只用在比對鍵，從不用在顯示文字。可用 ICU 的 `Traditional-Simplified`，`LegadoJSBridge` 已在使用。
3. 去掉空白、標點與符號：Unicode 的 P\* 與 S\* 類別，包括《》「」【】等。
4. 日文：平假名與片假名統一。青空作品另有讀音可當輔助鍵。
5. **不去數字，不去括號內的字。**「三體」與「三體II」，「斗罗大陆」與「斗罗大陆3」必須不同（`SearchAggregator.swift:97-104` 的理由）。網文常見的「（精校版）」「【完本】」等後綴，先量測真實資料，再決定要不要處理。
6. 作者另做一層正規化：沿用「互相包含且至少 2 字」的相容規則（`SearchAggregator.swift:125-131`）；若需要去掉「著」「作者：」等字樣，先量測、再列為規則。

### 7.2 信心等級

| 等級 | 條件 | 行為 |
|---|---|---|
| A 識別碼 | 共同外部識別碼（ISBN-13、Calibre uuid、Gutenberg 編號、青空作品 ID、Open Library work），或同一個 `SourceItemKey` | 自動歸併 |
| B 書名＋作者 | `WorkMatchKey` 書名相等；**雙方**作者非空且相容；內容形態相同；語言相容（未知視為相容；zh-Hans 與 zh-Hant 相容，但分屬不同版本） | 自動歸併，標示「依書名與作者判斷」，可拆開 |
| C 只有書名 | 書名相等，作者缺漏或不相容 | 不歸併；作品頁顯示「可能是同一部」建議 |
| 拒絕 | 語言明確不同、內容形態不同，或使用者拆開過 | 不歸併 |

B 級比現在的搜尋合併嚴格：現在只要一方作者為空就合併（〈審計〉§11.2）。這只套用在新的作品層，舊的搜尋行為暫時不變。

### 7.3 歸併演算法

確定性的 union-find，同一份輸入永遠產生同一份索引：

1. 每份副本推導出它目前的 `SourceRecord`。再加上使用者在瀏覽或搜尋時看過、且做過動作的遠端紀錄，例如打開過詳情或加入書架。
2. 套用 `differentWorks` 決定，作為禁止歸併的配對。
3. 依共同識別碼合併（A 級）。
4. 依 `WorkMatchKey` 分桶，桶內兩兩檢查 B 級條件後合併。
5. 套用 `sameWork` 決定。
6. 每個連通分量是一部作品；分量內依「語言或文字系統＋內容形態」分版本。Calibre 同一本書的多種格式屬於同一個版本。

拒絕永遠優先：使用者拆開過的兩個項目，之後任何證據都不會自動把它們合回去。

## 8. Metadata 合併

### 8.1 每個欄位的生效值

1. 使用者覆寫，也就是 `override` 決定。
2. 使用者鎖定：凍結鎖定當下的生效值，之後的刷新不改它。
3. 使用者在「識別」畫面選用的候選，也就是 `chooseCandidate`。
4. 依欄位的來源優先序取第一個非空值，預設如下表。
5. 都沒有時，用副本自己的原始值。

| 欄位 | 預設優先序 | 自動補齊 |
|---|---|---|
| 書名、作者 | 副本自己的值（檔案或該書源）→ 其他來源 | **不自動補**。書目資料庫的書名只在使用者選用時才採用 |
| 封面 | 使用者 → 副本自帶 → 書目資料庫 | 副本沒有封面，而且是 A 級相符時才補 |
| 簡介、分類、系列、語言、出版者 | 副本自帶 → A 級書目資料庫 → B 級需使用者確認 | 原值為空時才補 |
| 字數、連載狀態 | 該網路書源 | — |

### 8.2 `ReadingBook` 與 Metadata 儲存的分工

什麼時候寫 `ReadingBook`、什麼時候只寫 Metadata 儲存：

- **使用者明確「套用」書目資料：** resolver 經既有的 `BookStore.updateBook` 與封面 API 寫入，iCloud 把它視為一次使用者修改（本來就是）。
- **背景補齊：** 只寫進 Metadata 儲存，**不寫** `ReadingBook`，不讓 iCloud 雜湊無故改變（〈審計〉§4.3）。
- **既有的覆寫路徑：** 下列三處寫入書名或作者前，先查鎖定；有鎖定就跳過，並記一筆 `AppLogger`。
  - `BookStore` 的線上書刷新（`BookStore.swift:2122-2131`）；
  - Calibre 回寫（`RemoteLibraryWritingService.swift:179-188`）；
  - WebDAV 改名（`RemoteLibraryWritingService.swift:222-235`）。

  除了 Phase 1a 修正「來源」列的標籤，這是 Phase 1 唯一會改變既有行為的地方，而且只影響使用者鎖定過的書。

原始書檔永遠不改寫，與現況相同（〈審計〉§7.4）。

## 9. 來源能力與既有實作

| 來源 | 瀏覽 | 搜尋 | Metadata | 首頁欄目 | 取得 | 包的既有實作 |
|---|---|---|---|---|---|---|
| 書架 | 分組 | 邊打邊搜 | 檔案原始值、OPF | 繼續閱讀、同作者 | 打開副本 | `BookStore` |
| OPDS | ✓ | 送出才搜（依 feed） | 書名、作者、簡介、封面、識別碼 | 指定 feed | 線上讀、下載 | `OPDSClient`、`OPDS2FeedParser`、`OPDSBrowseModel`、`RemoteLibraryService` |
| Calibre | ✓（OPDS） | 送出才搜 | v1 同 OPDS；v2 讀 `/ajax/books` 的結構化欄位 | 最近加入 | 線上讀、下載 | 加上 `CalibreServerAPI` |
| WebDAV | ✓ | 只篩目前資料夾 | 無；v2 讀 EPUB 的 OPF | — | 線上讀、下載 | `WebDAVBrowseClient`（先移出 view，見 Phase 0） |
| Gutenberg | ✓ | 使用者明確要求 | ✓ | 隨 App 附帶的精選書單，開首頁不發請求 | 線上讀、下載 | `PublicLibrary`、`PublicLibraryCollection` |
| 青空文庫 | 目錄索引 | 邊打邊搜（移出 `body`） | ✓ | 新着 | 下載後轉檔 | `AozoraCatalogStore`、`AozoraLibraryDownloadService` |
| 網路書源 | 發現分類 | 送出才搜 | 詳情規則 | 發現分類、自訂頁 | 線上閱讀 | `BookSourceFetcher`、`SearchAggregator`、`DiscoverViewModel` |
| 書目資料庫 | — | 送出才搜 | ✓ | — | 只有資料 | 新增：第一個是 Open Library（§11） |

**provider 註冊表：**

- `@MainActor`，經 `AppDependencies` 注入（〈審計〉§14）。
- 依下列條件組出目前可用的實例：
  - `OPDSCatalogStore` 的連線；
  - `PublicLibraryAvailability`；
  - `BookSourceStore` 的啟用書源；
  - 設定中啟用的書目資料庫。
- `OPDSBrowseModel` 裡兩處 Gutenberg 特判（〈審計〉§9），移到 Gutenberg 實例自己的 adapter。

## 10. 儲存、同步、隱私

### 10.1 檔案

| 位置 | 內容 | 性質 | 同步 |
|---|---|---|---|
| `Application Support/Works/index.json` | 作品、版本、來源紀錄、識別碼、比對證據 | 衍生，可重建 | 否 |
| `Application Support/Works/decisions.json` | `WorkDecision` | **權威** | Phase S2 起經 v3 同步（§15 的 Phase S） |
| `Application Support/Works/metadata/` | `MetadataValue`，依 `SourceItemKey` 分片 | 衍生，可重新抓取 | 否 |
| `Caches/Works/` | 書目資料庫回應、封面候選 | 可丟棄 | 否 |

所有檔案都遵守下列規則：

- 頂層帶 `schemaVersion`。
- 容錯解碼。
- **讀取失敗時拒絕寫入**，避免重蹈〈審計〉§16 第 4 項的覆蓋問題。
- 寫入走序列佇列與原子置換，與 `BookStore` 相同。

`index.json` 的 schema 一變就整個丟掉重建；`decisions.json` 改版時，要寫明確的遷移與測試。

### 10.2 重建與增量更新

- **觸發：** 第一次需要索引時（打開統一搜尋或作品頁）在背景建立，不在冷啟動時建立。
- **增量更新：** 之後觀察 `BookStore.mutationRevision`，只更新有變動的副本。
- **刪書：** 移除對應的來源紀錄；引用它的決定保留但無作用。清理只在使用者「重設作品資料」時進行。

### 10.3 隱私

- **索引內容只留在本機：** Calibre 與 WebDAV 的書名會進索引，所以索引不同步、不上傳任何伺服器。
- **書名寫入日誌：** 涉及私人書庫書名的日誌，應先評估 `AppLogger` 的 privacy 標記。
- **統一搜尋的範圍：** 每個連線可以單獨排除。書目資料庫的查詢會把關鍵字送到第三方，預設要明確告知（§17 第 5 項）。

### 10.4 什麼時候改用 SQLite

先用 `SourcePerfTrace` 加三個 span：`works.index.build`、`works.index.load`、`works.search.local`。

以 2,000 份副本、5,000 筆遠端紀錄的合成資料量測：

- 載入超過 200 ms，或單次本機搜尋超過 16 ms，就評估 SQLite 加 FTS5。
- 這兩個門檻是建議值，請維護者確認。

在那之前不新增持久化技術。

## 11. 外部依據

2026-10-08 查證。這個環境的網路代理擋下 openlibrary.org、developers.google.com、jellyfin.org 與 manual.calibre-ebook.com；能直接讀到的是 Apple 審核指南，以及 GitHub 上的原始碼與文件。沒能讀到原文的項目已標明，實作前要再核對一次。

### 11.1 App Store 審核指南

來源：<https://developer.apple.com/app-store/review/guidelines/>（頁面沒有顯示更新日期）。

| 條文 | 原文重點 |
|---|---|
| 2.5.2 | Apps「may not download, install, or execute code which introduces or changes features or functionality of the app, including other apps.」 |
| 4.7 | 允許不在 binary 裡的「HTML5 and JavaScript mini apps and mini games, streaming games, chatbots, and plug-ins」，但 App 要為這些軟體負責，而且要遵守 4.7.1–4.7.5。 |
| 4.7.1 | 遵守隱私規範（5.1）；提供過濾不當內容、檢舉與及時回應、封鎖濫用者的機制；販售數位商品要遵守 3.1。 |
| 4.7.2 | 「Your app may not extend or expose native platform APIs or technologies to the software without prior permission from Apple.」 |
| 4.7.3 | 未經使用者每一次的明確同意，不得把資料或隱私權限分享給個別軟體。 |
| 4.7.4 | 必須提供軟體與 metadata 的索引，並以 universal link 連到每一個軟體。 |
| 4.7.5 | 必須讓使用者辨識超出 App 年齡分級的軟體，並以驗證或申報的年齡限制未成年者存取。 |

### 11.2 參考產品與做法

| 對象 | 查到的事實 | 來源 |
|---|---|---|
| Forward 模組 | 每個模組是一個 JS 檔，開頭是 `WidgetMetadata`：<br>- 頂層：`id`、`title`、`description`、`author`、`site`、`version`、`requiredVersion`、`detailCacheDuration`、`modules[]`、選填的 `search`。<br>- 每個 module：`functionName`、`type`、`params`、`cacheDuration`、`requiresWebView`。<br>- 參數型別：`input`、`count`、`constant`、`enumeration`、`page`、`offset`。<br>- 執行環境提供 `Widget.http.get/post`、`Widget.html.load`（cheerio）、`Widget.storage`、`Widget.sharedCache`。 | <https://github.com/InchStudio/ForwardWidgets> |
| Calibre 下載 metadata | 「calibre uses Google Books and Amazon. The metadata download can fill in Title, author, series, tags, rating, description and ISBN」。<br>有 ISBN 時，ISBN 優先於書名與作者。<br>批次下載可選只下載 metadata、只下載封面，或兩者都下載。 | calibre 原始碼 `manual/metadata.rst`（GitHub） |
| Jellyfin | 每個項目有 `ProviderIds: Dictionary<string, string>`、`IsLocked`、`LockedFields: MetadataField[]`；`MetadataField` 包含 Name、Overview、Genres、Tags 等。 | jellyfin/jellyfin 的 `BaseItem.cs`、`MetadataField.cs` |
| CKSyncEngine | 對應 WWDC23 第 10188 場〈Sync to iCloud with CKSyncEngine〉。<br>Apple 官方範例要求 iOS 17（beta 4）以上。<br>它依賴遠端推播，所以**模擬器無法正常同步，必須用真機或 Mac**。<br>範例附有模擬多台裝置的測試。 | <https://developer.apple.com/videos/play/wwdc2023/10188/>、<https://github.com/apple/sample-cloudkit-sync-engine> |

### 11.3 書目資料庫

| 來源 | 查到的事實 | 狀態 |
|---|---|---|
| Open Library | 以下來自第三方整理，未能讀到官方頁：<br>- 匿名約每秒 1 次；帶可識別的 User-Agent（App 名稱與聯絡方式）可提高額度。<br>- 不希望被當成服務的後端；大量需求請用每月資料傾印。<br>- 封面另有「每個 IP 每 5 分鐘 100 次」的舊限制，出自 2011 年的部落格。 | **實作前須讀 <https://openlibrary.org/developers/api> 原文** |
| Google Books | 未能讀取條款原文。 | 實作前須確認 API key、配額、快取與顯示規定 |
| 起點、番茄、晉江 | 本次沒有查證。構想文件 §6.3 已指出：能從公開網頁取得資料，不代表擁有重用、批量採集與封面再分發的權利。 | 條款審查前不內建（§17 第 4 項） |

### 11.4 對設計的影響

- **內建 provider 不受 4.7 約束。** 它們是 App 自己的 Swift 程式碼。
- **宣告式規則模組風險最低（推論）。** 只有資料、沒有可執行碼，由既有規則引擎解譯；但仍是「下載後改變功能」的內容，上架前要確認審核立場。
- **可下載的 JavaScript 模組屬於 4.7 的「plug-ins」。** 推論：模組需要的 HTTP 橋接（如 Forward 的 `Widget.http`、Legado 的 `java.ajax`）很可能落在 4.7.2「expose native platform APIs or technologies」的範圍，所以要先取得 Apple 的許可；另外還要做到 4.7.1 的檢舉與過濾、4.7.4 的索引與 universal link、4.7.5 的年齡限制。
- **既有的 Legado 書源已經有 JavaScript 橋接**（〈審計〉§10.3）。這是既有風險。本計畫不擴大它，也不讓新模組沿用它。
- **Open Library 的請求方式：**
  - 沿用 App 已經在送的 `Yuedu/<版本> (iOS; +https://yuedureader.com/support)` User-Agent（`Technotes/PublicLibraries.md`）；
  - 只在使用者動作時查詢，不批次、不預抓；
  - 封面請求另外限速。
- **Calibre 與 Jellyfin 的做法對應到本計畫：**
  - `ProviderIds` 對應 `ExternalIdentifier`；
  - `LockedFields` 對應 `lock` 決定；
  - Calibre 的「ISBN 優先」對應 §7.2 的 A 級。
- **CKSyncEngine 要求真機驗收。** 本專案近期的驗證多半只用模擬器（例如 `Technotes/RemoteLibraryReading.md`），所以 Phase S 的驗收要另外安排兩台真機（§15 的 Phase S）。

## 12. 統一搜尋

### 12.1 架構

```
BookSearchView（或新的統一搜尋頁）
  └─ UnifiedSearchCoordinator（@MainActor；發布經 SearchResultPublicationGate）
       ├─ LibraryParticipant          邊打邊搜（記憶體內，WorkMatchKey）
       ├─ AozoraParticipant           邊打邊搜（AozoraCatalogIndex，移出 view body）
       ├─ RemoteLibraryParticipant×N  送出才搜（每個 OPDS／Calibre 連線一個）
       ├─ GutenbergParticipant        使用者明確要求才搜；中國區不存在
       ├─ BookSourceParticipant       送出才搜（包住既有的 SearchAggregator）
       └─ BibliographicParticipant    送出才搜（Open Library 等；可關閉）
            ↓ SearchCandidate（已截短、清理）
       WorkResolver（與作品索引同一套 §7 規則；在背景執行）
            ↓
       [UnifiedSearchResult]：WorkSummary＋成員＋每個參與者的 SearchOutcome
```

### 12.2 規則

**必須沿用的約束：**

- 〈審計〉§11.5 的七條全部沿用。
- 路由是 `SearchResultRoute<UnifiedSearchResult>`，凍結快照。
- 目的地是獨立的 view。
- `SearchPagePush` 加一個 case。
- iOS 17 繼續用 UIKit 表格。表格的列需要能顯示本機封面檔，所以要加一層列級的封面抽象（目前只載入遠端網址）。

**參與者的行為：**

- 每個參與者有自己的逾時與錯誤。失敗只影響那個參與者的狀態列，不影響其他結果。
- 失敗一律經 `AppLogger` 記錄，並區分 `empty` 與 `failed`。

**排序：**

- 先沿用現有的分數：完全符合 3 分、前綴 2 分、包含 1 分。
- 同分時依序比：
  1. 書架上有副本；
  2. 有可閱讀的來源；
  3. 只有書目資料。

**範圍與預設：**

- 搜尋範圍是現有的 `SearchSourceScope` 再加上來源種類：書架、我的書庫、公有書庫、書源、書目資料庫。
- 預設不含書目資料庫，因為關鍵字會送到第三方。
- 預設也不含 Gutenberg，它需要使用者按下「在 Project Gutenberg 搜尋」。

### 12.3 分步落地

1. **Phase 4a：** 把 `SearchAggregator` 的 `searchSingleSource`＋`mergeBatch` 抽成參與者，行為不變。用 Phase 0 補的現況測試證明前後一致。
2. **Phase 4b：** 加書架與 OPDS／Calibre 參與者，結果仍分區顯示，還不跨區歸併。
3. **Phase 4c：** 啟用 `WorkResolver` 的跨參與者歸併與作品詳情頁。
4. **Phase 4d：** 讓換源與換封面也改用 `WorkMatchKey`，以 `ChangeSourceMatchTests` 加新的固定案例作護欄。

## 13. 探索首頁（HomeSection）

### 13.1 決定（維護者，2026-10-08）

- **首頁可以跨來源聚合，像 Emby 一樣。**
- **範圍二選一，比照 Forward：**
  - 「全部」：聚合所有來源；
  - 只看「單一來源」：某一個來源配置或書庫，例如只看一個 Emby 庫。
- **規範同步改寫：** `docs/design.md` 發現原型的「不擅自重組成平台推薦流」已經改寫（§13.5）。

### 13.2 參考：Jellyfin 的首頁怎麼決定

依據 jellyfin-web 原始碼：

- `src/components/homesections/homesections.js`
- `src/constants/homeSectionType.ts`
- `src/components/homesections/sections/recentlyAdded.ts`

Jellyfin 是從 Emby 分出來的開源專案。

- **欄目由使用者排序。** 首頁有 10 個欄目位置（設定 `homesection0`–`homesection9`），每個位置由使用者選一種類型：
  - 我的媒體（庫磚塊）、庫按鈕
  - 繼續觀看、繼續聆聽、**繼續閱讀**
  - 下一集、最新加入
  - 直播、錄影
  - 無
- **預設順序：** 我的媒體 → 繼續觀看 → 繼續聆聽 → 繼續閱讀 → 直播 → 下一集 → 最新加入，其餘為無。
- **聚合方式依類型而不同：**
  - 「繼續」類跨所有庫，聚合成**一列**。
  - 「最新加入」**每個庫各一列**，標題是「Latest in ⟨庫名⟩」，點標題進入該庫。使用者可以逐庫排除（`LatestItemsExcludes`）。
- **單一庫：** 點「我的媒體」裡的庫磚塊，就進入那個庫自己的頁面。

結論：Emby 系的首頁不是一條混合的推薦流，而是「跨庫聚合的個人列」加上「每個庫各自的列」，兩者都標明出處，順序由使用者決定。

### 13.3 Yuedu 的首頁

**範圍選單**

- 位置：探索的工具列，用原生 `Menu` 裡的 `Picker`。它不開啟 modal，所以不受 iOS 17 選單規則限制。
- 選項：「全部」，或任一個來源（某個來源配置、某個書庫連線、Gutenberg、青空）。
- 「全部」顯示下面的欄目清單。
- 單一來源顯示該來源自己的頁：
  - 來源配置：它的發現分類，也就是今天的來源配置頁；
  - Calibre／OPDS：它的導覽；
  - Gutenberg：精選與書架；
  - 青空：新着與索引。
- 中國區沒有公有書庫選項。
- 選擇存在 UserDefaults，取代 `explore.mode`。

**欄目類型**

| 類型 | 對照 Jellyfin | 內容 | 聚合 |
|---|---|---|---|
| 我的書庫 | 我的媒體 | 每個來源一塊磚：書架分組、書庫連線、公有書庫、來源配置、自訂頁、瀏覽器。今天的探索根頁就是這一種。 | — |
| 繼續閱讀 | 繼續閱讀 | 書架上最近打開的副本 | 跨所有來源，一列 |
| 最新 | 最新加入 | 每個來源一列，標題「⟨來源名⟩・最新」，可逐一排除。內容由各 provider 定義（見表下說明）。 | 每個來源一列 |
| 分類 | — | 指定某個來源的某個分類，沿用今天自訂頁的 7 種版面 | 單一來源 |
| 精選 | — | Gutenberg 隨 App 附帶的書單，不發請求 | — |
| 相關 | — | v1：同作者、同系列（書架上的訊號）；作品索引建好後，加上跨來源的同一部作品 | 跨來源 |

「最新」的內容由各 provider 自己定義：

- 來源配置：由使用者指定一個發現分類代表它；
- OPDS／Calibre：feed 的「最新」導覽，沒有時用根目錄的第一組書；
- Gutenberg：依發布日期的搜尋，但只在使用者按「載入」後才請求；
- 青空：新着，來自本機目錄，不連網。

規則：

- **每一列都標出處。** 只顯示來源本身提供的排行與數字，不自行捏造排行或評分；公有書庫已經這樣做（`Technotes/PublicLibraries.md`）。
- **預設欄目**，依舊的 `explore.mode` 決定：

  | 使用者 | 預設欄目 |
  |---|---|
  | 原本是書源模式 | 我的書庫（排在第一，就是他們熟悉的畫面）→ 繼續閱讀 → 最新 → 精選 |
  | 原本是公有書庫模式與新安裝 | 繼續閱讀 → 我的書庫 → 精選 → 最新 |
  | 中國區 | 不產生、也不能新增任何公有書庫的欄目或範圍選項 |

  `explore.mode` 與舊的根 view 保留一個版本，以回退旗標切換。

### 13.4 實作

- **一個頁面模型，多個頁面。**
  - 把 `CustomExplorePage`／`CustomExploreComponent` 一般化：元件的綁定從 `[ExploreCategoryReference]` 擴充成 `HomeSectionBinding`，再加上 `isEnabled`、`schemaVersion` 與容錯解碼。
  - 探索首頁是 id 固定為 `home` 的那一頁；使用者原有的自訂頁照舊是獨立的頁。
- **綁定種類：**
  - `.myLibrary`
  - `.continueReading`
  - `.latest(source)`，加上排除清單
  - `.sourceCategories([ExploreCategoryReference])`：今天的自訂頁元件
  - `.opdsFeed(connection, url)`
  - `.gutenbergCollection(id)`
  - `.gutenbergFeed(url)`：顯示「載入」按鈕，不自動請求
  - `.aozoraNew`
  - `.aozoraIndex(kind)`
  - `.related`
- **載入：**
  - 一般化 `CustomExplorePageModel`。每個 provider 宣告自己的載入策略：來源配置依序載入，Gutenberg 只在使用者要求時載入。
  - 來源配置的欄目要補上 `DiscoverViewModel` 會先做的 cookie 預熱（〈審計〉§12.3）。
  - 第二頁以後的三份載入實作合併成一份（〈審計〉§12.2）。
- **導覽：**
  - 一條混合 `NavigationPath`，路由要涵蓋 `ExploreNavigationRoute`、`OPDSFeedRoute`、`RemoteLibraryBookRoute`、WebDAV、青空與作者頁。
  - 閉包式的 `NavigationLink` 改成以值推入的連結。
  - 內嵌的搜尋頁仍推入同一條 path。

### 13.5 跟著首頁一起更新的東西

- **`docs/design.md` 發現原型：** 原則已於 2026-10-08 改寫；詳細的版面描述，在 Phase 5 實作時再更新。
- **TipKit 模式提示：** 相關旗標隨模式選單一起移除。
- **分頁根白名單：** `docs/design.md` 與 `CLAUDE.md` 裡的分頁根白名單，要改成新的首頁 view。

## 14. 統一作品詳情與模組系統的前置條件

### 14.1 作品詳情

- **結構：** 建立在 `BookDetailScaffold` 系列元件上（〈審計〉§13），新增「可用來源」區塊：版本 → 來源紀錄 → 動作。
- **動作分開表達，不合併成一顆按鈕：** 繼續閱讀、線上閱讀、下載、加入書架、查看來源詳情（構想文件 §9）。
- **資料來源與編輯：** Metadata 的每一列都標出來源，並提供編輯、鎖定、識別（搜尋候選）。
- **既有詳情頁：** 原有的書源詳情、遠端書詳情、青空作品詳情保留，作為從作品頁推入的「來源詳情」，不重寫。
- **書架長按：** 「書籍資訊」（`EditBookSheet`）保留。新增「作品詳情」入口，並修正「來源」列的標籤（〈審計〉§16 第 2 項）。

### 14.2 模組系統

依 §11 的條文，分四步。每一步都可以單獨停下，不影響前一步。

1. **內建 provider 的宣告（編譯期）。**
   - 每個內建 provider 宣告一份 `ProviderManifest`：`id`、`type`、顯示名稱、能力、會連線的主機、限速、可用區域、`searchPolicy`、`loadPolicy`。
   - 這就是構想文件 Phase 6 的「Capability Protocol」與「模組 Manifest」，但不涉及下載任何東西。
2. **Legado 書源用同一份宣告描述。**
   - 依書源實際有的規則推導能力：有搜尋規則就有 `CatalogSearching`，有發現規則就有 `HomeSectionProviding`，有詳情規則就有 `MetadataProviding`，有目錄與正文規則就能線上閱讀。
   - 書源因此進入同一個註冊表。執行仍走 `BookSourceSession`，不另開路徑。
3. **宣告式規則模組。**
   - 讓使用者匯入「只有規則、沒有 JavaScript」的模組，提供瀏覽、搜尋或 Metadata。
   - 由既有的 `ModernRuleEngine` 解譯 CSS／XPath／JSONPath／Regex。
   - 網路一律走 `WebFetcher`，因此套用 `safeURL`、限速與 User-Agent。
   - 使用者自己加的 OPDS 連線，本質上就是這一類。
4. **JavaScript 模組（v1 不做）。** 開工前必須先具備下列全部條件：
   - Apple 依 4.7.2 給予的許可。
   - 全新的最小橋接：
     - 只有經 `WebFetcher` 的 HTTP，並以模組為單位設定主機白名單；
     - 沒有共用 cookie、沒有 `deviceID`、沒有 WebView；
     - 不能 `importScript` 或 `eval` 遠端程式碼。
   - 真正能中止的執行：現在的 watchdog 只放棄佇列，腳本仍在跑（〈審計〉§10.3）。
   - 4.7.4 的模組索引與 universal link；4.7.1 的檢舉與封鎖；4.7.5 的年齡分級；4.7.3 的逐次資料分享同意。

**安裝與更新**（第 3、4 步）：

- 以訂閱網址安裝，比照 Legado 的網路導入與 Forward 的 `.fwd`。
- manifest 帶 `requiredVersion`，版本不符就拒絕安裝。
- 每個模組有自己獨立的儲存，比照 Forward 的 `Widget.storage`；移除模組時一併清除。

## 15. 遷移步驟

每一步都要滿足三個條件：

- 可以單獨合併；
- 有自己的測試；
- 不需要使用者遷移資料。

會影響畫面的步驟都在一個 UserDefaults 旗標後面，做法比照 `ReaderFeatureFlags`。

### Phase 0　前置：描述現況並修正錯誤語意（構想文件沒有這一階段）

| 步驟 | 內容 | 理由 | 驗收 |
|---|---|---|---|
| 0a | 為下列元件補上描述現況的測試，鎖住要包起來的行為：`SearchAggregator` 的合併與排序、`BookOriginSearchService`、`OnlineCoverSearchService`、`CustomExplorePageModel`、`DiscoverViewModel.reload`、`DiscoverKindsCache` | 〈審計〉附錄 B 的測試缺口 | 新測試在未改程式時通過 |
| 0b | 原生搜尋路徑區分「合法的空」與「失敗」：失敗要記錄，並計入 `SourceHealthStore` | 〈審計〉§11.3；`CLAUDE.md` 的「Don't swallow errors」 | **行為改變：** 被封鎖的書源會進冷卻。需維護者同意（§17 第 9 項） |
| 0c | 把 WebDAV 資料夾列表從 view 移到 model | 〈審計〉§8.2；「Views don't orchestrate」 | `RemoteLibraryBrowsePresentationTests`、`RemoteLibraryNavigationUITests` |
| 0d | `CustomExplorePageStore` 讀取失敗後拒絕寫入 | 〈審計〉§16 第 4 項；之後要遷移這個檔案 | 新增：損壞檔不會被覆寫 |
| 0e | 加上 `works.*` 的 SourcePerfTrace span | 「Measure, then optimize」 | span 出現在 Release Console |

### Phase 1　資料模型（構想文件 Phase 1）

| 步驟 | 內容 | 改到的既有檔案 | 驗收 |
|---|---|---|---|
| 1a | 新增 `ProviderType`、`SourceInstanceKey`、`SourceItemKey`、`ExternalIdentifier`、`ContentKind` 與純函式推導：`ReadingBook`、`RemoteLibraryItem`、`OnlineBook`、`AozoraWork`、`OPDSEntry` → `SourceRecord`。用推導結果修正「書籍資訊」的「來源」列。 | `HomeView.swift`（只改來源列） | 每種入口的推導都有表格驅動測試 |
| 1b | 匯入時多讀原始 metadata，只存進 sidecar：EPUB OPF 的 identifier、language、description、subject；OPDS 的 summary、`authorNames`、language、identifier；Calibre 無線傳書的 uuid 與 isbn；青空目錄欄位。既有的書在打開作品頁時才補讀，不在背景掃描整個書架。 | `BookStore.importEpub` 等只多呼叫一次 sidecar 寫入；`ReadingBook` 不變 | 匯入測試確認 `ReadingBook` 的編碼不變（雜湊相同） |
| 1c | `WorkIndex`：§7.3 的演算法、`index.json`、重建與增量更新 | 無 | 固定案例：《三體》簡繁、《三體》與《三體II》、同名不同作者、漫畫改編、譯本、Calibre 多格式、使用者拆開後不再歸併 |
| 1d | `WorkDecisionsStore`＋`MetadataResolver`；在三條覆寫路徑檢查鎖定 | `BookStore`（線上刷新）、`RemoteLibraryWritingService` | 鎖定後刷新不改書名；沒有鎖定時，行為與現況相同 |

**Phase 1 的回退：** 關閉旗標，刪除 `Works/`。`ReadingBook` 與同步內容完全沒有變動。

### Phase S　同步 v3（與 Phase 1–4 平行；維護者 2026-10-08 提議納入本次改版）

**為什麼要改**（〈審計〉§6.1）

- **合併單位太大。** 整本書是一個合併單位，A 讀了幾頁、B 加了書籤，同步後一邊的修改會消失。
- **裝置本地狀態也被同步。** 離線下載狀態與任務、相容性降級都在同一筆裡，而且會讓整本書被當成「現在修改」。
- **偵測修改靠雜湊。** 編碼穩定性因此成了正確性的前提，已經出過一次事故。這也是 D1「不能批次補欄位」的根源。
- **精確位置不同步；書籤整批覆蓋。**
- **每次都整檔上傳，也沒有推播。** 另一台裝置要等下一次啟動或進背景。

**實體切分**

| 實體 | 內容 | 同步 | 衝突規則 |
|---|---|---|---|
| `LibraryItem` | id、書名、作者、分組、是否在書架、加入時間、來源描述（§5 的 `SourceItemKey` 與取得所需欄位）、封面參照 | 是 | 每個欄位各自「較新者勝」 |
| `ReadingState` | 進度比例、最後閱讀時間、精確位置＋座標版本、漫畫與有聲書的位置 | 是 | 閱讀時間較新者勝；座標版本不符時只採用比例 |
| `Annotation` | 每一筆書籤、劃線、筆記 | 是 | 每筆獨立；刪除留墓碑 |
| `BookSettings` | 有聲書播放設定、渲染器偏好；`BookReaderSettings` 是否納入待決（§17 第 15 項） | 是 | 每個欄位各自較新者勝 |
| `WorkDecision` | §5 的決定 | 是 | 每筆獨立；「不同作品」優先於「同一作品」 |
| 裝置本地 | 離線下載狀態與任務、相容性降級、快取檔名、目錄與它的摘要、內容檔在本機的路徑 | **否** | — |

**傳輸：CKSyncEngine**

- 用自訂的 record zone，一個實體一筆 `CKRecord`。
- 以 change token 增量抓取，不再每次下載、上傳整個書架。
- 衝突以 `serverRecordChanged` 逐筆處理，套用上表的規則。
- 需要遠端推播：另一台裝置不必重啟就收到更新。模擬器收不到推播（§11.2），所以驗收必須用真機。
- 書檔與封面檔沿用現有的 `bookfile_*` 檔案紀錄，這一階段不搬。
- 書源、取代規則、閱讀設定等其他同步類型，先維持 v2。

**本機：`ReadingBook` 變成組合出來的檢視**

- **分檔存放。** 本機也依實體分檔存放；每個實體帶自己的修改時鐘，裝置本地欄位另存。
- **型別暫時保留。** `ReadingBook` 由 `BookStore` 從各實體組合出來，100 多個呼叫點不必同時改，之後逐步換成較窄的型別。
- **`ReadingBook.id` 不變**（D1）。
- **`books_meta.json` 繼續產生。** 它是投影，供三種用途：iCloud 手動備份、WebDAV 備份、回退。舊備份的還原永遠支援。

**過渡**

| 階段 | 內容 | 舊版本裝置 |
|---|---|---|
| S1 | 本機依實體拆分，`ReadingBook` 改成組合出來的檢視；同步仍是 v2 | 不受影響 |
| S2 | 啟用 v3（CKSyncEngine），同時把 v3 的結果投影寫回 `books_meta_v2`；作品決定開始同步 | 照常同步，但仍以整本書為單位 |
| S3 | 精確位置帶上座標版本後開始同步。青空設計已要求「同步的閱讀位置要先帶上座標版本，才能上線任何座標遷移」（`docs/superpowers/specs/2026-10-05-aozora-bunko-support-design.md`） | 不受影響 |
| S4 | 停寫 `books_meta_v2` | 不再收到更新 |

S4 的條件：連續 N 個版本，而且 v3 的裝置登記顯示已沒有舊版本裝置。停寫前，App 內提示「請更新其他裝置」。

- **第一次啟用 v3：** 以本機資料加上當下 v2 的合併結果作為種子。只做一次，並以 journal 記錄，中斷可以續跑；做法比照 TXT 位置遷移（〈審計〉§6）。
- **回退：** S2 期間 v2 一直在寫，所以關閉 v3 旗標就回到 v2。

**驗收**

- **單元測試：** 比照 Apple 範例，模擬多台裝置交錯修改。
  - A 改進度、B 加書籤：兩邊的修改都保留。
  - A 刪書籤、B 改同一筆的筆記：依墓碑規則處理。
  - 裝置本地欄位不出現在任何上傳的 record 裡。
- **兩台真機：**
  - 推播後，另一台不重啟就看到更新。
  - S2 期間，舊版本裝置照常收到書架的變動。
- **舊資料：** 以實際的 `books_meta.json` 做遷移 fixture，包含舊鍵與舊書籤格式；遷移前後逐本比對。取得使用者資料須經本人同意。

**與其他階段的關係**

- **不必等 Phase S 的部分：** Phase 1 的作品索引只存本機、可以重建；MVP 切片也全在本機。
- **要等 Phase S 的部分：** 作品決定的同步，以及以後的精確位置同步。
- **Phase 1d 的鎖定在 S2 之前只在本機有效：** 欄位時鐘解決的是兩台裝置的衝突，不能取代鎖定，因為來源的刷新總是比較新。所以鎖定仍需要，S2 起跟著作品決定一起同步。

### Phase 2　來源協定（構想文件 Phase 2）

- **2a** 註冊表與 `CollectionBrowsing`：書架、OPDS（含 Calibre、Gutenberg）、WebDAV、青空的 adapter。
- **2b** 「我的書庫」：連線可以從匯入 sheet 以外的地方瀏覽，例如探索首頁的入口欄目或設定。
  - 書架「＋」的三個入口保留，直到新入口通過 UI 測試。
  - `RemoteLibraryNavigationUITests` 同步改寫。
- **2c** 瀏覽列顯示「已在書架」與「已下載」。查找改用索引，不再逐筆掃描（〈審計〉§8.3）。

### Phase 3　Metadata（構想文件 Phase 3）

- **3a** `MetadataProviding` 與「識別」畫面：搜尋候選、逐欄選用、預覽後套用。
- **3b** 第一個網文 Metadata 來源：使用者自己的書源的詳情規則。不內建任何平台解析。
- **3c** 第一個內建書目資料庫：Open Library（條款見 §11）。另外，把 `OnlineCoverSearchService` 一般化成封面 provider，並改走 `WebFetcher`。
- **3d** 自動補齊：只補空欄位，只採 A 級相符，只寫 sidecar（§8.2）。

### Phase 4　統一搜尋（構想文件 Phase 4）

見 §12.3 的 4a 到 4d。

### Phase 5　探索首頁（構想文件 Phase 5）

見 §13。前提是 0a 與 0d 已完成。

### Phase 6　模組（構想文件 Phase 6）

見 §14.2。

### Phase 7　進階推薦（構想文件 Phase 7）

需先修改 `docs/design.md`，見 §17 第 6 項。

### MVP 切片

構想文件 §14 的驗證不必等七個階段全部完成，也不必等 Phase S，因為驗證全部在本機進行。最小的切片是：

- 0a、0b、0e；
- 1a–1d；
- 2a，只要書架、OPDS、Calibre；
- 3b；
- 4a–4c；
- §14.1 作品詳情的唯讀版。

## 16. MVP 驗收

**固定資料**

全部是本機 fixture。Calibre 另以 `YUEDU_LIVE_CALIBRE_URL` 做一次實測。

- 書架：
  - EPUB《三體》劉慈欣，zh-Hans，OPF 的 `dc:identifier` 是一個 ISBN-13，fixture 自訂即可，與 Calibre 那本相同；
  - EPUB《三體II：黑暗森林》。
- Calibre（loopback HTTP fixture）：
  - 《三體》EPUB＋PDF，`urn:uuid:X`，同一 ISBN；
  - 《球狀閃電》。
- OPDS fixture：《三體》繁體（zh-Hant）。
- 網文 Metadata：一個測試書源，詳情規則回傳《三體》的簡介、分類與字數。

**搜尋「三體」必須做到**

1. 第一列是一部作品「三體 · 劉慈欣」，標示四個來源：書架、Calibre、OPDS、書源。
2. 《三體II：黑暗森林》是另一列，不被歸併。
3. 作品頁顯示：
   - 封面：書架副本自帶的封面；
   - 簡介：來自書源，並標示出處；
   - 兩個版本：
     - 簡體：書架 EPUB 已在書架、Calibre EPUB／PDF 可取得；
     - 繁體：OPDS。
   - 動作分開：繼續閱讀、線上閱讀、下載、加入書架。
4. Calibre 離線時：
   - 其他結果照常出現；
   - Calibre 的狀態顯示失敗原因；
   - 日誌記錄 `failed`，而不是 `empty`。
5. 搜尋過程沒有發出任何 Gutenberg 請求，除非使用者明確要求；在中國區，Gutenberg 參與者不存在。
6. iOS 17 runtime：
   - 走 UIKit 表格；
   - 路由凍結；
   - 連續推入、返回各 10 次，沒有 watchdog。
   - 公有書庫目前尚未在 iOS 17 實測（`Technotes/PublicLibraries.md`）；這一項是必測。
7. VoiceOver：合併列的朗讀內容包含書名、作者、來源數、是否在書架。
8. 數據：
   - `works.search.local` 以 2,000 份副本量測；
   - 記錄第一個遠端結果到達的時間；
   - 以上都提出前後毫秒數。
9. 書架上每本書的 `stableHash(strippedForSync())` 在整個流程前後都不變（除了使用者明確套用的那一本）。

## 17. 待維護者決定

1. **B 級自動歸併：** 書名＋作者完全相符時要不要自動歸併？
   - 建議：要，但標示依據，並可以拆開。
   - 只用在新的作品層與統一搜尋。
2. **`decisions.json` 何時同步：**
   - 建議在 Phase S2 起，以 v3 同步的 `WorkDecision` 實體同步。
   - 不放進 `books_meta_v2`，以免影響書籍雜湊。
3. **遠端連線的可攜鍵：** `OPDSCatalog.id` 是裝置本地的 UUID。同步決定之前，必須定出跨裝置的連線身分，例如「類型＋正規化網址＋使用者名稱」。
4. **起點、番茄等網文平台的內建解析：**
   - 需要先審查條款，看能否取得結構化資料、能否顯示與快取封面。
   - 在那之前，用使用者自己的書源的詳情規則（3b）。
5. **書目資料庫：**
   - 是否以 Open Library 為第一個？
   - 預設要不要關閉？關鍵字會送到第三方，需要隱私揭露。
6. **「為你推薦」：** 已決定（2026-10-08）。
   - 首頁可以跨來源聚合，也可以切換成單一來源（§13.1）。
   - `docs/design.md` 的原則已改寫。
   - 尚待確認的只有一件事：「相關」欄目 v1 只用書架上的訊號，是否足夠？
7. **首頁預設欄目：** 兩種舊模式的使用者，以及中國區，預設欄目各是什麼（§13.3 的建議表）。
8. **書架搜尋：** 書架要不要加搜尋欄？或者統一搜尋裡的「書架」結果就夠了？
9. **Phase 0b 的行為改變：** 被封鎖或已失效的書源會進冷卻，之後的搜尋一段時間內不查它。
10. **WebDAV 索引：** 是否提供逐連線、opt-in、深度與數量有上限的建索引？
11. **第三方 JavaScript 模組：** 是否向 Apple 申請 4.7.2 的許可（§11、§14.2）？在那之前只做宣告式模組。
12. **上線方式：** 統一搜尋與新首頁，是否先以設定中的實驗開關上線？
13. **同步 v3 的傳輸：**
    - 是否採用 CKSyncEngine？
    - 它需要遠端推播權限，而且驗收必須用兩台真機（§11.2）。
14. **過渡期：**
    - `books_meta_v2` 要雙寫幾個版本？
    - 停寫的條件是什麼？
    - 是否需要 App 內的「請更新其他裝置」提示？
15. **同步範圍：** 每本書的閱讀設定（`BookReaderSettings`）是否進 v3？
    - 現在它不同步。
    - 同步後，另一台裝置會跟著改字體與行距。
16. **其他同步類型：** 書源、取代規則、閱讀設定是否也改成實體同步？
    - 建議這次只做書庫，其他維持 v2。

## 18. 風險

| 風險 | 緩解 |
|---|---|
| 改到 `ReadingBook` 的編碼，iCloud 合併時用舊進度蓋掉新進度 | D1、D2。§16 第 9 項把雜湊不變列為驗收。 |
| 錯誤歸併：同名異書、譯本、改編 | §7.2 的保守等級；拆開的決定永久有效；每個歸併都標示依據 |
| 區域 gate 外洩：搜尋或首頁在中國區出現公有書庫 | gate 放在 provider 可用性，而不是 view；每個進入點都有測試 |
| 違反 Gutenberg 使用條款：自動請求、預抓 | `searchPolicy` 設為 `.onExplicitRequest`；首頁載入策略設為 `.onDemandOnly` |
| iOS 17 回歸 | §12.2 的約束；§16 第 6 項把 iOS 17 runtime 列為必測 |
| 大型書庫的效能 | §10.4 的量測門檻；索引在背景建立並增量更新 |
| 私人書庫的書名外流 | 索引只在本機；書目查詢需要明確開啟；日誌依 privacy 標記處理 |
| 範圍蔓延到排版引擎 | 本計畫不碰 `Modules/Core/ReaderCore/` |
| 自訂探索頁遷移失敗、使用者的頁消失 | 0d 先修；遷移前備份原檔；解碼失敗時保留舊檔，不寫新檔 |
| 同步重做時遺失資料：這是整個計畫中風險最高的改動 | S1 不改同步；S2 雙寫並可關旗標回退；種子遷移有 journal；以實際資料做 fixture 逐本比對 |
| 新舊版本裝置並存時，資料互相覆蓋 | S2 把 v3 的結果投影回 `books_meta_v2`；S4 的停寫要有明確條件與提示 |
| 只用模擬器驗證不到推播與多裝置 | Phase S 的驗收另外安排兩台真機（§11.2） |

## 19. 每一步的回歸測試

除了每一步新增的測試，至少要執行〈審計〉附錄 B 的對應類別：

| 改動 | 必跑的既有測試 |
|---|---|
| Phase 0b（搜尋錯誤語意） | `NetworkSettingsSearchTests`、`SearchSourceScopeTests`、`SearchResultPublicationGateTests`、`IOS17SearchResultTableTests` |
| Phase 1（資料模型） | `BookStoreMetadataWriteBudgetTests`、`RemoteReadingRecordTests`、`LocalBookImportServiceTests`、`ICloudAudioSyncExclusionTests`、`AozoraLibraryDownloadServiceTests` |
| Phase 1d（鎖定） | `RemoteLibraryWritingTests`，以及線上書刷新相關測試 |
| Phase 2 | 遠端書庫與 OPDS 全部類別；`RemoteLibraryNavigationUITests` |
| Phase 4 | `IOS17SearchResultTableTests`、`ChangeSourceMatchTests`、`SearchRecentsTests` |
| Phase 5 | `ExploreModeTests`、`PublicLibraryAvailabilityTests`、`CustomExplorePageTests`、`ExploreNavigationAndMetadataTests`、`PublicLibraryExploreUITests` |
| Phase S（同步 v3） | `BookStoreMetadataWriteBudgetTests`、`RemoteReadingRecordTests`、`BookmarkStablePositionTests`、`ICloudAudioSyncExclusionTests`，加上新的多裝置模擬測試與兩台真機驗收 |
| 任何新字串 | `ruby scripts/check_localizations.rb`（五種語言） |

照 `CLAUDE.md`：

- 執行測試用 `scripts/xctest.sh`；
- 模擬器以 `scripts/sim.sh` 解析，不寫死裝置；
- 每次改 view 都附 `#Preview`，並檢查 VoiceOver 朗讀。
