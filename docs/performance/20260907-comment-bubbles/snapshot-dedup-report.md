# 同次 curl 中間頁背面快照去重

## 已確認根因

正式四組之後額外的 40 秒江湖 ON 操作 sample，對 19 個不同中間頁記錄 38 次實際 snapshot render，每頁恰兩次，間隔約 35–92 ms。UIKit 的 transitionViewControllerStack 及 viewControllerAfter 兩條路徑都取得 curlBackPage，既有 CoreTextPageEngine 僅快取首尾頁，因此同次中間頁背面重畫。該窗口 preload done 為 0，不是先前章節供應迴圈。

## 修正與契約

CoreTextPageEngine 將中間頁也存入原有 chapterSnapshots NSCache，維持原本裝置分級 cost/count 上限（16/32/64–128 MiB；4/6/12 張）。沒有新增全書圖片快取。快照以已安裝 layout 的 UUID revision、spine、localPage 識別，避免依全域頁碼混淆。revision 字典僅保留 LayoutCache 內章節。

內容 refetch、版面／尺寸變更、外觀變更及記憶體警告都使舊 key 失效；每次 layout install（包含 partial→full）取得新 revision。背景首尾頁 render 返回時須通過相同 commit guard，過期結果不得重新插入 cache；已同步完成的相同 key 不會被稍後背景結果覆蓋。

## 相同 fixture 前後數字

自含固定 CJK 章節、360×560 pt；等待 full pagination 後每輪24個中間頁，各連續請求2次，三輪。無網路、不讀實際來源。

| 指標 | before | after |
|---|---:|---:|
| 48 requests，第1輪 ms | 189.221 | 102.307 |
| 第2輪 ms | 195.356 | 103.260 |
| 第3輪 ms | 188.444 | 94.233 |
| 中位數 ms | 189.221 | 102.307（-45.93%） |
| 同對 UIImage identity 共用／輪 | 0/24 | 24/24 |
| 三輪 SourcePerfTrace rendered 次數 | 144 | 71 |
| 三輪 SourcePerfTrace cached 次數 | 0 | 73 |

每對第二個 request 均共用；after 另有一次跨輪 retained cache 命中。SourcePerfTrace 的 leaf ms 是四捨五入整數，總 elapsed 採 fixture 高精度 uptime。每輪首對 PNG 相同，correctness suite 另驗證 first/middle/last 真實黑白外觀 PNG 變更、refetch 內容像素變更、resize 尺寸變更及舊非同步 key 拒收。

第一次 after 的配色 case 初始 .label/.systemBackground 在回歸模擬器為 dark，故切到相同白字黑底未改像素。測試現先固定黑字白底，再驗證黑底白字；保留 PNG 變更斷言。after2 全4項通過。

原始數字：/tmp/yuedu-snapshot-before-metrics.txt、/tmp/yuedu-snapshot-final-metrics.txt。结构化比較：/tmp/yuedu-snapshot-comparison.json。

## 實際 App 範圍限制

原四組正式50次矩陣保存為 final-matrix.before-snapshot-dedup.metrics.json 及 /tmp/yuedu-final-live-matrix.before-snapshot-dedup.md，屬此次去重前基線。這個簡單 CJK fixture 的45.93%不能代表完整閱讀器 CPU 改善率，也不能將整個江湖主題約20pp額外CPU都歸因於快照。實際 snapshot-after 四組仍由 root 同流程重測。背景 JPEG decode 樣本尚未證實圖片 identity 重建根因，未在此次改動。

## 最終驗證與交付

- /tmp/YueduSnapshot-after-20260908-2.xcresult: 4 passed, 0 failed。
- /tmp/YueduSnapshot-ReaderChapterSupplyTests-20260908.xcresult: 13 passed, 0 failed。
- /tmp/YueduSnapshot-ReaderRenderRefreshTests-20260908.xcresult: 11 passed, 0 failed。
- /tmp/YueduSnapshot-ReaderPresentationContractTests-20260908.xcresult: 17 passed, 0 failed。

合計45/45項通過；build-for-testing exit0。固定編譯快照 /tmp/yuedu-reader-snapshot-dedup-after.app；完整 app/xctestrun 路徑及核對 SHA256 在 /tmp/yuedu-snapshot-build-handoff.json。未操作 Profiling Simulator。
