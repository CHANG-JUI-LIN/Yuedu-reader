# 本地日文 TXT 與青空文庫

## 編碼偵測

原本的候選順序是 UTF-8 → GB18030（變數名為 gbk）→ Big5 → UTF-16；第一個能解碼的候選直接勝出。因此 Shift_JIS 的位元組即使能以 GB18030 解碼，也只會產生亂碼。

`TXTEncodingDetector` 改用合法序列、常用字頻率與 ICU4J 的對數信心評分辨識 UTF-8、UTF-16 LE/BE、GB18030、Big5、CP932、EUC-JP、EUC-KR。BOM 優先；無 BOM 的 UTF-16 必須有正向證據。統計最多讀取 512 KiB 樣本中的 8,000 個高位元組，略過獨立 ASCII，但保留多位元組字元內的低位元組尾碼，避免破壞 CP932、Big5 與 GB18030 四位元組序列。分數封頂 100 後，以常用字密度處理同分。

信心門檻為 10；短樣本需要常用字證據，半形假名另有證據計數。候選仍須通過 `canDecode`，維持僅容忍取樣末尾 1–3 位元組截斷的原有規則。未達門檻會記錄 `AppLogger.error` 並拋出本地化錯誤，不猜測其他編碼。現在沒有手動選編碼入口；建議後續提供選編碼及重新偵測的設定，本次未新增 UI。

參考 `~/legado-E` 與 `~/legado-with-MD3` 的 `EncodingDetect.kt`、`CharsetDetector.java`、`CharsetRecog_mbcs.java`、`CharsetRecog_UTF8.java`、`CharsetRecog_Unicode.java`；這五份檔案在兩個 clone 中完全相同。Swift 掃描與評分程式獨立重寫；常用字資料保留 ICU/Unicode 出處與 `LICENSES/ICU-Unicode.txt`。相較 Legado，保留字元的完整位元組，而不是直接過濾低位元組。

所有取樣、預覽、整檔與映射章節共用 `TXTTextDecoder`。CP932 使用 Foundation 的 DOS Japanese 編碼，支援 NEC 擴充字。EUC-JP 統一使用系統 iconv，因 Foundation 的 `japaneseEUC` 拒絕有效的 JIS X 0212（`8F xx xx`）；這是 EUC-JP 的主解碼器。App Debug／Release 增加 `-liconv`。

## 真實樣本對照

| 原始青空文庫下載 | 大小 | 修正前 | 修正後 |
| --- | ---: | --- | --- |
| [吾輩は猫である](https://www.aozora.gr.jp/cards/000148/card789.html) | 749,051 bytes | GB18030，亂碼 | CP932，全文及映射解碼均等於 Python 的正確結果 |
| [『吾輩は猫である』中篇自序](https://www.aozora.gr.jp/cards/000148/card2671.html) | 5,772 bytes | GB18030，亂碼 | CP932，全文及映射解碼均等於 Python 的正確結果 |

桌面 `Test document/TXT Format` 的四本中文小說也做了前後對照：萬古神帝、修真聊天群、我師兄實在太穩健了維持 GB18030；苟在武道世界成聖維持 UTF-8。

測試資源包含青空文庫原始下載的中篇自序，以及 Python 真正編碼的 CP932、EUC-JP、GBK、GB18030、Big5、EUC-KR 檔案與 UTF-8 對照。CP932 含 NEC 擴充字，EUC-JP 含半形假名與 JIS X 0212，GB18030 含四位元組字元；來源、雜湊與生成方式見 `Tests/iOS/yuedu appTests/Fixtures/TXTEncodings/README.md`。

## 注音與閱讀位置

`AozoraMarkupParser` 將 `｜漢字《かんじ》` 與 `漢字《かんじ》` 轉成既有 `.ruby` 節點，經 `NodeAttributedStringRenderer` 產生 `CTRubyAnnotation`。Lazy TXT builder 使用新增的 inline 接縫保留原本 TXT 的段落字型、縮排與樣式；UnifiedChapter builder 使用同一個解析器。含 ruby 的段落使用既有行高放寬邏輯。

依使用者決定，沒有 `｜` 時讀音必須含假名，避免中文 `功法《九陽神功》` 被改寫；支援平假名、片假名與半形假名，中點 `・` 不算假名。無豎線的注音範圍是前方連續漢字（含補充平面漢字、疊字符號與變體選擇符）。有 `｜` 時可指定假名及拉丁字母等底文。

正文中所有完整的 `［＃…］` 編輯註記都剝除，包含跨行註記。字體大小、傍點、縮排、換頁與外字描述不套用格式；外字 `※` 不重建字形。普通括號、不完整 ruby 與未閉合的編輯註記保留原文。

合成章節標題仍使用原本的 title builder，包含自訂章節標題設計；本次正文接縫未延伸到標題。標題內的 ruby 與編輯註記尚未處理。

TXT 索引版本由 v6 升到 v7，以移除符號的 UTF-16 範圍投影 v5/v6 的 `(spineIndex, charOffset)`。位置與書籤的起訖點先驗證實際舊／新渲染文字，再由同一個 transactional commit owner 寫入；重開 v7 不重複遷移。未改寫原始 TXT 位元組與來源 fingerprint。

已保存錯誤編碼的舊索引仍會因編碼身分不符停止，保留舊索引、位置與書籤；本次未實作跨錯誤編碼的位置重算。文字替換／繁簡轉換若讓舊與新文字無法證明相同來源，也保留資料並停止遷移。

中斷提交紀錄升到 v2，記錄移除青空標記後的最終位置。一般 TXT 的舊 v1 紀錄仍可重播；含青空標記的 v1 紀錄保留並停止，需要另外證明舊位置的投影才能重播。

## 修改範圍

- 新增：`TXTEncodingDetector.swift`、`TXTEncodingFrequencyData.swift`、`TXTTextDecoder.swift`、`AozoraMarkupParser.swift`、ICU 授權與 TXT 實體測試資源、`AozoraTXTTests.swift`。
- TXT：`TXTFileReader.swift`、`TXTFilePersistence.swift`、`TXTChapterParser.swift`、`TXTReaderPreparationService.swift`、`TXTLocationMigration.swift`、`TXTReaderIndexMigrationService.swift`。
- 渲染接縫：`TXTLazyAttributedStringBuilder.swift`、`NodeAttributedStringBuilder.swift`、`NodeAttributedStringRenderer.swift`。
- 工程設定與測試：App 的 `project.pbxproj`、五個 `.lproj/Localizable.strings`、`TXTFileReaderTests.swift`、`TXTReaderIndexMigrationTests.swift`、本文件。
- 共享工作區另外有一行必要的編譯修正：`FixedPageReaderViewController.swift` 對 optional toolbar 做 guard 解包。其他聊天的閱讀器／UI 修改保留。

沒有新增解碼、重試或替代讀取的兜底路徑。取樣截斷容忍與多檔案中斷提交 journal 是原有機制；映射章節的既有 UTF-8 replacement 路徑仍保留，沒有用它修正此次編碼偵測。

## 驗證

編碼修改前：`TXTFileReaderTests` 14 tests / 1 suite，25 issues；修改後：40 tests / 6 suites 通過。

青空文庫修改前：34 tests / 2 suites，15 issues，其中 `CoreTextWritingModeTests` 26 tests 先通過。假名邊界修正後，11 個青空測試通過；另外先以舊 v1 journal 實際重現普通 TXT 被拒絕重播的失敗，再修正相容性。

最後一次程式碼修改後的合併回歸：**82 tests / 10 suites，`TEST SUCCEEDED`；80 個實跑通過，2 個本機語料診斷測試跳過**。被跳過的兩個方法只接受既有 `~/Downloads/聚宝仙盆 (1).txt`，本機沒有該檔，沒有替換語料或更改其期望。

選測 struct：`TXTFileReaderTests`、`TXTMetadataProbeTests`、`TXTChapterBoundaryTests`、`TXTInitialPreviewPlannerTests`、`TXTLocationMigrationTests`、`TXTReaderIndexMigrationTests`、`TXTScrollJumpDiagnosticTests`、`AozoraTXTTests`、`CoreTextWritingModeTests`、`PlainTextParagraphFormattingTests`。覆蓋 NEC 字、JIS X 0212、中文長文、BOM、截斷取樣、跨 512 KiB 注音、補充平面漢字、中文書名、半形假名、註記剝除、v6 位置／書籤與中斷提交。

結果日誌：`/tmp/yuedu-txt-aozora-final.log`；編碼階段：`/tmp/yuedu-txt-encoding-green3.log`。本次生成的 `.xcresult` 已在測試結束後刪除。

所有 Xcode 測試均使用 `scripts/xctest.sh`，以 `scripts/sim.sh` 解析工具鏈與 simulator destination，使用 struct 名稱選測並核對 suite 數。未使用 `-derivedDataPath`。
