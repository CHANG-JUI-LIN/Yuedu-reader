# 紅樓夢基線差異調查（2026-09-09）

狀態：調查中；已修正一個獨立重現的片段量寬錯誤。原始 `redchamber.tsv` 未修改。

## 問題與比較邊界

Phase 5A Task 5–7 擴大回歸發現 271 章與既有 golden 不同。上一輪已證明：Task 7 實作前的 `b06801de` 也有逐字相同的失敗，因此這批差異並非由 Lexbor 長屬性映射新增。

本輪區分近期程式變更、歷史程式重跑結果與已提交基線。三份資料的角色如下：

- **G**：已提交的 golden，SHA-256 `bb8ce279d3f7b3254705d07bc62557956d29a27f9e68f012e0dcbd1619a24f5f`。
- **H**：`a4715bc156239795542789452aeb967ba87f89c5` 歷史程式，在今日環境重跑。
- **C**：Task 7 工作目錄、下述片段量寬修正之前的程式（起點 `b06801de`），在同一今日環境重跑。此診斷仍走 Current frontend，未切換成 Lexbor。

[pre-integration.json](../lexbor-migration/pre-integration.json) 記錄 H 在 iOS **26.5（23F77）** 的 458 章基線全數通過。今日只安裝 iOS **27.0（24A5423a）**；本輪使用獨立的同型 iPhone 17 Pro Max 模擬器，viewport／reader settings／EPUB 不變。歷史資料沒有保存這本 EPUB 的檔案 checksum，因此 **H 與 G 的差異不能僅憑本輪就全部斷定為 OS 變更**；仍須保留 runtime、font environment、fixture identity 的歸因限制。

## 已完成的代表章節控制

零起算 spine：`0, 4, 15, 17, 31, 138, 300, 457`。每組均實際執行排版後比較，沒有放寬數字容差。

| 控制狀態 | 與 G 不同的章數 | 頁數總和 | 文字 fragment 總和 |
|---|---:|---:|---:|
| 現行字型解析 + 現行 reader line-height | 7 | 123 | 4,010 |
| 現行字型解析 + 關閉 reader line-height | 7 | 119 | 4,010 |
| 舊字型解析 + 現行 reader line-height | 6 | 116 | 3,956 |
| 舊字型解析 + 關閉 reader line-height | 6 | 112 | 3,956 |
| 再還原 fallback descriptor 的 size 0 | 6 | 112 | 3,956 |
| 歷史程式 H 原樣執行 | 6 | 112 | 3,956 |

最後三個狀態的 8 行 fingerprint **逐字一致**。控制只在隔離 worktree 暫時改動，完成後還原；沒有將舊字型／行距行為放回產品。

第一個差異 spine 4 可由舊字型解析完整還原；spine 15、17 等即使使用歷史程式 H，在目前環境仍不能對回 G。

## 原因線索

- `43481b6c` 將 `BrowserLayoutConfig.lineHeight` 接入繼承；以前設定值存在但沒有作用。現行設定有實際效果，作者宣告仍可覆蓋，已有 `BrowserReaderParityTests.readerLineHeightInheritsAndAuthorDeclarationWins`。
- 同一提交改變 `InlineLayout.resolvedFont`：搜尋整個 font-family list、保留原字型 family、加入 Unicode fallback，並維持粗體／斜體語義。這些會改變實際 glyph advance、ascent／descent 及分頁。
- `6ef53fd1` 修正 fallback 字級，避免粗體 CJK 被縮到 12pt。本輪代表章節還原 size 0 未增加差異，不能將它視為這組差異的原因，也不能因此撤銷字級修正。
- 歷史程式 H 在目前環境仍有差異，故不能用撤銷近期功能修正的方式讓全部 G 回綠。

## 全書比較

兩組皆覆蓋 458／458 章，沒有略過；C 再現原先 271 章差異。逐章資料見 [全書三方對照](attribution-2026-09-09.tsv)。

| 分類 | 章數 | 判定 |
|---|---:|---|
| 全部一致 | 187 | G = H = C |
| 僅近期程式差異 | 30 | G = H，C 不同 |
| 歷史重跑與近期程式差異重疊 | 241 | G、H、C 三者各不相同 |

| 狀態 | 總頁數 | 總文字 fragment |
|---|---:|---:|
| G：既有 golden | 3,820 | 137,294 |
| H：歷史程式、目前環境 | 3,809 | 137,018 |
| C：現行程式、目前環境 | 4,204 | 139,402 |

H 對 G：11 章頁數改變、146 章 fragment 數量改變。C 對 H：271 章 fingerprint 改變。這裡沒有將 241 章稱為「只有 OS 差異」；它們同時受到近期程式變更影響。

現行版測試同時跑 `BrowserReaderParityTests`、`ReaderBoldCJKFontSizeTests`、`BrowserLayoutFontFallbackTests`：連同資料擷取測試共 14 個方法／16 次執行，0 failed／0 skipped。**資料擷取測試通過不等於 G 的 equality gate 通過**；C 與 G 仍有 271 章不同。

全書還原字型／行距控制完成：458／458 行與 H **逐字一致**，0 額外差異。此結果限定了近期程式差異的來源範圍；仍未解釋 H 對 G 的 241 章差異。

## spine 17 的字元層檢查

檢查的是本章第一個文字 fragment（source range `{1, 20}`），並非將它當作全書所有差異的共同根因。G 與 H 的文字 digest 都是 `391c3e45`，X、Y、高度及 baseline 相同；寬度由 `337.49` 變成 `333.24`，相差 `-4.25pt`。

H 的保留 `CTLine` 只有一個 glyph run：`.PingFangUITextTC-Regular`、17pt、identity matrix；`CTLineGetTypographicBounds` 為 `333.23638132295713`。fragment 四捨五入後的寬度直接對應這個值，因此本處沒有在 fragment／分頁階段額外減掉 4.25pt。G 沒有逐 glyph 的歷史紀錄，尚不能指出當時哪個 advance 不同。

相同文字的實際 CoreText 控制結果：

| 控制 | 寬度（pt） | 判讀 |
|---|---:|---|
| 原始屬性；直接建 line／typesetter 建 line | 333.236381 | 兩條建立方式相同 |
| 明確 `zh-Hant` | 333.236381 | 未還原 G |
| 明確 `zh-Hans` | 328.986381 | 未還原 G；整章也不能對回 |
| 明確 kerning 0 | 337.023346 | 數值接近但不等於 G，不能作為修正 |
| ligature 0／1／2、tracking 0、三種 paragraph line-break strategy | 333.236381 | 未還原 G |
| 改後接字元或分割顏色屬性 run | 333.236381 | 只有低於 1e-12pt 的浮點差異 |

字元 probe 顯示目前 UI 字型的單獨逗號／句號 advance 為 `8.582684824902724`，與漢字相鄰時有 `4.25pt` 的間距調整。這解釋了為何檢查標點，但 **4.25pt 相同尚不足以證明它就是 G → H 的原因**。OpenType `chws`／`halt`／`palt`／`kern` 的設定回讀為 nil，不能聲稱已成功切換那些 feature；AAT text-spacing selector 回讀有效時，也沒有還原 G。

所有字型、語言、行距及測試 helper 的暫時修改已還原；診斷程式另存於本機 `/tmp`。還原後親自重跑 `BrowserReaderParityTests`、`ReaderBoldCJKFontSizeTests`、`BrowserLayoutFontFallbackTests`，13 個方法通過、0 failed／0 skipped。未加入語言覆寫、固定字距或標點補償到產品，原 golden 不變。

## 後續控制與已證實的片段量寬錯誤

將寬度控制為整段文字中的 advance，可精確得到 spine 17 首行的 `337.49pt`。再加入段落邊界上下文、以 CoreText 重新建議超寬行的斷點後，spine 17／31 的頁數、片段數與首尾 geometry 可對回 G，但完整 fingerprint 仍不相同；四個代表章節沒有一章完整對回。這些控制只用於診斷，已全部還原，沒有將上下文填字或另一套斷行模式放進產品。

沿同一路徑找到可獨立重現的現行程式錯誤：`InlineLayout.makeLayoutLine` 把每個 DOM 片段截成 attributed substring，再以新的 `CTLine` 單獨量寬。相鄰文字節點即使字型與樣式相同，也因此失去跨片段的字偶距，片段 X／width 與保留的整行 `CTLine` 不一致。

- 紅燈證據：40pt 的短文字測試出現 `2.578125pt` 寬度誤差。
- 修正：片段直接消費保留 `CTLine` 中相交 `CTRun` 的 advance；同一 run 內的切分沿用 caret offset，run 邊界使用自身的左右邊緣，避免 bidi 邊界的另一個 caret affinity。最後一段仍受原本的整行 authoritative width 約束。
- 沒有修改 `CoreTextLineBreaker`、字型選擇、reader line-height、golden 或數字容差。
- 新增 `BrowserLayoutInlineRunGeometryTests`，驗證字偶距、連字、CJK、RTL 片段寬度、後續行的 paragraph string index，以及實際 HTML `<span>` 流程。工作目錄最終回歸：4 個方法／9 次執行通過，0 failed／0 skipped。

新增的跨行測試曾誤把 soft-break end caret 當成行尾 advance。原始 glyph positions／advances 證明某行實際終點為 `71.19140625pt`，end caret 為 `76.34765625pt`；修正測試使用最後 glyph 的 advance 終點後通過。這是新增測試的 oracle 修正，原有 golden 與容差均未改。

### 修正的回歸與整合範圍

隔離工作目錄的片段量寬最終回歸為 4 個方法／9 次執行通過。相同產品程式另通過字型 fallback（9）、選取契約（4）、source mapping（5）、determinism（4），以及逐類執行的 ruby measurement（3）、ruby fragment（2）、ruby interaction（3）、圖片（20）測試，均無跳過。全書擷取所在的中間 bundle 曾包含一個新增測試 oracle 失敗，不能把該 bundle 整體標成通過；該方法已在最終回歸修正並通過。

產品修正及新增測試已帶回主工作目錄。首次整合建置遇到 AutoReadController 與既有檔案重複宣告 `DisplayLinkProxy`，因此未執行測試。使用者確認自動閱讀正在另一個 task 修改，本輪未修改那些檔案。後續核對重複宣告已由另一邊移除，重新在主目錄逐類執行 InlineRunGeometry（4）、FontFallback（9）、SelectionContract（4）、RubyMeasurement（3）、RubyFragment（2）、RubyInteraction（3）、SourceMapping（5）及 Image（20）：8 類／50 個方法通過，0 failed／0 skipped。其中新增幾何測試的 4 個方法實際包含 9 次執行。主目錄與隔離工作目錄的量寬修正、新增測試內容一致。

### C2：片段量寬修正後的全書對照

| 指標 | 結果 |
|---|---:|
| 比較章節 | 458／458 |
| 相對 C 的 fingerprint 改變 | 163 |
| 頁數或文字片段數改變 | 0 |
| 總頁數／文字片段數 | 4,204／139,402，均未改變 |
| 與歷史 PRE 的逐章文字長度差異 | 0；合計 2,231,613 UTF-16 units |
| 相對 G 的差異 | 272 章 |

逐章變更見 [片段量寬修正對照](attribution-2026-09-09-run-geometry.tsv)。新增的 G 差異為 spine 135：1 頁、12 個文字片段及首尾 geometry 均不變，內部片段 geometry digest 改變。舊 G 原有的 271 章差異仍在；本次修正沒有讓基線 gate 回綠。

逐章文字長度與歷史 PRE 相同，增加了輸入一致性的證據；歷史資料仍缺少 EPUB 位元 checksum 與逐 glyph capture，不能據此宣稱所有輸入位元相同。

## 測試程序與產物

第一輪共用模擬器上的診斷遭 SIGKILL，未產生完整比較資料；測試日誌顯示已進入排版、沒有啟用 test timeout。未將此失敗視為通過，也未武斷認定終止原因。之後使用本輪建立的獨立模擬器。

[代表章節控制資料](attribution-2026-09-09-sample.tsv)保存各狀態的完整 fingerprint。

本機 xcresult、控制版測試檔及原始記錄位於 `/tmp/yuedu-linebreak-20260909/`。提交到 docs 的資料只保存幾何及 digest，不包含書籍正文。

## 決策

目前不應直接覆寫原 golden，也不應撤銷已驗證的字型／行距功能修正。

撤回先前未經證實的系統歸因及 runtime 選項。歷史程式也失敗只定位了比較邊界，沒有證明根因。近期程式差異已由 458 章還原控制限定在字型／行距政策；H 對 G 的 241 章仍未完成歸因，不能宣稱修復完成。

原 golden 未改，本輪未 commit；C2 相對 G 仍有 272 章差異，Phase 5A 尚未結案。
