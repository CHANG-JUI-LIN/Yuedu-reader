# 發現

- 報告六項缺口針對橫排可重排 EPUB 分頁；指定的線上書評情境主要走 CoreText/Online 管線，必須分別補齊功能與診斷負載。
- 上輪已修 chapter routing invalidation、背景、頁碼、旁白/TTS 高亮與外觀包還原；相關 79 項測試通過。
- 模擬器可用 iOS 27，工具鏈 Xcode-beta；動態解析 destination，勿同時跑測試/安裝。

## 使用者補充的比較要求
- 不限江湖俠客：任何氣泡都會慢。比較全部預設 vs 完整江湖俠客主題；各組對照氣泡關閉／顯示／點開書評／關閉書評後靜置。
- 另以來源、內建、自訂模板 fixture 隔離 artwork 的成本。不能以某個 PNG cache 的改善推論所有氣泡都已修好。
- 無需實機資料；本輪使用 Xcode+Simulator CPU/記憶體/trace，實機耗電和溫度不作量化結論。

## 已定位的功能回歸細節
- Browser 的選字需要 glyph 命中，CTLineGetStringIndexForPosition 回的是 caret insertion position；emoji 右半容易回傳下一字。已用相鄰完整 composed cluster 的 shaped rect 判定，5項focused regression通過。
- RTL run 的 logical start 是 physical right edge，幾何需用兩端 min 作原點；ruby handles 需取base linear mapping，不能用最後一塊rt highlight。
- Browser新粗體測試發現Georgia-Bold的fallback仍為PingFangSC-Regular(weight0)，正在共用ReaderFontCascade補native bold fallback，保留實際字級。
- 尚未量測假說：SVGWebViewRasterizer idle worker保留最後SVG DOM；若有動畫，可能持續WebContentCPU。native認出的氣泡不經該路，不可先斷言是共同原因。

- 實際UI在21:08:13登入模式切換捕捉SwiftUI背景發布警告。LoginManager.markLoginInfoChanged由JS背景執行緒同步post通知，ExploreHomeView.onReceive未指定main queue，直接呼叫discover.reload；計畫在UI訂閱邊界切主執行緒並重走相同行為驗證。不是401根因（獨立HTTP請求同樣401），亦不能由此推論所有氣泡效能症狀。


2026-09-07 continuation: User login succeeded; live monthly rank #1 夜无疆 loaded819 chapters; >10min reading/review UI then requested stress. Far jump chapter10 reproduced cache immediate self-eviction loop;118.08s avg105.22% readerCPU vs47.24s idle0.72%. Perf agent fixing stable position/cache anchor, availability vs replacement, empty nextContent queue, text-size estimate. Four-way real UI matrix remains pending.


### 2026-09-08 最終四組連續跨章
使用者登入已成功，月票榜首《夜無疆》與完整江湖主題已使用。四組固定第10章第1頁、冷章cache及乾淨持久標題、各50次真實curl：全預設OFF/ON CPU9.47%/19.44%，江湖OFF/ON29.56%/40.05%；RSS峰661.578/761.141/802.094/890.594 MiB。200/200連續頁碼有效，跨章4/4/5/4次，最大preload done1/sec、完成後缺目的layout0。以前105.22%卡死根因已修，不把操作CPU與idle直接算降幅。全預設ON書評關閉後81秒Reader0.99%，評論PID已退出，其餘WebKit/GPU0。細項與口徑見Technotes/ReaderCommentPerformance-20260907.md。


### 2026-09-08 最終完成與界線
快照已沿用同一有界NSCache按layout revision/spine/localPage去重，144fixture請求render144→71、中位189.221→102.307ms；4+13+11+17共45項直接回歸通過。後續正式settled四組各50次全部有效，CPU9.86/19.49/27.78/40.40%，RSS峰662.5/763.5/790.2/888.3MiB，快照重畫176→0；未以fixture降幅冒充整App CPU降幅。追加未cache第20章遠跳15.267秒僅建一次保留目標；江湖ON第10章一次35.058秒含28.204秒jsNet，不隱藏。書評真資料約6.18/6.21秒；一段193秒idle6.469%未在同App同章前後sample重現（0.743→1.594%），保留限制且不猜根因。詳細原始證據與最終報告Technotes/ReaderCommentPerformance-20260907.md；采樣/logstream停止，來源登入與江湖/氣泡ON保留，無commit。
