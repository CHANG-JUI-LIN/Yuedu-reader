# 遠端書庫與閱讀

OPDS、Calibre／Calibre-Web 與 WebDAV 共用遠端書籍詳情。閱讀、加入書架、下載離線副本是三個獨立 use case；遠端文件仍使用 EPUB、TXT／Markdown 或 PDF 閱讀器，不使用網路小說書源流程。

## 主要介面

- `RemoteLibraryService` 由 `AppDependencies.remoteLibrary` 注入，負責書籍身份、開書、能力探測、快取及離線副本。
- `RemoteBookReference` 以連線 ID、來源 entry ID 與格式匹配同一 `ReadingBook.id`。取得網址變更不建立新閱讀紀錄。
- `BookStore.books` 僅包含書架成員；`readingBook(id:)` 與 `readingBooks` 包含未上架閱讀紀錄。閱讀器、進度與書籤使用此統一介面。
- 書架儲存於既有 `books_meta.json`，未上架紀錄儲存於相鄰的 `books_meta.reading.json`。加入書架沿用 ID 與閱讀資料；移出遠端書架也保留閱讀紀錄及離線副本。
- OPDS 原有連線檔繼續使用，新增來源種類；WebDAV 從同步設定複製一次，之後獨立管理。帳號與密碼存 Keychain，舊設定會遷移。
- `OnlineChapterRef` 的舊資料若缺少 volume／VIP／付費旗標，解碼預設為 `false`；保留既有音訊與 PDF 選填欄位。

## 文件讀取與快取

EPUB 先檢查 HEAD 與有界 Range，再把共用 HTTP client 交給 Readium。OPF、目錄、圖片、字型、加密資訊、PLS 與 SMIL 都透過 `EPUBPackageResources` 讀取；CoreText 排版及 `(spineIndex, charOffset)` 定位維持原路徑。

遠端 ZIP 透過 Readium 的 `ArchiveOpener` 擴充介面接入 `RemoteEPUBArchiveOpener`，共用一個 ReadiumZIPFoundation archive、最多 65,633 bytes 的 ZIP 尾端及 Readium 64 KB 預讀 buffer。原版 Readium 3.8 遠端 opener 固定預讀 6 MB，跨位置讀取小檔案會產生大量重疊傳輸；這個 adapter 只調整封裝檔的讀取策略，不新增 HTTP client、磁碟快取或 EPUB 解析器。上游開放預讀策略設定後可改回官方 opener。

自動快取位於 `Caches/RemoteLibrary/<bookID>/<versionHash>/`，包含 Range bytes、必要的完整檔案及 EPUB spine metadata。強 ETag 或 Last-Modified 與長度建立版本；缺少有效版本資訊時，每次線上開啟使用新的快取世代，弱 ETag 本身不重用不同次開啟的 ZIP bytes。每段回應驗證區間、總長與內容長度，來源變更不混用舊片段。

明確下載的副本使用 Documents 中的 `remote_<bookID>.<format>`。正在準備及閱讀的資源有使用計數保護；清除遠端快取不刪除使用中的內容、閱讀紀錄或離線副本。同步及 WebDAV 備份僅輸出書架成員，移除裝置暫存路徑；binary sync 僅包含明確下載的副本。

### 同一本書的任務生命週期

`RemoteLibraryBookOperations` 由 `RemoteLibraryService` 持有，按本機書籍 ID 排程資源變更。開書與明確下載依序處理；等待者取得執行權後重新讀取紀錄，若前一個操作已準備好閱讀資源或離線副本，就使用該結果，不再重複取檔。不同書籍不互相等待。這個排程不新增網路 client、檔案快取或解析路徑。

取消等待中的呼叫只結束該呼叫；正在執行的呼叫完成清理後，才交給下一個明確提出的操作。釋放閱讀資源會作廢尚未完成的開書結果，但不取消獨立的離線下載；資源網址改變或遠端寫入則透過 `invalidate(bookID:)` 作廢舊操作，向等待中的開書與已開啟的閱讀器回報「內容已變更」。每次回寫前再次檢查執行權與來源識別，避免舊回應重新發布已釋放或更名的資源。

解析成功後只合併資源欄位，不以開書前的 `ReadingBook` 快照覆寫書架成員、進度、書籤、書籍資料或離線狀態。EPUB session 在驗證及持久化成功後才對閱讀器公開。明確下載也不切換正在使用的 TXT／PDF／EPUB 來源；下一次開書才採用離線副本。

`ReadingResourceUsage.release` 回報是否釋放最後一個實際閱讀器，只有最後一個閱讀器關閉才釋放共用 session。重複的消失通知不重複釋放，多視窗不會關掉另一個閱讀器持有的資源。

### 相容處理的精確範圍

1. TXT／Markdown／PDF 的既有解析器需要完整檔案，開始閱讀時自動暫存。
2. EPUB 僅在伺服器成功回應但拒絕 Range，或無法提供必要長度時使用完整暫存。401／403、登入 HTML、逾時、損壞 Range 與解析失敗均不觸發此路徑。
3. 無網路或伺服器不可達時可重用已知版本的可用快取；認證失敗不以快取掩蓋。缺少資源會向當前閱讀器顯示錯誤，保留原位置。
4. Calibre 的搜尋僅在 HTTP 404 且錯誤正文明確為 `No books found` 時解讀為空結果，其餘 404 仍是錯誤。

小型 EPUB 也直接走同一遠端 ZIP 介面，以安全的尾端長度計算避免 UInt64 下溢；原本建立 `package.epub` 再改成本機開啟的相容路徑已移除。檔案小於 ZIP 尾端窗口時，必要的有界讀取仍可能涵蓋整個小檔案。

## 2026-09-11 架構追查與本次驗證

本次承接源閱 WebDAV 靜態追查，採用共用來源連線、輕量瀏覽、閱讀資料與資源生命週期分離的方向；不採用其先完整複製再交本機解析器、只檢查檔案存在、前端切頁的做法。來源證據見下載目錄的 `閱讀架構研究/源阅-1.0/webdav-followup/WebDAV架構追查.md`，靜態反編譯結果不當作源閱實機流量證據。

依使用者最新指示，後續驗證全部使用模擬器；先前進行中的真機命令已終止，中止結果不計入通過紀錄。

`iPhone 17 Pro Max / iOS 27` 模擬器的 `RemoteEPUBPublicationTests` 已通過 7 項測試，新增 stored／deflate 256 KB 資源的並行完整讀取與 90,000..<180,000 部分讀取。實際 loopback HTTP + URLSession + Readium + CoreText 首屏紀錄：檔案 **25,172,076 bytes**，傳輸 **131,170 bytes**，**3 次 GET 全為 Range**，**161 ms**。ZIP entry 排列會影響預讀區段；這是單次樣本數字，回歸門檻是此樣本首屏傳輸小於 1 MB。

以下本次相關類別／方法均在上述模擬器逐類執行成功，關閉平行測試，共 **59 項**（依測試 runner 計數）：

| 類別 | 通過項數 |
| --- | ---: |
| `RemoteEPUBPublicationTests` | 7 |
| `RemoteLibraryServiceTests` | 21 |
| `RemoteLibraryResourceClientTests` | 5 |
| `RemoteLibraryReadFailureTests` | 5 |
| `RemoteLibraryWritingTests` | 8 |
| `CacheManagementServiceTests` | 4 |
| `RemoteReadingRecordTests` | 7 |
| `ReadingResourceUsageTests` | 1 |
| `RemoteLibraryNavigationUITests` | 1 |

最後的模擬器 `xcodebuild build` 已完整結束，回報 `BUILD SUCCEEDED`；三語本地化檢查通過（3 個檔案、2,497 個 key），`git diff --check` 通過。

驗證產物保存在 `~/Library/Logs/YueduRemoteLibrary/20260911-lifecycle/`，本次模擬器結果使用 `simulator-` 前綴。VoiceOver 實際朗讀尚未驗收，UI 自動化只驗證可存取標籤與操作。

另外，首次啟動測試揭露 `FirestoreSyncManager` 註冊設定變更通知後才初始化 `FirebaseAuthManager.shared`，導致帳號初始化寫回設定時重入同一個 `dispatch_once` 而崩潰。現將必要依賴的初始化移到訂閱之前；後續測試 host 啟動驗證此路徑。`GatewayAccountBackend` 補上直接使用 StoreKit 符號所需的 import。

## 既有驗證範圍

`RemoteEPUBPublicationTests` 使用 loopback HTTP 伺服器、實際 URLSession、Range 磁碟快取、Readium 與 CoreTextPaginator。2026-09-10 原有紀錄為 25,172,076 bytes EPUB 首屏前傳輸 18,940,002 bytes。2026-09-11 真機重跑相同測試時，ZIP entry 排列不同，實際傳輸達 25,231,458 bytes（6 次 Range，845 ms），超過整本書；這推翻了僅憑原先單次通過認定 Range 傳輸量合格的結論，也定位出 Readium 6 MB 預讀問題。回歸現已額外要求這個只讀取小型資源的 24 MB padding 樣本首屏傳輸小於 1 MB。

新回歸涵蓋閱讀紀錄、獨立操作、EPUB 資源／版本、HTTP 認證策略、搜尋／資料夾解析、錯誤通知與快取清理。既有 TXT、PDF、書籤、EPUB 與 BookStore 測試逐類執行，停用平行測試。

真機 WebDAV／Calibre 連線與 VoiceOver 操作尚未驗收。後續已完成本機安裝的 Calibre 9.14 桌面驗證，以及 Basic／Digest 實際伺服器的閱讀、寫入與進度回傳測試；結果及能力限制見 [CalibreInteractions.md](CalibreInteractions.md)。

### 本次已完成回歸

以下選定類別／方法均實際執行成功，共 177 項測試（參數化案例依 Swift Testing 的 test 數計算），未使用平行測試。

| 類別或方法 | 通過項數 |
| --- | ---: |
| `CoreTextWritingModeTests` | 25 |
| `RemoteEPUBPublicationTests` | 6 |
| `RemoteLibraryResourceClientTests` | 5 |
| `RemoteLibraryReadFailureTests` | 5 |
| `RemoteLibraryBrowsePresentationTests` | 5 |
| `RemoteLibraryConnectionTests` | 8 |
| `RemoteLibraryHTTPTests` | 8 |
| `CacheManagementServiceTests` | 4 |
| `BookStoreMetadataWriteBudgetTests` | 3 |
| `BookmarkStablePositionTests` | 4 |
| `TXTReaderIndexMigrationTests` | 5 |
| `TXTFileReaderTests` | 8 |
| `TXTMetadataProbeTests` | 10 |
| `LocalPDFArchiveTests` | 12 |
| `RemoteLibraryServiceTests` | 12 |
| `LocalAudiobookArchiveTests` | 3 |
| `EPUBCFIResolverTests` | 5 |
| `EPUBAnchorOffsetTests` | 1 |
| `EPUBPronunciationTests` | 5 |
| `EPUBAutoRoutingTests` | 4 |
| `GeneratedBookCoverTests` | 19 |
| `ICloudAudioSyncExclusionTests` | 1 |
| `RemoteReadingRecordTests` | 7 |
| `OPDSParserTests` | 9 |
| `EPUBRenderingTests/publicationSessionResolvesPercentEncodedUnicodeSpineHrefs` | 1 |
| `EPUBRenderingTests/publicationSessionServesFixedLayoutRelativeResources` | 1 |
| `EPUBRenderingTests/cjkRTLPageProgressionDefaultsToVerticalWriting` | 1 |

第一階段最終 `xcodebuild build` 已完整結束並回報 `BUILD SUCCEEDED`。當時本地化檢查通過：三個語系、2,416 個 key；`git diff --check` 通過。第二階段新增項目的最終驗證另記於上述 Calibre 文件。
