# 正式相同起點四組50次連續翻頁矩陣（四組50次均已完成）

與較早的混合快取/不同起點額外壓測完全分開。每組由root先備份與清除整本chapter cache、清持久qd_title_svg、重啟App，從《夜无疆》第10章第一頁開始50次連續仿真翻頁。全預設組先delete defaults domain再import預設設定，並以畫面驗證背景/字體；不能只憑xcresult名稱判定設定。

資料來源：`/tmp/yuedu-reader-profiling/final-matrix.metrics.json`，目前包含四組正式continuous、各組cold_load與獨立review結果；所有原始資料保留/tmp，不進repo，不含登入資料。

| 指標 | 全預設 OFF | 全預設 ON | 江湖 OFF | 江湖 ON |
|---|---:|---:|---:|---:|
| PID | 68738 | 70070 | 72190 | 73705 |
| 完成tap／實際連續頁面變化 | 50／50 | 50／50 | 50／50 | 50／50 |
| waitForPage事件 | 0 | 0 | 0 | 0 |
| 起點 | 第10章1/12 | 第10章1/13 | 第10章1/11 | 第10章1/12 |
| 終點 | 第14章8/9 | 第14章3/10 | 第15章6/8 | 第14章9/9 |
| 實際跨章界 | 4次 | 4次 | 5次 | 4次 |
| script事件總時間 | 77.171s | 76.781s | 77.259s | 78.519s |
| CPU實際採樣跨度／筆數 | 75.711s／76 | 75.734s／76 | 76.444s／77 | 77.659s／78 |
| Reader累積CPU秒差 | 7.17s | 14.72s | 22.60s | 31.10s |
| Reader平均CPU | **9.47%** | **19.44%** | **29.56%** | **40.05%** |
| Reader RSS首→尾 | 642.031→647.016MiB | 675.266→761.141MiB | 768.266→681.172MiB | 767.594→877.609MiB |
| Reader RSS最高 | **661.578MiB** | **761.141MiB** | **802.094MiB** | **890.594MiB** |
| WebContent/Networking CPU秒差 | 每個程序皆0.00s | WebContent合計0.16s／Network0.02s；另GPU0.15s | 每個程序皆0.00s | WebContent合計0.16s／Network0.03s；另GPU0.14s |
| chapter.network（窗口內完成） | 4次／合計2115ms，最大1181ms | 4次／合計2346ms，最大1242ms | 5次／合計2502ms，最大1379ms | 4次／合計1753ms，最大592ms |
| chapter.parse | 4次／合計73ms，最大25ms | 3次／合計12694ms，最大5443ms | 5次／合計86ms，最大36ms | 4次／合計12386ms，最大3607ms |
| chapter.jsNet | 無該trace | 3次／合計12352ms（parse內含） | 無該trace | 4次／合計11992ms（parse內含） |
| chapter.nextContent | 4次／全0ms | 3次／全0ms | 5次／全0ms | 4次／全0ms |
| 正文renderLeaves | 6次／合計45ms，最大14ms | 6次／合計1375ms，最大276ms | 7次／合計83ms，最大14ms | 6次／合計1536ms，最大376ms |
| fullLayout | 6次／合計31ms | 6次／合計593ms | 7次／合計21ms | 6次／合計564ms |
| reader.chapter.available | 4次／合計27ms | 4次／合計151ms | 5次／合計31ms | 4次／合計154ms |
| reader.chapter.replaced | 0次 | 0次 | 0次 | 0次 |
| preload begin／done | 6／6 | 6／6 | 7／7 | 6／6 |
| 最大每秒begin／done | **1／1** | **1／1** | **1／1** | **1／1** |
| done後快取缺目標 | **0次** | **0次** | **0次** | **0次** |

全預設OFF時間窗口：2026-09-07 23:47:25.430–23:48:42.601（monotonic342417.763228–342494.933883）。capture2為第10章1/12，capture3…52共50個tap，各頁正確遞增或由末頁跨到下一章1頁，沒有重複/跳過頁碼。閱讀位置log依序spine12→13（23:47:43.635）→14（23:47:59.302）→15（23:48:16.569）→16（23:48:31.903），與第14章8/9的末張可及性一致。

本輪全部renderLeaves均leaves=none，包含窗口前冷載第10章11ms，以及窗口內spine11/13/14/15/16/17的14/8/7/6/5/5ms。未殘留來源ON圖像。初次冷載第10章发生23:45:44，位於翻頁script之前，因此冷載耗時不混進翻頁CPU；4次網路是窗口內完成的新章請求，不是50次翻頁總延遲。jsNet未出trace只能說未觀察到已記錄的JS網路span。

CPU方法：在events.start/end內按monotonic挑CSV，首尾cpu_total_s差除以首尾monotonic差；100%代表一個CPU core。不平均ps的rolling百分比，不把setup/idle混入，不以RSS推算耗電。每秒採樣首尾內縮，因此CPU分母75.711s，不是77.171s。章節網路/parse/render是可能重疊或內含的span，不能全部相加當端到端。

此前clean-jianghu-off-continuous從第11章末起跑、跨7章，僅作額外壓測留在`/tmp/yuedu-clean-live-matrix.md`，不進本正式四組比較。

## 全預設ON追加核對

PID70070事件窗口為2026-09-07 23:58:25.664–23:59:42.445（monotonic343077.989732–343154.770582），本次50次翻頁本身仍在9/7午夜之前，後續review才跨日。source111已由root核對；capture2第10章1/13，capture3為2/13，capture52第14章3/10；50個tap皆符合下一頁或末頁→下一章1頁，無wait事件。章界log為spine12→13（23:58:45.359）→14（23:59:04.060）→15（23:59:22.527）→16（23:59:39.457）。

renderLeaves原始trace有12筆，其中6筆為單字元章標題圖且四捨五入0ms，6筆為正文263/276/213/231/180/212ms，不是同正文重建兩次。正文合計1375ms中imageLoad1232.8ms；native bubbleDraw8.7ms、bubbleTrim7.8ms、bubbleRecognize23.4ms。葉節點為內含時間不可再與renderLeaves總和相加。

ON窗口末有一個預載網路已完成、parse尚未結束，故network4筆而parse/jsNet只有3筆：該parse於23:59:43.534完成3592ms，jsNet3470ms；這兩筆在事件end之後，未計入表中窗口總量。4筆完整parse若作附加「同批請求完成」觀察合計16286ms，jsNet15822ms，但不得混入窗口CPU或與OFF表中欄位直接替換。

OFF/ON同樣50次操作且起點第10章，ON圖片占位使總頁數不同，因此终點OFF第14章8/9、ON第14章3/10。CPU19.44%對9.47%表示此套來源內容的ON有額外操作成本，不能全歸到氣泡畫圖：來源評論網路、完整SVG資源、CoreText排版和內容量都包含其中。兩組皆沒有原先每秒數十次自我逐出的重建循環。兩個江湖組的最終結果已補在同表，解讀見文末四組比較。

## 獨立書評操作：全預設ON（不混入50次翻頁）

同chapter10點第一段氣泡。command60後第一快照尚未見WebView；61快照為WebView載入中；62已見實際段評與關閉按鈕。command63–68為6次真drag，窗口取capture62.ready→68.ready：**2026-09-08 00:07:52.000–00:08:19.334，27.333秒**。27筆CPU樣本首尾跨度26.222秒。

| 程序 | CPU累積秒差 | 平均CPU | RSS開始→結束／最高 |
|---|---:|---:|---|
| Reader PID70070 | 2.35s | **8.96%** | 734.797→734.188／735.578MiB |
| 活躍評論WebContent PID71039 | 3.42s | **13.04%** | 366.953→443.922／443.922MiB |
| 其餘各WebContent | 各0.00s | 各0% | 未作合併記憶體結論 |
| WebKit GPU PID70106 | 0.82s | 3.13% | 175.328→177.500／183.031MiB |
| WebKit Networking PID70084 | 0.16s | 0.61% | 153.188→153.953／153.953MiB |

載入只能說：capture60（點擊後）到首次觀察到已載入的capture62相隔**119.416秒**；61最後觀察到loading到62已完成間隔118.179秒。中間包含root工具操作/思考空檔，這是觀察間隔，不是實際網路延遲或source解析秒數，也不能稱120秒才載完。

command69以header向下drag關閉，69及70快照均無WebView，確認回正文。70後到71的短時間不列為長期idle測量。此操作結果不表示來源HTML內部「关闭」按鈕已修好，只確證sheet手勢關閉成功。

JSON同一份`final-matrix.metrics.json`新增獨立`final-default-on-review-scroll`項目，kind為review-scroll；與兩個continuous paging項目分開。

## 江湖OFF追加與關閉書評後的程序核對

正式江湖OFF PID72190於2026-09-08 00:18:16.068–00:19:33.327連續50次，從第10章1/11到第15章6/8，50個頁碼轉換全部連續有效、無wait；章界spine12→13（00:18:32.624）→14（00:18:46.924）→15（00:19:00.940）→16（00:19:13.392）→17（00:19:25.724），跨5次。Reader平均29.56%，正文render總和83ms、fullLayout21ms。此輪背景/字體/排版為完整江湖設定；不是只換氣泡樣式，所以CPU增加不能全部歸到來源bubble。RSS中途下降，沒有按起終點單調推估洩漏。

### defaultON書評關閉後（補充較長實際觀察）

前文僅依AX無WebView，現在已核對程序級CSV：評論WebContent PID71039最後一次存在於**00:10:20.789**，累積CPU14.950秒；69.ready為00:10:21.207，70.ready為00:10:22.431。從70→71到71→stop81，PID71039都沒有任何樣本；同一Simulator的Reader與其他WebKit每秒採样持续，因此不是sampler停掉。沒有觀察到該評論程序關閉後繼續佔CPU。缺少存活樣本不能寫成「測得該PID CPU差0%」，而是程序已不在同sim程序監測中。

- **70→71正文/末端開menu窗口**：00:10:22.431–00:11:44.011，81.579秒事件；81筆採樣跨度80.813秒。Reader CPU0.80秒／**0.99%**；其餘各WebContent與GPU CPU差均0，Networking0.02秒／0.025%。原先以為只有很短間隔，實際ready時間相隔81秒；仍不延伸成長期電量結論。
- **71→stop81設定/原生登入操作窗口**：00:11:44.011–00:14:04.895，140.883秒事件；139筆採樣跨度139.391秒。Reader5.37%包含原生設定操作，不能當idle；原評論PID仍缺席，其他各WebContent/GPU/Networking CPU差均0。

尚無「關閉後review PID持续數% CPU」證據，因此沒有根據去修改coordinator閉包或聲稱retain cycle根因。關閉後實際程序資料已放同JSON review項目的after_close_windows，不混進50次翻頁主表。

## 江湖ON完成與四組比較

最後一組PID73705，2026-09-08 00:28:28.837–00:29:47.355，50/50頁碼連續有效，無waitForPage；第10章1/12→第14章9/9，4次跨章。spine12→13（00:28:46.996）→14（00:29:02.879）→15（00:29:18.796）→16（00:29:34.832）。原先每秒數十次反覆預載的症狀未重現，6次preload done都保有目標；最大每秒1次，四組皆如此。

最後組12筆renderLeaves中6筆為0ms章標題node，正文6筆376/286/267/236/203/168ms，合計1536ms。正文葉節點imageLoad1239.8ms、native bubbleDraw26.4ms、bubbleTrim14.8ms、bubbleRecognize33.5ms；全預設ON相應imageLoad1232.8ms、bubbleDraw8.7ms。這些是渲染span內含時間，並非整個翻頁CPU。

四組均从第10章第一頁、50次同類型操作，均使用最終同一production。單次觀察CPU为全預設OFF9.47%、ON19.44%；完整江湖OFF29.56%、ON40.05%。來源ON相對OFF約增加9.97／10.48百分點；完整江湖相對全預設約增加20.09／20.61百分點。因此完整主題在來源OFF時仍有可見操作CPU成本，不能把全部差異歸因native氣泡或評論WebView。這不是只切換一個CSS屬性的受控試驗，字型、排版、背景圖等設定一起變；要定位主題剩餘約20百分點成本還需該操作窗口的stack/leaf歸因，不能直接猜為某一張背景。

每組只有一次50次串行操作，尚無重複試驗誤差範圍；ON圖像與主題字型改變每頁字數，四組终點分别14章8/9、14章3/10、15章6/8、14章9/9。江湖OFF跨5章，其餘4章，所以不能把不同網路請求數的總量當相同工作吞吐比較。网络也是真實外部服務，不能保證四次同延迟。

各窗口新章网络OFF為4次2115ms、江湖OFF5次2502ms；ON為4次2346ms、江湖ON4次1753ms。來源ON的JS網路另外包含於chapter.parse，觀察到的parse成本大多是它：全預設ON窗口3筆parse12694ms中jsNet12352ms；江湖ON4筆parse12386ms中jsNet11992ms。全預設ON末筆parse3592ms於窗口後才完成，若追完整批次则4筆parse16286ms、jsNet15822ms。不可把「3筆12694 vs4筆12386」當成江湖解析較快的證据；它只說來源ON本身啟動了秒級評論網路工作。

## 第10章冷載：分開於50次翻頁窗口

從App重新啟動、整書cache清除後，`chapterStates[12] nil→loading`到第一個`pageVC REAL spine=12`的日誌事件差。這是App載入狀態到原生頁面建立，不是手指接觸至螢幕發光的量測。另列loading到capture2首次確認頁碼的觀察上界。

| 指標 | 全預設OFF | 全預設ON | 江湖OFF | 江湖ON |
|---|---:|---:|---:|---:|
| loading→first REAL | **0.737s** | **11.205s** | **0.725s** | **8.718s** |
| loading→首次已載入capture2上界 | 2.518s | 11.419s | 2.792s | 9.740s |
| chapter.network | 515ms | 487ms | 280ms | 214ms |
| chapter.parse | 59ms | 6085ms | 12ms | 3832ms |
| 其中chapter.jsNet | 無該trace | 5910ms | 無該trace | 3667ms |
| chapter.nextContent | 0ms | 0ms | 0ms | 0ms |
| 正文HTML parse | 2ms | 101ms | 2ms | 101ms |
| 正文renderLeaves | 11ms | 1871ms | 17ms | 1771ms |
| 另標題node render | 無獨立图 | 5ms | 無獨立图 | 17ms |
| fullLayout | 13ms | 141ms | 5ms | 135ms |

全預設ON初章imageLoad1811.9ms、江湖ON初章imageLoad1664.7ms，冷SVG成本遠大於暖native count bubble draw。ON兩組冷載相差2.487秒，但僅JS網路已相差2.243秒，不能以此宣稱完整江湖比全預設載入更快或更省。

capture1為tap之後的快照，晚於loading約0.2秒，因此capture1→2的差值不是完整tap載入上界；command1在runner啟動前已預寫，若以其mtime起算又會混入約10秒setup。本表採原生事件時序與首次可見觀察，避免以上兩種偏差。

所有資料仍在同一`/tmp/yuedu-reader-profiling/final-matrix.metrics.json`，各continuous項目有cold_load；獨立review-scroll保留自身window，未混入翻頁表。先前原生fixture的程式修正before/after與本表最終production不同設定對比亦不可互相替代。

## 江湖ON書評與關閉後閒置（獨立窗口）

command60點第10章第一段氣泡；61雖已出現「关闭」，只是sheet/Web頁骨架，**不能算評論資料已完成**。首次確證真資料在capture62：有「80 条」與實際樓層；67已出現下一批樓層與「第 2 / 4 页」。只萃取這些數量/頁碼標誌，未保存評論正文或使用者資料。

command62–67為6次真drag。這次第一個drag的62快照才首次確認真資料，因此主要操作窗口採**command62送出→capture67.ready，00:32:53.568–00:33:20.310，26.742秒**，完整包含6次drag。26筆採樣跨度25.239秒，Reader2.10 CPU秒／**8.32%**；評論WebContent PID74233為3.20 CPU秒／**12.68%**；GPU3.09%、Networking0.24%。Reader RSS最高924.469MiB；評論WebContent367.531→463.469MiB，最高463.469MiB。其餘WebContent CPU差各0。

另保留嚴格「已確認data後」62.ready→67.ready窗口22.257秒（包含後5次完整drag）：Reader7.93%、評論WebContent12.36%。它不等同全預設ON的62→68六次drag窗口，不能因8.32%與8.96%的小差直接判主題書評更省。這兩組均是來源Web頁捲動，與正文CoreText翻頁完全分列。

載入觀察：60點擊後快照→首次data62相隔105.352秒；61骨架→62真data相隔102.876秒；command60寫入→62首次真data上界106.277秒。中間有長工具空檔，不能當精確網路延遲；本窗口App log未找到有耗時的XHR/SourcePerf span，可確認資料完成的證據是62與67，無法從骨架按鈕反推API完成時間。

68手勢關閉與69快照皆無WebView。評論PID74233最後採樣為00:33:46.999（累積CPU8.810秒），早於68.ready00:33:47.253；之後同sim其他程序持续採樣而74233不再出現。**69→70完整純正文閒置109.276秒**，108筆採樣跨度108.065秒，Reader CPU1.01秒／**0.935%**，所有仍存活WebContent、WebKit GPU/Networking CPU差均0，未觀察到評論關閉後繼續動畫負載。

閒置stack sample `/tmp/yuedu-reader-profiling/final-jianghu-on-idle.sample.txt`（00:34:50.424，獨立5秒採样）主線3174樣本中3149停在mach_msg2_trap，約99.21%是等待；這是堆疊採樣占比，不是CPU百分比。physical footprint199.8MB與CSV RSS約925MiB是不同口徑，不能互換或直接當作洩漏量。

### 真實滿快取反向跳驗證

50次高壓後command56從第14章跳回第10章。00:30:37.862先更新anchor16→12；38.005 preload12時5槽全滿 `[13,14,15,16,17]`；38.016完成後變為`[12,13,14,15,16]`，目的12保留。鄰章11於38.025完成後`[11,12,13,14,15]`仍保有12；同時pageVC REAL spine12已出現。這是實際满5槽、反向跳而目的未自我逐出的證據，preload12本身11ms。後續額外30次與40秒paging sample只用來歸因操作CPU，不加入正式四組50次數據。
