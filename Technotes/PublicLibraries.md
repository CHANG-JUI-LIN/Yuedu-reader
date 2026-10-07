# 探索頁的公有書庫

公有書庫提供 Project Gutenberg 與青空文庫。瀏覽、閱讀、加入書架和下載不依賴 Pro。沒有任何書源時，探索頁顯示公有書庫；有書源後，右上角原生選單切換「公有書庫／書源」，選擇寫入 `explore.mode`。升級前已有書源的讀者保留原本的書源頁。第一次匯入不改模式，下一次進入探索才顯示一次 TipKit 提示；減少動態效果停用圖示彈跳。

## Project Gutenberg

內建唯讀連線為 `builtin.gutenberg`，由 `PublicLibrary` 解析，不寫入使用者的 `opds_catalogs.json`，也不能編輯或刪除。它沿用 `OPDSFeedView`、`RemoteLibraryBookDetailView`、`RemoteLibraryService`、Readium 與既有 CoreText 閱讀路徑。

- 根目錄：`https://www.gutenberg.org/ebooks.opds/`。
- 熱門：`https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads`。
- 最新：`https://www.gutenberg.org/ebooks/search.opds/?sort_order=release_date`。
- 搜尋：`https://www.gutenberg.org/ebooks/search.opds/?query={percent-encoded query}`；`l.zh`、`l.ja`、`l.ko`、`l.en` 是語言篩選。
- 書籍：feed 提供的 `/ebooks/{id}.opds`，取得網址仍以 feed 為準。

公有書庫首頁的分類是固定連結，開啟首頁不請求 Gutenberg。只有開啟分類／書籍 feed、送出搜尋或按「載入更多」才請求一頁；不預抓、不背景爬取、不讀取仍指向舊 `m.` host 的 OpenSearch description。搜尋先凍結 query，再建立 route。列表只使用 feed 內嵌的 base64 縮圖；書籍詳情才讀取遠端封面。EPUB3 優先於 EPUB，並保留官網連結。

共享 HTTP client 的 request、session 預設 header 和重新導向均保留 `Yuedu/<version> (iOS; +https://yuedureader.com/support)`。沒有個人 email。參照 [OPDS 使用條款](https://www.gutenberg.org/policy/terms_of_use.html) 與 [機器人政策](https://www.gutenberg.org/policy/robot_access.html)，所有書籍由讀者直接從 Gutenberg 取得，保留原檔授權文字。介面註明其公有領域判斷以美國為準，其他所在地法律可能不同。

[離線目錄說明](https://www.gutenberg.org/ebooks/offline_catalogs.html) 預告 2027 年停用現有 XML OPDS。維護者已規劃聯絡 Gutenberg；Task 13 等待回覆，沒有使用未獲准的 OPDS 2 測試服務。

## 青空文庫目錄與取書

官方來源唯一為 `https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip`。2026-10-07 官方站無法連線；開發驗證使用計畫指定的合成 55 欄 CSV 與既有青空文字 fixture，沒有改用鏡像。目錄尚未發布、裝置沒有可驗證的快取時，首頁不顯示青空區塊。

`scripts/aozora_catalog/build_catalog.py` 合併作品與人物，保留角色，只收錄 `作品著作権フラグ=なし` 且提供官方 HTTPS ZIP 的作品。輸出排序穩定、壓縮的 `works.json` 與含 SHA-256、筆數、來源修改時間及出處的 `manifest.json`。`generatedAt` 採來源 Last-Modified；缺少它時使用目錄記錄的最新日期，因此來源不變時輸出不變。

預定固定 release 為 `aozora-catalog-v1`，資產是 `manifest.json` 與 `works.json`；App 固定讀取：

- `https://yuedureader.com/catalogs/aozora/v1/manifest.json`
- `https://yuedureader.com/catalogs/aozora/v1/works.json`

`.github/workflows/aozora-catalog.yml` 目前只有手動 `workflow_dispatch`，排程留作註解。**首次啟用前須取得維護者同意**：確認 tag 不會觸發 Xcode Cloud、建立固定 tag/release、設定網站 `_redirects`、再決定是否開每日排程。沒有在本次實作執行這些對外操作或 push。已完成上述前置作業後，可以在 Actions 手動執行；job 先測試 builder，再比較 manifest digest，只在內容改變時覆寫資產。

App 每 24 小時最多自動檢查一次 manifest；讀者可手動重新整理。解析、索引和原子寫檔在背景工作執行，先發布已驗證的快取。人物／作品索引與搜尋正規化一次建立；搜尋依書名／讀音前綴、包含、作者排序。作者與書名使用五十音分組，分類採 NDC。作品快照帶入詳情；「加入書架」交給 `AozoraLibraryDownloadService` 下載原始 ZIP，沿用 `AozoraBookImporter` 轉換，並以 `catalogWorkID` 辨認同一本書。重複操作共用工作，已在書架則直接開啟。

目錄書誌資料的出處標示為「青空文庫」，並連至 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)；此授權不套用到作品正文。CSV 記錄的原檔連結會隨修訂改變，因此不從作品 ID 推算下載 URL。官方 [連結規準](https://www.aozora.gr.jp/guide/linkkijyunn.html) 的文字須在復站後重新核對；本次不把停站期間無法讀取的內容當成已重新驗證。

## 區域與審核邊界

`PublicLibraryAvailability` 讀取 StoreKit 2 `Storefront.current` 和 `Storefront.updates`。最後一次已知國家碼存入 UserDefaults；冷啟動若已有 `CHN`，不先閃出書庫。沒有任何已知區域而 StoreKit 回 nil 時可用；曾有有效值後收到 nil 則保留該值。

`CHN` 時探索固定為書源，沒有切換選單、沒有提示，不啟動公有書庫首頁的目錄工作。既有 OPDS 匯入頁的 Gutenberg 範例仍保留。單一 binary 供應所有 storefront；App Review 的裝置可能採美國 storefront。若中國區審核仍不接受內建內容，是否從 App Store build 移除內建書庫必須由維護者決定，本次未擴大區域規則。

## 明確保留的相容／失敗處理

- 官方 CSV 連線失敗時，builder 記錄 notice、不產生新資產；workflow 因無輸出而略過發布，保留上一版。若發布契約改為要求上游停站必須讓 job 失敗時，可移除此段。解析錯誤不當成功。
- App 更新目錄遭遇連線、HTTP、解析或 digest 驗證失敗時，保留已驗證的快取並記錄錯誤；沒有快取則不冒充有目錄。離線瀏覽不再支援時才可移除此保留路徑。
- Storefront 暫時回傳 nil 時保留最後已知國家碼，避免已知中國區在暫時無法取得商店資訊時顯示書庫；若 StoreKit 日後保證持續提供非空 storefront，才可移除。首次從未取得區域的 nil 依決策 16 允許使用。
- iOS 17–25 沒有 SwiftUI 原生 section index API，使用原生 `UITableView` section index；最低版本提高至 iOS 26 後可刪除。TipKit API 隨 iOS 17／18／18.4／26 簽名分別呼叫，可隨最低版本提高移除舊分支。
- 沒有新增鏡像、網路自動重試、固定延遲、平行解析器或閱讀器。

## 驗證與量測

2026-10-07，以一般 `Yuedu-Reader.xcodeproj`、iPhone 18 Pro Max／iOS 27.0 Simulator 執行，沒有使用個人 iPhone。所有 iOS 測試由 `bash scripts/xctest.sh -- -only-testing:'yuedu appTests/<struct>'` 執行；UI 類別改用 `yuedu appUITests/<class>`。最後相關修改之後各自執行並確認測試數，不以 XCTest 對 Swift Testing 顯示的「0 tests」當作結果。

- 模式、舊設定遷移、首次匯入判定與中國區 gate：`ExploreModeTests` 4、`PublicLibraryAvailabilityTests` 2 通過。
- 內建連線、query escaping、列表圖片界線：`PublicLibraryRegistryTests` 4；HTTP、User-Agent、錯誤與單次請求：`RemoteLibraryHTTPTests` 12 通過。另有 `RemoteLibraryConnectionTests` 8 與 `OPDSParserTests` 10 通過。
- 青空模型與搜尋：`AozoraCatalogTests` 5；快取與 manifest 契約：`AozoraCatalogStoreTests` 4；下載／匯入／重複加入／取消：`AozoraLibraryDownloadServiceTests` 5；既有 `AozoraBookImportTests` 6 通過。Python builder 的 7 個測試通過。
- `PublicLibraryExploreUITests` 2 通過：無書源首頁、真實書源匯入、一次性 TipKit、切換、重啟保留與 VoiceOver label/value。
- `PublicLibraryLiveUITests` 分兩次 opt-in，各實際執行 1 個案例並跳過另一個：非 Pro 的 Gutenberg 搜尋、實際遠端閱讀、加入書架、離線下載通過（35.507 s）；Pro 加指定主題的青空 fixture 首頁、五十音作者索引與作品詳情通過（21.157 s）。截圖已人工檢查。未在 iOS 17 runtime 執行畫面測試。
- `ruby scripts/check_localizations.rb` 驗證五語言同步；新／修改 view 的 preview、原生標題、footer、DS token 和 accessibility 經檢查。

主題使用 `~/Desktop/Test document/山风 - 春水漾.qitheme`，先 `simctl launch … -debug-force-pro`，將檔案複製到 App 的 `tmp/`，再以 percent-encoded `file://` URL 執行 `simctl openurl`；匯入成功後再跑 Pro 截圖。青空畫面只使用 `Fixtures/AozoraCatalog/works.json` 的驗證快取，驗證結束移除；沒有修改來源、發布測試目錄或取得官方作品。未建成目錄時隱藏青空的路徑另由 UI 與 store 測試驗證。

| SourcePerfTrace span／範圍 | 首次 | 接續 |
|---|---:|---:|
| `publicLibrary.measure.root`，真實 Gutenberg 根 feed，含網路與解析 | 5,566 ms | 295 ms |
| `publicLibrary.measure.catalog`，1,254-byte 合成 fixture，背景解析與索引 | 40 ms | 0 ms（整數記錄，低於 1 ms） |
| 最終 Pro 畫面啟動的 `aozora.catalog.load`，同一 fixture | 22 ms | 未另外測量 |

這是同一量測案例的冷／暖執行，沒有宣稱前後改碼的加速，也不能推算完整官方目錄的時間或畫面首幀時間。`PublicLibraryMeasurementTests` 1 個測試通過；再次執行需明確設定 `TEST_RUNNER_PUBLIC_LIBRARY_LIVE_MEASURE=1`，一般測試不會打 Gutenberg。兩個 UI opt-in 分別為 `TEST_RUNNER_PUBLIC_LIBRARY_LIVE_UI=1` 與 `TEST_RUNNER_PUBLIC_LIBRARY_THEME_UI=1`；非 Pro 案例需使用尚未將 Gutenberg 1342 加入書架／下載的測試資料，才能實際覆蓋三個動作；主題案例需先匯入主題與準備 fixture 快取。

成功的非 Pro run（17:48–17:49，App PID 61925）網路紀錄只有一個搜尋 OPDS task 和一個書籍 OPDS task；`publicLibrary.opds.load` 分別為 925／300 ms。列表沒有額外封面請求，進入詳情後才取封面，按閱讀後才走既有 EPUB HEAD／Range 與下載。User-Agent 由 HTTP 測試檢查；沒有把系統 log 隱去的 header 當成已讀到的值。

本機證據位於 `~/Library/Logs/YueduPublicLibraries/20261007/`：`logs/` 保留測試與網路摘要；根目錄 PNG 包含 `nonpro-shelved-and-downloaded.png`、`nonpro-remote-reader.png`、`qitheme-import.png`、`pro-qitheme-library-home.png`、`pro-qitheme-aozora-authors.png`、`pro-qitheme-aozora-detail.png` 及首次匯入提示。匯出附件後已刪除本次 `.xcresult`。

仍待上游與發布條件具備後驗證：完整官方 CSV 的產出／規模量測、公開網址的 manifest 與 digest、官方 ZIP 的實際取書。Task 13 的 OPDS 2 仍等待 Gutenberg 回信；本次沒有啟用排程、建立 release/tag、修改網站 `_redirects` 或 push。
