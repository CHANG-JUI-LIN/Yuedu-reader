# 快照去重後實際四組高壓比較

四組各自從第10章第一頁冷載入，再連續50次相同翻頁。CPU以事件窗口內各PID的累計CPU秒差÷實際採樣秒數計算；RSS使用同一窗口樣本峰值。每組只計完成的continuous events，設定、評論及額外翻頁均分開。舊資料為最後快照去重前的固定基線；每組只有一次實際run，不能視為多輪統計顯著性。

| 組別 | CPU 前→後 | 差異 pp | CPU秒 前→後 | RSS峰值MiB 前→後 | 快照繪製/命中 前→後 | <150ms同頁重畫 前→後 | 50步頁碼一致 |
|---|---:|---:|---:|---:|---:|---:|---|
| 全預設 OFF | 9.47%→9.86% | +0.39 | 7.17→7.66 | 661.6→662.5 | 88/12→48/52 | 44→0 | 是 |
| 全預設 ON | 19.44%→19.49% | +0.05 | 14.72→14.75 | 761.1→763.5 | 88/12→48/52 | 44→0 | 是 |
| 江湖 OFF | 29.56%→27.77% | -1.79 | 22.60→21.21 | 802.1→790.2 | 88/12→48/52 | 44→0 | 是 |
| 江湖 ON | 40.05%→40.40% | +0.35 | 31.10→30.85 | 890.6→888.3 | 88/12→48/51 | 44→0 | 是 |

## 章節與渲染工作量

| 組別 | 新章network 次數/總ms 前→後 | parse 次數/總ms 前→後 | jsNet總ms 前→後 | renderLeaves總ms 前→後 | 跨章數 前→後 | preload最大/秒 前→後 | 目的cache缺失 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 全預設 OFF | 4/2115→4/1015 | 4/73→4/75 | 0→0 | 45→39 | 4→4 | 1→1 | 0 |
| 全預設 ON | 4/2346→4/2086 | 3/12694→3/9886 | 12352→9536 | 1375→1265 | 4→4 | 1→1 | 0 |
| 江湖 OFF | 5/2502→5/1273 | 5/86→5/76 | 0→0 | 83→81 | 5→5 | 1→1 | 0 |
| 江湖 ON | 4/1753→4/1725 | 4/12386→4/18108 | 11992→17659 | 1536→1486 | 4→4 | 1→1 | 0 |

network、parse及jsNet是同一章流程的不同階段，jsNet包含於parse，不能相加成端到端。只計階段結束落在翻頁窗口內的trace；窗口末尾仍在背景執行的階段可能跨界。服務回應時間與進入新章數不同，不可把網路總ms差當本機快照修正效果。

## 第10章冷載入

| 組別 | loading→首個native REAL 秒 前→後 | after至capture2首次可見上界秒 |
|---|---:|---:|
| 全預設 OFF | 0.737→0.719 | 2.537 |
| 全預設 ON | 11.205→8.727 | 9.591 |
| 江湖 OFF | 0.725→0.643 | 2.739 |
| 江湖 ON | 8.718→35.058 | 35.730 |

精確SourcePerf cold階段及原始事件路徑見JSON各row.cold_load。capture2上界包含觀察延遲，不等於純網路延遲。

新四組均以正式五章cache提交、checksum及render artifact驗證完成作開始條件，無固定sleep。舊baseline前三組也在開始前完成；舊江湖ON最後spine10提交晚於stress開始0.944秒，因此該CPU前後比較仍含這個限制。

## 額外：首屏後立即高壓（不列主比較）

snapshot-after-default-on 沒等初始四章預取完成，Reader CPU33.57%。同頁重畫44→0，但舊baseline首屏後等36.84秒、新run僅0.42秒，前十秒混入11.02 CPU秒的冷預取工作。資料保留JSON，不能以此推論快照修正的整體CPU效果。

## 評論

評論以獨立review-events的tap起點→首次實際「楼」資料ready計時，不能以原生sheet或「关闭」骨架ready當資料完成；不混入50次翻頁主表。已完成評論資料另列JSON。

原始私有log／CSV／截圖只保留/tmp，報告不包含登入資訊。

| 評論run | tap→真樓層觀察秒 | 真drag次數 | Reader CPU | 活躍WebContent CPU | 活躍WebContent峰值MiB |
|---|---:|---:|---:|---:|---:|
| snapshot-after-default-on-review | 6.266 | 6 | 7.94% | 11.57% | 455.2 |
| snapshot-settled-after-default-on-review | 6.177 | 6 | 8.77% | 12.37% | 465.5 |
| snapshot-settled-after-jianghu-on-review | 6.207 | 6 | 12.02% | 12.32% | 463.8 |

tap→資料時間是單一連續driver的觀察端到端，包含命令送達、原生sheet和WebView觀察成本，並非純XHR。舊四組人工分次觀察含長工具間隔，不能拿其約100秒與此數字計算加速倍率。

## 關閉段評後純正文閒置

snapshot-settled-after-jianghu-on-idle：capture 71→72，193.260秒；Reader 6.469%（12.42 CPU秒／191.983採樣秒），RSS 742.9→773.0 MiB，峰值773.2 MiB。各WebKit進程累計CPU增量合計0.00秒。兩端AX均無WebView。

這次Reader閒置CPU高於舊約0.94%的測量，不能報成1%；該窗口沒有chapter/preload/snapshot SourcePerf事件。後續同章同App的評論前後診斷未穩定復現此值，詳見下節；保留6.47%的實際觀察，不依未取得的該窗口stack猜測修復。

## 未快取第20章遠跳（獨立驗證）

事前spine22 package不存在；loading→首個native REAL 15.267秒，driver tap→capture78觀察18.391秒。target只完成1次preload，9頁，滿5槽[11,12,13,14,15]加入後為[12,13,14,15,22]，目標保留，未重現自我evict迴圈。

此為App已開啟、字型/SVG資源暖機後的未快取章節，不與fresh-app第10章冷載混用。target network6855ms、parse6407ms（其中jsNet6296ms）、body render236ms。provider ready後的四個鄰章network另屬预取，未加到target耗時。

## 同章評論前後閒置診斷

PID87765，完整驗證20–24與10–14章快取後返回同一第10章，評論前sample30秒、真樓層與6次drag後關閉，再sample40秒。兩端正文均無WebView；UI診斷完整通過。

| 口徑 | Reader CPU 前→後 | CPU秒/採樣秒 前→後 | RSS峰MiB 前→後 |
|---|---:|---:|---:|
| sample開始→尾端snapshot ready | 0.74269%→1.59413% | 0.24/32.315→0.66/41.402 | 825.516→799.047 |
| sample header實際30/40秒，排除尾端snapshot | 0.74273%→1.62515% | 0.21/28.274→0.64/39.381 | 825.516→799.047 |

CPU以各窗口內首末CSV累計差計算，實際採樣覆蓋秒數短於完整窗口。所有WebContent與GPU增量均0；after僅WebKit network增加0.01 CPU秒。RSS為ps採樣，不與sample報告中的physical footprint混用。

主執行緒mach_msg2_trap等待：before20251/20549樣本（98.55%），after27893/28447（98.05%）；這是堆疊採樣占比，並非CPU百分比。after可見SwiftUI.prepare-image 125樣本，其中ImageIO/AppleJPEG解碼71樣本；主線_SwiftUIProxyImage.finish有126樣本等待圖片準備。ReaderView.body僅4個inclusive樣本，背景圖片getter含URL解析1、UIImage(contentsOfFile:)1；不足以判定每秒反覆重讀。Firestore/gRPC/JSC背景執行緒主要等待，兩段均未採到CoreTextPageEngine、CommentBubble或BookSourceSession。

同章純閒置本輪約0.74%→1.63%，沒有復現先前193秒窗口的6.47%；該舊觀察仍保留為未穩定復現的限制。現有stack沒有可確證新根因，因此未新增猜測式修正。診斷PID沒有SourcePerf輸出；精確sample窗口內App log為空，不把缺少trace當成獨立SourcePerf量測。

## 可支持的結論與限制

四組共200次實際翻頁，頁碼序列全部與基線一致，實際快照繪製352→192，同頁150ms內重畫176→0；最後江湖ON有99次請求（48繪製/51命中），並非強補成100。四組Reader總CPU並未一致下降，不能把快照微基準的45.93%下降當成App整體省電幅度。

江湖ON本輪冷第10章35.058秒必須保留：chapter.network1908ms、parse28381ms（其中jsNet28204ms）、body render1758ms（imageLoad1645.4ms）。相較舊8.718秒，jsNet增加24.537秒，加上主網路增加1.694秒，合计26.231秒，接近端到端增加26.340秒；body render舊1771→1758ms穩定。可定位此次主要延遲在實際來源網路/JS內網路等待，不能歸因快照快取，亦不能以單輪網路差宣稱穩定改善。

所有原始證據僅保留/tmp；四組UI各Passed1/1、warnings0由root核對。所有before固定快照檔保持不變。
