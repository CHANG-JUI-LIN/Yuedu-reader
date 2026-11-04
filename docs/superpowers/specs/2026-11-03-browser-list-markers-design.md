# 新引擎的清單符號（list marker）

**狀態：** 設計稿，兩項決策已定（2026-11-03，見第 14 節）。第 13 節第 1 步（量 WebView）已完成，數字都寫回第 5、9、10 節。第 2 步（樣式與序號）、第 3 步（符號文字）、第 4 步（掛靠、幾何、繪製）、第 5 步（直排）、第 6 步（`inside` 回退）、第 7 步的引擎部分（VoiceOver 文字）、第 8 步（UA 清單邊距與邏輯縮排；8b 的 `p`、標題、`blockquote` 邏輯邊距；8c 的標題相對字級和 `pre`、`figure`、`hr`、`dl`、`dd` 邊距；8d 的 `hr` 邊框與寬度、等寬字型；8e 的未知標籤改成行內；8f 把 8d、8e 查到的項目全部修完）已在 YueduCoreText 實作，還沒提交。新引擎現在畫**橫排和直排的外側符號**；有 `inside` 符號的章節整章交給舊引擎。App 改用朗讀函式排在第 9 步，和升 0.13.0 一起做；第 8 步的基線語料也延到第 9 步一起量。

**日期：** 2026-11-03

**範圍：** YueduCoreText（預計 0.13.0）＋ App 的套件版本要求與讀取點檢查。

**目標：** 新引擎在橫排和直排畫出清單的項目符號與編號，位置、大小、字型和 iOS 27.2 的 WKWebView 一致（原訂 27.0，量測時這台機器的 27.0 runtime 已經刪了）。附帶效果是解開 GAPS S001b：S001 那份候選修正（`refs/archive/fidelity-S001-attempt3`）合不進去，就是因為走新引擎後清單編號會消失。

## 1. 現況

- 新引擎的 UA 樣式只給 `ul`／`ol` 40px 左內距（`ComputedStyle.swift` 的 `UserAgentStyle`；第 8 步已改成 WebKit 的邏輯邊距與縮排），`li` 就是普通區塊。**項目符號和編號一個都不畫**，`list-style-*` 宣告也沒有任何地方讀。GAPS 的 S001b 只記到有序清單，實際範圍連無序清單也包括在內。
- 能力掃描不認得清單，所以有清單的章節照樣走新引擎，符號是**默默不見**，不是回退。
- 舊引擎（`HTMLAttributedStringBuilder`）把 `"1.\t"` 或 `"•\t"` 當成文字插進 attributed string：只分 `ol`（數字）和其他（圓點），只數同一層的 `li`，不看 `start`、`reversed`、`value`，`list-style-type` 只認 `none`。符號算在舊引擎的文字裡，所以 VoiceOver 和聽書都會唸出來。

## 2. 和 DTCoreText 的關係

這份設計大部分**不是**照 DTCoreText 的做法：

- **借得到的只有「編號怎麼寫成文字」這個題目**（`DTTextList.formattedMarker`）。實作照 CSS Counter Styles 3 寫，不搬它的程式碼：它的羅馬數字沒有 1–3999 的範圍限制，也沒有中文編號。照規格寫，也就不用處理 BSD 授權聲明。
- **定位不能借。** DTCoreText 用 tab 停駐點把符號推到縮排前面，跟舊引擎現在的做法一樣，套不進盒模型。量法以 WebKit 為準，所以符號的位置照 WebKit 的規則（第 8、9 節）。

## 3. 語料證據

範圍：`~/Desktop/Test document/EPUB Format` 的 19 本書，數的是 XHTML 裡的標籤（不含 nav／toc 檔）和樣式表裡的 `list-style*` 宣告。

| 書 | ol／ul／li | 樣式表裡的 list-style | 屬性 |
|---|---|---|---|
| 紅樓夢（人民文學） | 298／0／8829 | 無（預設 decimal） | — |
| 三國演義注評 | 123／0／4440 | `none`、`outside` | `li value` ×3 |
| 哈利波特 | 247／0／288 | `decimal`（.list）、`lower-alpha`（註腳項目） | `ol style` ×1 |
| 全知讀者視角 | 11／0／87 | 無 | — |
| 詭秘之主 | 36／0／49 | `cjk-ideographic`，但被後面一條 `decimal` 蓋掉 | — |
| Project Hail Mary | 1／1／9 | `decimal` ×4、`disc` ×4 | `li value` ×5 |
| 草枕 | 0／7／21 | `none` | — |
| AI 術語詞典 | 1／1／12 | `list-style: none` | — |
| 洪武大帝 | 1／0／9 | `none`、`outside` | — |

另外 Mahabharata 和全職高手的樣式表有宣告、但正文沒有清單，其他 8 本完全沒有。

從這份資料得到的結論：

- **大宗是多看註腳清單**：`<ol class="duokan-footnote-content"><li class="duokan-footnote-item">`，放在章末，引擎會照常顯示（`BrowserLayoutDocument.collectFootnotes` 只改點擊行為）。紅樓夢、詭秘之主、哈利波特、全知讀者視角都是這種。
- **實際生效的類型**只有 `decimal`、`disc`、`lower-alpha`、`none`。中文編號的實際用量是 0：詭秘之主的 `cjk-ideographic` 被後面一條規則蓋掉了。
- **`li` 以區塊開頭很常見**（三國 4437 個 `<li><p>`、全知讀者視角 87 個、Hail Mary 9 個），所以「符號掛在哪一行」一定要做對。
- 有 `value` 屬性，沒有巢狀清單，沒有 `inside`，也沒有真的 `list-style-image`（福爾摩斯的 `list-style-images` 是拼錯的屬性）。
- 目前走新引擎、因而默默掉了符號的書：紅樓夢、哈利波特、詭秘之主、Hail Mary 全部章節，全知讀者視角的一部分章節。
- ai-glossary 在最新一次量測（`ib-after-base`）已經 81.5 分過關，16 章全部回退 `media-queries`。所以 S001 現在的意義是讓那 16 章改走新引擎，不是為了過 80 分。

## 4. 範圍

**這一版支援：** 橫排和直排（`vertical-rl`，第 10 節）；`list-style-position: outside`；`display: list-item`（`li` 預設）；第 5 節的類型；HTML 的 `start`、`reversed`、`value`、`type`。

**整章交給舊引擎（兜底，照 CLAUDE.md 揭露）：** 判斷在計算後的樣式樹上做，`text-indent` 已經有這種做法的先例（`BrowserLayoutCapabilityScanner.layoutAffectingDeclaration` 的註解）。只看計算後的值，不看宣告字面，所以 `ol { list-style-type: none }` 底下的 `li` 不會觸發。

| 觸發條件（計算後的樣式） | 擋的是什麼 | 什麼時候可以刪 |
|---|---|---|
| 有 list-item 是 `list-style-position: inside`，而且會畫出可見符號 | 內側符號要佔行內寬度、參與斷行，這一版沒做；語料用量 0 | 內側符號實作之後 |

回退原因叫 `UnsupportedFeature.listMarker`，量測報告裡的名字是 `list-marker`，看得出是哪一項擋下來的（第 6 步做了）。判斷寫在 `ListMarkerSupport.drawsInsideMarker`，掛在 `BrowserChapterAdmission.judge` 裡，和 `text-indent` 用同一棵計算後的樣式樹。下列情況**不會**觸發：
- `list-style-type: none`。
- `inside` 宣告後又被覆蓋成 `outside`。
- `inside` 只是繼承下來，但頁面上沒有任何 list item。
- 隱藏的清單（`display: none`、`hidden` 屬性）。

沒有定義的計數樣式名稱會畫成 decimal，算是可見符號，會觸發。

**這條回退會讓閱讀位置偏移。** 舊引擎把 `"1.\t"` 寫進文字，所以章節從新引擎改走舊引擎時，清單之後的閱讀進度和書籤會偏幾個字。日後刪掉回退、章節搬回新引擎時，也會反向偏一次。這不是新問題：換引擎的位置本來就不互通（`PictureOffsetMigration` 的說明寫明舊引擎存的位置不遷移）。註腳清單多半在章末，影響有限，但要寫進發佈說明。

**忽略，並在文件與發佈說明裡揭露：** `list-style-image` 不畫圖片，改畫 `list-style-type` 的符號。瀏覽器在圖片載入失敗時就是這樣畫，舊引擎也一樣不畫圖片；語料用量 0。

**不做：** `::marker` 規則、`content` 屬性、`counter-reset`／`counter-increment`、`::before` 計數器、由右至左、`list-style-image` 本身。`list-style-type` 的 `<string>` 值（`"→"`）和 `symbols()` 也不做：WebKit 認得它們，我們當成無效宣告丟掉，所以會改用前面的宣告或繼承來的值，不會照字串畫。語料用量 0。

## 5. 符號文字

照 CSS Counter Styles 3 的預定義樣式，用一張表描述，不寫成一堆 switch：每一筆記錄 system（cyclic／numeric／alphabetic／additive／中文）、符號、後綴、範圍、超出範圍時改用的樣式。新增一種類型只要加一筆資料。

| 類型 | 寫法 | 後綴 | 範圍（超出時改用） |
|---|---|---|---|
| `decimal` | 1 2 3 | `". "` | 不限 |
| `decimal-leading-zero` | 01 02 | `". "` | 不限 |
| `lower-alpha`／`lower-latin`、`upper-alpha`／`upper-latin` | a…z, aa | `". "` | ≥ 1（decimal） |
| `lower-roman`／`upper-roman` | i ii iii | `". "` | 1–3999（decimal） |
| `disc`／`circle`／`square` | 合成圖形，見下 | `" "` | — |
| `cjk-decimal` | 〇一二 | `"、"` | ≥ 0 |
| `trad-chinese-informal`、`cjk-ideographic`（規格定義兩者相同）、`simp-chinese-informal` | 一、十、十一、二十、一百零一 | `"、"` | −9999–9999（cjk-decimal） |
| `none` | 不畫 | — | — |

- 中文非正式寫法照規格 §7.1.3：0 寫成「零」；每個非零位數接位數記號（十、百、千）；10–19 去掉十位的「一」；去掉尾端的零，中間連續的零合成一個「零」。負號是「負」（繁體、`cjk-ideographic`）或「负」（簡體）。
- **iOS 27.2 實測過的寫法**（測試書 S001c 第 1、3 章）：`decimal-leading-zero`、`lower-alpha`、`upper-alpha`、`lower-roman`、`upper-roman`、`cjk-ideographic`、`trad-chinese-informal`、`simp-chinese-informal`、`cjk-decimal` 全部支援，後綴照上表。範圍：`lower-alpha` 的 0 畫成「0.」、27 畫成「aa.」；`upper-roman` 的 3998、3999 正常，4000 改畫「4000.」；`decimal` 的負數畫成「-2.」。
- **中文範圍是 ±9999，從 iOS 27.2 的 runtime 讀出來的。** WebKit main 在 2026-09-10（bug 257369）把中文、日文、韓文長寫法的範圍放寬到 ±9999999999999999，那是規格的選配章節 §7.1.2。但 27.2 兩個 build（探針模擬器用的 24B8117，和 Duo 的 24B91016s）的 dyld 共用快取裡，內建的 `counterStyles.css` 仍寫 `range: -9999 9999`，所以照 27.2 做：超出時改用 `cjk-decimal`，負數再超出就改用 `decimal`。`counterStyles.css` 是編進 WebCore 的 UA 樣式表，範圍和演算法是同一個提交改的，所以 range 沒變就代表演算法也是舊版。舊版演算法在 ±9999 以內的寫法和規格相同（讀過 `50320fd3` 上一版的程式）。
- **超出範圍時只有計數的部分改用備用樣式，後綴仍是原樣式的**：WebKit 的 `listMarkerTextContent` 把解析出的樣式的後綴接在 `text()` 後面，改用備用樣式是在 `text()` 裡面發生的。所以 `cjk-decimal` 的 −1 是「-1、」，`trad-chinese-informal` 的 10000 是「一〇〇〇〇、」、−10000 是「-10000、」，`upper-roman` 的 4000 是「4000.」。
- **`decimal-leading-zero` 補零時把負號算進長度**（WebKit 的 `applyPadSymbols`）：0 是「00.」，−1 是「-1.」，−5 是「-5.」，不是「-05.」。
- 這兩條，加上中文的負數和超出範圍，**2026-11-03 量過，全部吻合**（測試書 S001c 第 3 章 `11-chinese-range`、`11-simp-negative`、`11-cjk-decimal-negative`、`11-leading-zero-negative`，探針結果 `lists-8`）。用 Core Text 量的字元寬度預測墨跡寬，和截圖比：「一〇〇〇〇、」94.76／95、「-10000、」66.65／66.67、「-1、」26.71／26.67（若後綴跟著改成「.」會是 19.42）、「00.」22.76／22.67、「-1.」19.42／19.33（若補成「-01.」會是 29.4）、「-5.」22.78／22.67。「負一、」44、「负十二、」60.67 的寬度合理，但「負」「负」不在探針的字元表裡，沒有逐字預測。9999 那一項的符號超出視窗左緣被裁掉，只對得上右側間距 6.33。
- 實作在 YueduCoreText 的 `CounterStyle.swift`：`CounterStyle.predefined` 是那張表，`ListMarkerText(type:ordinal:)` 回傳 `.bullet`（圓點類，不排文字）或 `.counter(representation:suffix:)`（計數和後綴分開，第 7 步 VoiceOver 唸的時候才能只去掉後綴的空白）。表裡沒有的名字畫成 `decimal`。根本不存在的名字照規格本來就是 decimal；**WebKit 認得但我們沒做的樣式（例如 `hiragana`）畫成 decimal 是兜底**：WebKit 會畫假名，語料用量 0，補進表裡那個名字的兜底就消失。建符號時（`ListMarker.make`）用 `CounterStyle.predefined[name] == nil` 判斷，往診斷 sink 記一筆 `list-style-type` 的診斷，每個項目一筆。
- 其他預定義類型（hiragana、katakana、lower-greek 等）語料用量 0，留到有需求再加，加的時候只要補表。規格規定**不存在的計數樣式當成 decimal**；已知但還沒實作的類型也一樣畫成 decimal，並透過引擎既有的診斷 sink 記一筆，之後才查得到是哪本書用了哪種類型。
- 符號套用 WebKit UA 的 `::marker` 規則：`font-variant-numeric: tabular-nums`（Core Text 的等寬數字特性）、`white-space: pre`、`text-transform: none`、`text-indent: 0`、`unicode-bidi: isolate`。
  - **`tabular-nums` 未量：** PingFang 沒有數字寬度的特性，要求 `tnum` 時 Core Text 給的寬度和比例數字一模一樣（「1」6.72、「2」10.07），所以這套量測分辨不出 WebKit 有沒有套用。用比例寬度預測「1.」「7.」「10.」「11.」「12.」的墨跡左緣，和截圖差 0.22 以內，在像素格內。實作照 UA 規則要求 `tnum`，對 PingFang 不會改變結果；遇到真的有等寬數字的字型時再量。
- **字型和顏色取自 `li`，不是取自符號實際所在那一行的元素。** 例如 `<li><p>` 時取 `li` 的字型，而不是 `p` 的。WebKit 的 `computeMarkerStyle` 寫明「符號一律從 list item 繼承」。iOS 27.2 實測確認：`li` 25.5px、p 17px 時，編號和圓點都是 25.5px 的大小（測試書 08-li-large、08-ul-large、14-cjk-large、14-disc-large）。
- **圓點是合成圖形，不是「•」字。** WebKit 對 `disc`／`circle`／`square` 畫自己合成的圖形（`listMarkerSynthesizesGlyph`），大小從字型的 ascent 算。iOS 27.2 實測（第 12 節的探針，PingFang 9／12／17／25.5／34／50px 和 Times New Roman 17px，七種全部吻合到 1/3pt 的像素格內）：
  - **A** 是 WebKit 的字型 ascent：Core Text ascent **無條件進位到整數**（PingFang 17px：18.02 → 19；Times 17px：15.149 → 16）。descent 同樣進位（**D**，PingFang 17px：5.78 → 6）。圓點的大小和位置用這兩個值；第 9 節的行高**不用**，理由見該節。
  - 圖形是邊長 `s = (A × 2/3 + 1) / 2` 的正方形，**不取整**（17px：6.83；50px：18.17）。`disc` 是內切的實心圓，`square` 是實心正方形，`circle` 是同一個圓的 1pt 描邊（線畫在邊上，外緣 `s + 1`）。
  - 行內方向：符號盒起點在 list item border box 起點往外 `floor(A × 2/3) + 8`，寬 `s + 2`，圖形在盒內往裡 1pt。所以圖形左緣在 border box 起點往外 `floor(A × 2/3) + 7`（17px：19）。
  - 區塊方向：圖形頂端在基線往上 `A / 2`（17px：9.5）。
  - 和 WebKit main 分支的寫法（寬 `(ascent × 2/3 + 1) / 2 + 2`、起點邊距 `−(ascent × 2/3) − 7 − 1`）一致，差別只在起點邊距的 `A × 2/3` 要取整數（floor），而 A 本身已經是進位後的整數。

## 6. 樣式模型

- **`list-item` 做成區塊上的旗標**（`ComputedStyle.isListItem`），不在 `CSSDisplay` 加新的 case，免得每個 `switch display` 都要重新檢查。`display: list-item` 會設這個旗標；`li { display: block }` 會清掉它，符號就消失，跟瀏覽器一樣。`li` 的 UA 預設設這個旗標。
  - 認得的 `display` 值都會清掉旗標；認不得的值（`flow-root`、`inline list-item` 等）整條丟掉，旗標和 display 都不變。
  - **這一步就改了版面：** 以前 `display: list-item` 沒人解析，元素維持 UA 的 display。現在任何元素寫 `display: list-item` 都會變成區塊（例如 `span`），跟瀏覽器一樣。語料（第 3 節的 19 本）只有 Project Hail Mary 寫了 `display: list-item`：6 條 `.list-decimal*`／`.list-disc*` 規則，套在 9 個 `li` 上，而 `li` 本來就是區塊，所以實際改到版面的元素是 0。
- **`list-style-type`、`list-style-position` 是繼承屬性**，UA 預設只設在清單容器上：`ul`／`menu`／`dir` 是 `disc`，`ol` 是 `decimal`。巢狀照 WebKit main 的 `html.css`：祖先裡有幾個 `dir`／`menu`／`ol`／`ul`，有一個時 `dir`／`menu`／`ul` 是 `circle`，兩個以上是 `square`；`ol` 不變。三國的 `ol { list-style-type: none }` 就是靠繼承傳到 `li`，裡面再包一層 `ul` 時，`ul` 自己的 UA 值會蓋回 `circle`。
  - UA 的類型另外寫成 `UserAgentStyle.listStyleType(for:listAncestors:)`，不放進 `basis(for:)`：`applyingUA` 對繼承屬性是「UA 值不等於初始值才蓋」，而最外層 `ul` 的 `disc` 剛好等於初始值，照那條規則會蓋不掉繼承來的 `none`。
  - 計數樣式名照 CSS Counter Styles 3 存成字串（`CSSListStyleType.counterStyle(name)`，轉小寫）：任何合法的識別字都是有效宣告，沒有對應樣式的名字之後畫成 `decimal`，所以這裡不能丟掉。
- **`list-style` 簡寫**：先把三個子屬性重設回初始值（`disc`、`outside`、`none`），再套用寫到的 token。所以 `list-style: inside` 會把類型重設成 `disc`；`none` 給類型和圖片之中還沒被設定的那一個，只有一個 `none` 時兩者都是 `none`。同一個子屬性出現兩次、或有認不得的 token，整條宣告無效。圖片（`url()`、`image-set()`、漸層）只解析到讓宣告有效，不畫。
- **HTML 屬性**（`HTMLPresentationalHintExtractor`：屬性名會轉小寫，值不會，這正是需要的）：
  - `ol type`、`li type` 區分大小寫：`1`→decimal、`a`→lower-alpha、`A`→upper-alpha、`i`→lower-roman、`I`→upper-roman。
  - `ul type`、`li type` 的 `disc`／`circle`／`square`／`none` 不分大小寫，WebKit 仍支援這種舊寫法。`none` 是 HTML 標準 §15.3.8 的呈現規則，原稿沒列。
  - 值不修剪空白（屬性選擇器比對整個值），`type=" a"` 沒有效果。
  - 作者的 CSS 蓋過屬性提示，跟其他屬性提示同一套優先序。
  - **公開 API 有變：** `HTMLPresentationalHintProperty` 加 `.listStyleType`、`HTMLPresentationalHintValue` 加 `.listStyleType(HTMLListStyleType)`，新增公開的 `HTMLListStyleType`。App 的舊引擎（`HTMLAttributedStringBuilder.applyPresentationalHints`）對 `hint.property` 做完整的 switch，升級到 0.13.0 時要補一個什麼都不做的 case（第 13 節第 9 步），0.13.0 的 CHANGELOG 要寫。
- 宣告都在 `ComputedStyleTreeBuilder.apply(key:value:)` 這一個地方處理，不另開解析路徑。
- **已知限制（引擎原有）：** 同一個宣告區塊裡同一個屬性寫兩次，CSS 解析器只留最後一條（`text-indent` 是唯一在解析時先驗證的例外）。所以 `li { list-style-type: square; list-style-type: "→" }` 會被當成整條無效、改用繼承來的值，瀏覽器則留 `square`。不同規則之間的覆蓋正常。

## 7. 序號

照 HTML 規範的 ordinal value 演算法算，**在計算後的樣式樹上算**，因為只有 display 是 list-item 的元素才算項目：

1. 一個項目的清單擁有者，是它最近的 `ol`／`ul`／`menu` 祖先；沒有這種祖先時，就是它的父元素（例如單獨一個 `display: list-item` 的 div，序號從 1 起算）。
2. 擁有者擁有的項目，是所有以它為擁有者、而且是 list-item 的後代，照文件順序排列；不只直接子節點。`display: none` 的子樹不計，`display: block` 的 `li` 也不計。
3. 起始值：`ol start` 有就用它；`reversed` 而且沒有 `start` 時，起始值是擁有的項目數；其他情況是 1。
4. 逐項：`li value` 能解析成整數就把目前的值設成它；這一項用目前的值；然後 `reversed` 減 1，否則加 1。

整數照 HTML 的「整數解析規則」：略過開頭的 ASCII 空白，可以有正負號，至少一個 ASCII 數字，數字後面的東西忽略（`"5abc"` 是 5）；沒有數字，或超出 32 位元整數範圍（WebKit 用 32 位元 int），就當成沒寫這個屬性。全形數字和全形空白不算。

和舊引擎不同的地方（換引擎時編號會變的情況）：`start`、`reversed`、`value` 現在都會生效；隱藏或改成 block 的 `li` 不再佔號；包在 `div` 裡的 `li` 仍然算同一個清單的項目。

序號放在 style node 上（`ComputedStyleNode.listItemOrdinal`，不繼承），由一個獨立的 pass（`ListItemOrdinals.assign`）在 `buildTree` 結尾算好，所以每條建樣式樹的路徑都有。盒子樹建構只讀它，不自己數。

**複製節點要帶著序號。** 樣式樹建好之後，到盒子樹之前還有幾個階段會重建節點：影片換成佔位圖時重建它的祖先（`BrowserLayoutSemanticContent.prepareMedia`），直排時 `LogicalFlow.styleTree` 重建**每一個**節點，表格儲存格去掉 margin 時也會複製。序號是建完樹才算的，所以改成初始化參數（預設 nil），這三個地方都傳下去；以後新增的複製點也一樣要傳，否則直排會整份沒有序號。`ListStyleTests.ordinalsSurviveTheStagesBeforeBoxConstruction` 照 `makeLayout` 的順序走過這些階段，橫排直排各驗一次。

**和實測對照：** iOS 27.2 的探針沒有直接讀出編號，但每個符號的墨跡寬度和位數對得上（測試書 S001c）：06-start 是 5、6；06-reversed 是 3、2、1；06-reversed-start 是 10、9；06-value 是 1、7、8、−2、−1、0；13-li-block 的第三項是 2（block 的 `li` 不佔號）；13-li-in-div 的三項是 1、2、3（包在 div 裡的照算）。**沒量：** `reversed` 而且沒有 `start` 時，起始值數的是「擁有的項目」還是「直接子節點的 `li`」。量過的倒數清單只有三個直接子節點的 `li`，兩種算法結果相同；清單裡有 block 的 `li` 或包在 div 裡的 `li` 時才會分出來。

## 8. 符號掛在哪一行

照 WebKit main 分支的 `RenderListItem::firstFormattedLineRootFor` 和 `markerSearchBoxType` 的規則寫。**不沿用 `ownsFirstFormattedLine`**：那是單一容器內 `text-indent` 的歸屬，不會往下跨進子區塊。

從 list item 開始，依序看每個子節點：

- **跳過、繼續找下一個**：float、絕對定位、巢狀清單自己的符號、書寫方向不同的區塊。
- **行內內容**：只有可摺疊空白的文字，或空的行內元素，也跳過，但記住這個容器當備案。其他行內內容就讓這個容器的第一行成為答案。外側符號遇到行內元素裡包著區塊時，會跟進那個區塊找。
- **一般區塊容器**：遞迴往裡面找；找到就是答案，找不到就繼續下一個子節點。
- **停止**：表格、ruby 區塊、置換元素（區塊圖片）。到這裡就沒有答案，只剩前面記住的備案。

iOS 27.2 實測對得上的部分（測試書 S001c）：`<li><p>` 掛在 p 的第一行；以巢狀清單開頭的 `li` 掛在內層第一項的第一行；`li` 的第一個子節點是浮動時跳過它、掛在後面文字的第一行；只有區塊圖片時沒有行（幾何見第 9 節）。表格、ruby、行內元素包區塊、絕對定位、書寫方向不同的區塊**沒量**，照 main 分支的程式寫。

實作（第 4 步，`ListMarker.swift`）：`BoxTreeBuilder.buildBlockInternal` 建完 list item 的整棵子樹之後才找掛靠的盒子（`ListMarker.anchor`），不往下傳狀態，因為那時每個子盒子都已經定型。找到的盒子把符號加進 `BlockBox.listMarkers`（陣列：以巢狀清單開頭時，內外兩個符號掛在同一個盒子上。建盒子時內層項目先完成、先掛，所以新的符號插到陣列最前面，陣列保持文件順序、外層在前；第 7 步 VoiceOver 照這個順序唸）；`InlineLayout` 把它們放進那個盒子第一行的 `LayoutLine.listMarkers`。沒有任何一行接手時，符號留在 list item 自己的 `unanchoredListMarker`。

目前的搜尋只做了量過的部分：跳過浮動；遇到區塊圖片或表格就停；否則遞迴，第一個自己有行內內容的盒子就是答案。**沒做：** 只有空白或空行內元素時的「備案」、絕對定位、ruby 區塊、書寫方向不同的區塊。這幾種都沒量，語料也還沒遇到，遇到時照上面 main 分支的規則補。

## 9. 幾何

以下全部是 iOS 27.2 WKWebView 的實測值（第 12 節的探針，測試書 S001c；截圖是 3 倍，像素格 1/3pt）。這一節用橫排描述，直排見第 10 節。A、D 是第 5 節定義的進位後 ascent／descent。

**行內方向（文字符號）**

- 符號字串是「計數＋後綴」（例如 `"1. "`、`"一、"`），用 `li` 的字型和文件語言排成一條 `CTLine`：`zh-Hant` 的「、」是置中的字形，要帶 `kCTLanguageAttributeName` 才排得出來。
- **符號盒的尾端貼齊 list item 的 border box 起點**，所以墨跡和 border box 之間隔著後綴的空白。實測 PingFang 17px 的 `decimal` 墨跡間距是 7.00，Core Text 用同一串字預測的尾端只差 0.16；`cjk-*` 是 6.33，預測差 0.06。
- 下面這些都**不會**移動符號，墨跡間距全部維持 7.00：
  - 首行 `text-indent`（`<li><p>` 的 p 縮兩字，內文往裡 34pt）。WebKit main 的程式看起來會被推動，實測不會。
  - 中間層的 margin（p 的 margin-left 2em）。
  - `li` 自己的 padding（17pt）或 border（3pt）。
  - `text-align: center`（首行往裡 104pt）。
  - 巢狀清單：內層項目的符號貼齊內層 `li` 的 border box。
- **浮動要分兩種：**
  - 行開始排之前就在的浮動（前一個元素或前一個 `li` 留下的）把行首往裡推時，**符號跟著行首走**：間距仍是 7.00，量的是到被推過的行首。
  - `li` 自己的第一個子節點是浮動時，符號**留在 border box 起點**，不跟著被推開的第一行。
- `li` 以巢狀清單開頭時，外層的符號掛在內層第一項的第一行上，但行內位置照外層 `li` 的 border box 起點算，所以兩個符號左右錯開。

**行內方向（合成圓點）：** 第 5 節的公式，以 border box 起點為準，不受上面列的那些因素影響。

**區塊方向**

- 文字符號的基線等於它掛靠那一行的基線（±0.42 以內）。圓點的頂端在同一條基線往上 `A / 2`。
- **符號會撐高那一行。** 它像一個用 `li` 字型、`li` 行高的行內盒：在基線上方佔 `A + 半行距`，下方佔 `D + 半行距`，半行距是 `(li 的 line-height − (A + D)) / 2`（可以是負的）。行高是這個範圍和原本各盒的聯集。
  - `<li><p>` 時 li 是 25.5px、p 是 17px（測試書 08-li-large、08-ul-large）：第一行高 +12.75，內文往下 9.38。公式預測 12.75 和 9.375。
  - 符號字型和那一行相同時不會撐高：`line-height: 1`（08-li-lh1）和多看註腳（`line-height: 100%`）都是 0。
  - 所以 `InlineLayout` 排掛靠的那一行時，要把符號的範圍算進行高，符號本身不佔行內寬度。viewport 還沒排版時的高度估算也要算進去，否則捲動時版面會跳。
  - **實作用不進位的 Core Text ascent／descent**（`InlineLayout.halfLeadingBox`，和行的 strut、正文共用同一份）。WebKit 每個行內盒都用進位後的 A、D，我們的正文和 strut 不進位；只有符號進位的話，同字型的行會被撐高約 0.38（PingFang 17px、行高 17），而 WebKit 是 0。撐高的量和字型度量無關（兩個盒子的半行距差抵掉了 ascent＋descent），所以 08-li-large 仍是 +12.75；內文往下的量變成 9.43，和實測 9.38 差 0.06，在 1/3pt 的像素格內。整套引擎的行內盒都不進位，要改得一起改，不在這件事的範圍。
- **沒有行：**
  - 空的 `li` 有一行高（li 的 line-height，25.5），符號放在這一行上，基線在內容頂端往下 `A + 半行距`。同一項改成 `list-style-type: none` 時高 0。
  - 只有區塊圖片的 `li`：符號放在「內容頂端開一行」的位置（基線同上，在頂端往下 `A + 半行距`），**不增加高度**。
  - 行內圖片開頭的 `li` 有行，符號照常掛在第一行的基線上。
  - 實作：`BlockLayout` 只在 `li` 沒有行內內容、除了浮動也沒有子盒子時，把內容高度撐到符號的行高；`PageWalker` 在 list item 的內容頂端發出這個符號。**這種沒有行的符號不看浮動**（掛在行上的才有第 9 節行內方向的浮動規則），沒量過浮動旁邊的空 `li`。

## 10. 直排（vertical-rl）

使用者決定這一輪一起做（第 14 節）。以下是 iOS 27.2 實測（測試書 S001d）。

- **座標：** `LogicalFlow` 在建盒子樹前，把實體邊距一次轉成（行內、區塊）座標，一路保持到發出繪製項目為止。第 8 節和第 9 節**行內方向**的規則都在這套座標裡算，橫排直排同一份程式，只在發出時換軸。直排時行內方向是由上往下，所以「list item 的 border box 起點」是**上緣**，符號在欄的上方；欄由右往左排。
- **行內方向：實測和橫排相同。** 符號尾端貼齊 `li` border box 上緣，墨跡間距 `decimal` 6.67（橫排 7.00，差一個像素格）、`cjk-*` 6.33、圓點 12.00；圓點的起點公式和第 5 節相同（25.5px 時 15.00，也吻合）。
- **字向：** 實測符合預期。拉丁數字、羅馬數字和 `". "` 順時針橫躺，「10.」整串橫躺、不套縱中橫；「一」「十」等漢字直立；「、」用直排標點字形（在字格右上）。符號字串的排版走正文同一套直排處理，不另做：`CJKTypography.apply(vertical: true)` 加上 `InlineLayout.applyVerticalOrientation`（第 5 步從 `InlineLayout` 抽出來，正文和符號共用這一份）。
  - 橫躺字的置中有一個已知差：`CJKTypography.centreSideways` 用不進位的 `(A − D) / 2`（PingFang 17px 是 6.12），WebKit 用進位後的 6.5，所以橫躺的數字比 WebKit 偏約 0.38。正文的橫躺字也是同一個差，不為符號另做。
- **區塊方向（欄寬方向）：和橫排不同，這一條要依書寫方向分開寫。** 定義兩組進位後的字型度量：符號自己的（`li` 的字型）A<sub>m</sub>、D<sub>m</sub>，和掛靠那一行的根行內盒（那一行所屬區塊的字型，`<li><p>` 時是 p）的 A<sub>l</sub>、D<sub>l</sub>。
  - **佔位：** 符號在行裡佔一個以中央線置中、寬 `A_l + D_l` 的範圍，**不加行距**。這一行的寬度取它和原本各盒的聯集。橫排則是用符號自己的字型加 `li` 的半行距（第 9 節），兩者不同。
  - **畫的位置：** 符號用自己的字型排，自己的內容區（寬 `A_m + D_m`）的右緣（行上側）對齊上面那個範圍的右緣。換句話說，符號自己的中央線在行的中央線往左 `(A_m + D_m − A_l − D_l) / 2`。字型相同時兩條線重合。
  - 橫躺的字以自己的中央線放：字母基線在自己的中央線往左 `(A_m − D_m) / 2`。直立的字以自己的中央線置中。
  - 合成圓點：圖形的右緣在符號內容區右緣往左 `A_m / 2`，和橫排「頂端在基線上方 A/2」是同一條規則換軸。
- **實測對照**（PingFang；17px 時 A＋D＝25，25.5px 時＝37，15.3px 時＝23）：

  | 情況 | li／行的字型、行高 | 欄寬（原樣／無符號） | 符號位置 |
  |---|---|---|---|
  | `li` 直接放文字（14-decimal 等） | 17／17，25.5 | 25.5／25.5 | 和中央線差 0.3 以內 |
  | `li` 的 `line-height: 1`（14-li-lh1） | 17／17，17 | **25**／17 | 同上 |
  | `<li><p>`，p 的 `line-height: 1`（14-li-p-lh1） | 17／17，17 | **25**／17 | 同上 |
  | `li` 字級大，文字直接在 li，`line-height: 1`（14-li-large-lh1） | 25.5／25.5，25.5 | **37**／25.5 | 同上 |
  | 多看註腳（14-footnote-cjk／decimal） | 15.3／15.3，15.3 和 18.36 | **23**／15.3、18.36 | 同上 |
  | `li` 字級大，`<li><p>`（14-li-large） | 25.5／17，25.5 | 25.5／25.5（**不撐寬**） | 往左 6.0（公式 (37 − 25) / 2） |
  | 同上，p 的行比符號寬（14-li-large-tall） | 25.5／17，42.5 | 42.5／42.5 | 往左 6.0 |
  | 同上，中文編號（14-cjk-large） | 25.5／17，25.5 | 25.5／25.5 | 直立字中心和預測差 0.08 |
  | 同上，圓點和方塊（14-disc-large） | 25.5／17，25.5 | 25.5／25.5 | 圖形右緣和預測差 0.08、0.25 |

  如果套用橫排的規則，14-li-lh1、14-li-p-lh1 和註腳都不會撐寬，14-li-large 反而會撐寬，所以直排不能共用橫排的行高規則。
- **第 5 步補量（2026-11-03，`lists-9`，S001d 第 3 章）：**
  - **「那一行的字型」是根行內盒**（行所屬區塊的字型），不是行首第一個行內盒，也不是最大的那個。`li` 的 `line-height: 1`、17px：
    - 行首是 2em 的 `<span>`（14-span-first-large）：欄寬 34（無符號也是 34）。第一個盒或最大盒的規則會是 49。
    - 2em 的 `<span>` 在行中間（14-span-later-large）：欄寬 34。
    - 行首是 0.6em 的 `<span>`（14-span-first-small）：欄寬 **25**（無符號 17）。第一個盒的規則會是 17。
    - 三組的符號都在欄的中央線上（差 0.33 以內）。
  - **空的 `li`**：一欄寬「`li` 的行高」和「符號內容區 A＋D」取大的那個，符號在欄的中央線上。也就是 `li` 自己那一行（strut）加上符號佔的範圍。
    - 14-empty（行高 25.5）：25.5。
    - 14-empty-lh1（行高 17）：**25**，不是 17。
    - 14-empty-ul：25.5，圓點右緣和預測差 0.08。
    - `list-style-type: none` 時寬 0，和橫排相同。
  - 只有區塊圖片的 `li` 在直排到不了：`VerticalTextSupport` 擋圖片（見「准入」）。
- **實作**（第 5 步）：
  - 佔位：`InlineLayout.lineMetrics` 的直排分支，用 `markerLineExtent`（根行內盒字型的進位 A＋D）在中央線兩側各撐一半。橫排分支不變。
  - 畫的位置：`PlacedListMarker.blockShift` 等於 `(A_m + D_m − A_l − D_l) / 2`，walker 把它加到基線上，傳給 `ListMarker.paint` 的就是符號自己的中央線。圓點的 `contentStart` 依方向分開算，橫排是 `baseline − A`，直排是 `baseline − (A + D) / 2`，兩者再往內 `A / 2`。
  - 空項目：`ListMarker.ownLine`。橫排是符號的行內盒；直排是 `max(li 行高, A + D)`，置中。`BlockLayout` 的高度和 walker 發出符號的位置都讀它。
  - 測試裡中文編號要帶 `lang="zh-Hant"`：S001d 是 zh-Hant，「、」在字格置中，墨跡離符號尾端 6.33。沒帶語言時「、」排在字格前段，間距變成 10.33。
- **UA 縮排（第 8 步已修，寫成 `padding-inline-start`）：** 實測 WebKit 把 40px 放在上方：直排清單的 `li` 上緣在 48（body 的 8 加 40），`list-style: none` 的 `ul` 也一樣。我們的 UA 寫死實體的 `paddingLeft = 40`，直排時 `LogicalFlow` 會把實體左邊轉到區塊結尾那一側，所以直排清單現在是左邊多 40px。修法是 UA 改寫邏輯邊（`padding-inline-start`），交給 `LogicalFlow` 轉換。這會改到現有的直排清單版面（草枕有 7 個 `ul`，都是 `list-style: none`，縮排會從左邊移到上方），所以放在第 13 節的 UA 步驟裡分開量。
- **准入：** `VerticalTextSupport.accepts` 不擋 `li`，直排清單照常放行（第 5 步測試鎖住）。它擋圖片、浮動、表格和行內區塊，所以直排不會出現「只有區塊圖片的 `li`」和浮動推符號的情況，第 9 節那兩條只在橫排用得到。
- **書寫方向的來源：** 書的主要書寫方向（`principalWritingMode`）由 App 讀出後寫進 `BrowserLayoutConfig.writingMode`，排版時行用的 `textWritingMode` 就是它。符號也讀 `config.writingMode`，和行一致。
- **viewport：** `makeViewportSession` 不接受直排，所以 viewport 還沒排版時的高度估算只有橫排，直排不用改。

## 11. 原文位置、繪製與各條讀取路徑

**符號不佔原文字元。** `sourceText` 完全不變，所以不需要像 0.11 那樣做位置遷移，書籤、閱讀進度、高亮都不受影響。這也合乎 CSS：`::marker` 是產生的內容，不是 DOM 文字。

**繪製項目：**

- **文字符號**：用現成的 `.text` 項目。`sourceRange` 是長度 0，位置在掛靠那一行的起點；`sourceMapping: .wholeRange`；`renderedTextOverride` 是符號字串；用一條符號自己的 `CTLine`。這條 `CTLine` 在排版時建一次、存在盒子上，viewport 的繪製快取才不會每次快照都重建。`.wholeRange` 的定義（「沒有自己的原文，對應整個擁有者範圍」）剛好合用，**不用新增公開的 case**。
- **合成圓點**：用現成的 `.fill` 項目（圓角＝半徑；`circle` 用邊框）。`PageWalker` 用行首的 `StepInlineLineStart` 發出它（和行內背景同一條路），所以它帶那一行的 `lineSerial`、跟著那一行換頁和底部對齊（已測，開關底部對齊各一次）；不走 `placeFill`，那條路的區塊裝飾會把圖形拉長或在每頁重畫。
- **浮動造成的位移**（第 9 節「行開始排之前就在的浮動」）：`BlockLayout` 進入 list item 時記下當時已經放好的浮動（`BlockBox.floatsBeforeListItem`），排第一行時用這份快照算左側侵入量（`PlacedListMarker.floatShift`）。項目自己內容裡的浮動不在快照裡，所以不移動符號。
- **主題換色**：分頁模式換主題**不重排**。`BrowserLayoutPageEngine.applyThemeChange` 清掉繪製清單快取，重建時 `DisplayListBuilder.build(themeTextColor:oldThemeColor:)` 只把顏色等於舊主題文字色的 `.text` 項目換成新色。文字符號走這條路自動換色；用 `.fill` 畫的圓點不會，切到深色模式會停在舊顏色。所以圓點的 `.fill` 要帶一個「跟著文字色」的標記（`DisplayFillItem` 加欄位），換色條件和文字相同：顏色等於舊主題文字色才換。

**每條讀取路徑都要確認**，括號內是預期的行為：

| 路徑 | 預期 |
|---|---|
| 分頁：`PageWalker` → `PageFragmentation` | 發出符號的步驟，帶掛靠那一行的 `lineSerial`，那一行換頁時符號跟著走（第 4 步做了，`ListMarkerLayoutTests` 鎖住） |
| 捲動：`BrowserScrollDocument.make`（同一個 `PageWalker`） | 同上，不另寫（已測：和分頁的符號位置相同，圖塊視窗保留換色標記） |
| viewport：`BrowserViewportSession.snapshot`（經 `BrowserContinuousLayout.makeDocument`） | 同上；符號掛在 `LayoutLine` 上，視窗只排一部分行時跟著行走；`CTLine` 建一次存在 `ListMarker` 上，快取能命中，也加進 `retainedDrawingLineIDs`（已測：捲走再捲回位置不變，整章和一次排完相同） |
| viewport 還沒排版時的高度估算 | 已改（橫排）：估算加上符號比項目行高多出的部分（已測：200 項 08-li-large 結構，估算和實排多出的高度相同）。viewport 不接受直排（`makeViewportSessionImpl`），直排不用改 |
| 背景繪製：`BrowserPaintFragment.paintFragments`（文字依基線分組） | 文字符號和那一行同基線，分在同一組；圓點是 `.fill`，自己一個繪製片段（讀程式確認，沒另寫測試） |
| 只換色的主題切換：`BrowserLayoutPageEngine.applyThemeChange` → `DisplayListBuilder.build` | 文字符號自動換色；圓點靠 `followsTextColor` 一起換（實心改填色、`circle` 改邊框色），作者指定的顏色不動（已測）。捲動模式換主題會 `discardScrollPreparation()` 重排，符號在排版時就拿到新顏色，不走這條換色路徑 |
| 朗讀語意：`BrowserLayoutSemanticContent` | 第 14 節第 1 題：引擎在這個檔案提供公開的 `DisplayList.spokenText(pageText:pageRange:paragraphRanges:)`（第 7 步） |
| VoiceOver 的頁面文字：分頁和捲動都是 `BrowserLayoutPageView.accessibilityPageText`（捲動的 `BrowserScrollTileCell.interactiveView` 也是 `BrowserLayoutPageView`；`ReaderViewportFragmentHost` 設了 `accessibilityElementsHidden`，不是第三條路） | 第 9 步改用引擎的函式：有序清單的編號插在項目開頭，段落之間換行；原文位置不變 |
| 聽書：讀 `sourceText` | 不變，不唸編號 |
| 引擎選取、命中測試：`BrowserTextGeometry`、`BrowserPageGeometry`、`LinkInteraction` | 長度 0 或非 `.linear` 都已經會跳過；符號的 `linkTarget` 一律是 nil，項目以連結開頭也一樣（已測） |
| App：`BrowserLayoutPageView` 409／423／515、`ReaderViewportFragmentHost` 285、`ReaderScrollItem` 332 | 逐一確認不會把符號當成可點、可選的文字；423 的點擊命中要跳過長度 0 的項目 |

## 12. 驗證

**第一步是量 WebKit**，在寫任何引擎程式之前。現行量法（ORACLE.md）只在畫面分反映符號，差幾 pt 抓不到，所以另加了一個**符號位置探針**（2026-11-03 已做，第 9、10 節的數字都從這裡來）：

- **程式：** `Tests/iOS/yuedu appTests/ListMarkerProbeTests.swift`，由 `scripts/fidelity/list_probe.sh` 帶環境變數 `YUEDU_LIST_PROBE` 啟動，平常跑測試時直接跳過。用 oracle 同一套 WKWebView 設定和參考 CSS（橫排視窗 366×800、直排 390×776），`-testLanguage zh-Hant`。結果寫到 `~/Library/Caches/YueduFidelity/list-probe/<run>/`：每章一個 JSON，加上每個符號的裁切圖。不進評分，`SCORER_VERSION` 和 `oracle.lock` 都不動。
- **位置和大小：** 先注入 `::marker { color: transparent !important }` 讓所有符號透明，再一次只讓一項的符號顯示，原生 3 倍截兩張圖相減，得到這一個符號的墨跡框、重心和面積（pt²）。一次只看一項，相鄰項目的符號才不會連成一塊；透明不改版面，探針也會檢查前後版面是否一致。
- **基準點：** list item 的 border box 用 `getBoundingClientRect`；首行用 `Range.getClientRects()`。基線 JS 量不到，在第一個非空白字元前插一個 0×0 的 inline-block，取它的中心：橫排就是基線，直排就是中央線。插入後如果行的排法變了（兩端對齊微調），探針會標出來並確認移除後還原。
- **會不會撐高行、空 `li` 有沒有一行高：** 再注入 `list-style-type: none` 跑一次，比較 border box 和首行的位置差。
- **預測值：** 同一個測試裡用 Core Text 量每個符號字元的前進寬和墨跡（比例數字、`tnum` 等寬數字、直排字形各一份），帶文件語言，和截圖量到的位置對照。
- **閱讀器端：** 直接讀繪製項目的 rect，不必截圖相減。

**測試書**（照 ORACLE.md「測試書語料」的格式）：橫排是 `scripts/fidelity/fixtures/gaps/S001c-list-markers/`（8 章），直排是 `S001d-vertical-list-markers/`（3 章；第 3 章是第 5 步補的空 `li` 和行首 `<span>` 字級）。每個清單的 `data-case` 開頭就是下面的編號：

1. `li` 直接放文字（ol 和 ul 各一）
2. `<li><p>`，p 有 `text-indent`
3. `<li><p>`，p 有 margin-left
4. `li` 有 padding 或 border
5. `li` 是 `text-align: center`
6. `start`、`reversed`、`value`（含負數和 0）、`type="A"`／`type="i"`、字母和羅馬數字的範圍邊界
7. 空的 `li`（ol 和 ul）、只有區塊圖片的 `li`、行內圖片開頭的 `li`
8. `li` 字級比裡面的 p 大（ol 和 ul）、`li` 的 `line-height: 1`
9. 多看註腳清單（照紅樓夢和詭秘之主的結構）
10. 巢狀 ul（circle、square）、ul 裡的 ol、ol 裡的 ul、以巢狀清單開頭的 `li`
11. 所有支援的計數樣式、`li` 自己的 `list-style-type`，以及圓點在 9／12／25.5／34／50px 和 Times New Roman 的大小
12. 浮動推進行首：浮動在清單之前、浮動是 `li` 的第一個子節點
13. `li { display: block }`、包在 `div` 裡的 `li`、`display: list-item` 的 div、不在清單裡的 `li`
14. 直排一組：`decimal`（數字橫躺）、`cjk-ideographic`（直立加直排「、」）、`disc`、兩位數編號、`lower-roman`、`<li><p>`、直排的多看註腳清單、草枕那種 `list-style: none` 的 `ul`；另外為了分辨第 10 節的行寬規則加了 `li` 和 p 各自 `line-height: 1`、`li` 字級大（文字直接在 li、在 p 裡、p 的行比符號寬）、字級大的中文編號和圓點

**單元測試（Swift Testing）：** 計數樣式的表（每種類型的邊界值：0、1、9、10、11、19、20、101、3999、4000、負數）、序號演算法、簡寫重設、屬性大小寫、掛靠規則（每一種子節點類型）、長度 0 的項目在選取和命中測試都被跳過、能力掃描的回退條件、VoiceOver 文字（有序編號插在項目開頭、圓點不插、原文位置不變）、直排的符號座標換軸，以及 `CoreTextWritingModeTests`（動到直排就要跑）。

**驗收：**

- 每本測試書：探針量到的符號位置和 WebView 相差 0.5pt 以內，大小相差 0.5pt 以內，畫面分扣分歸零或接近零。
- 基線語料：沒有清單的新引擎章節分數變動在 0.3 以內（跟 S012 的標準相同）；有清單的章節不能下降。
- 合入 S001 候選後再量一次，ai-glossary 16 章走新引擎，ai-glossary:15 的 1–6 編號畫出來。

## 13. 實作步驟

每一步都跑相關的測試類別，加上該步驟對應的測試書。

1. **探針與測試書**（2026-11-03 完成）：量 iOS 27.2 WebView（橫排和直排），第 5、9、10 節的「待量」都改成實測值。探針和測試書見第 12 節。
2. **樣式與序號**（2026-11-03 實作，未提交）：`isListItem`、兩個繼承屬性、簡寫、HTML 屬性、序號 pass。這一步還不畫符號，只加單元測試：YueduCoreText 的 `ListStyleTests`，S001c 量過的情況直接當輸入。
3. **符號文字**（2026-11-03 實作，未提交）：計數樣式表與格式化，純函式加單元測試（YueduCoreText 的 `CounterStyleTests`）。第 5 節沒量的四組已加進 S001c 第 3 章，第 4 步一起量。
4. **掛靠、幾何、繪製**（2026-11-03 實作，未提交）：`BoxTreeBuilder` 交付符號、`InlineLayout` 的行高（實測會撐高，橫排規則見第 9 節）、`PageWalker` 發出步驟、圓點的換色標記。一次涵蓋分頁、捲動、viewport 三條路徑和只換色的主題切換。新檔 `ListMarker.swift`；測試是 YueduCoreText 的 `ListMarkerLayoutTests`（20 個，S001c 的實測值直接當預期：decimal 墨跡間距 7.00、圓點 19／9.5／6.83、撐高 12.75、浮動兩種、空 `li`、區塊圖片 `li`；另有開關底部對齊各跑一次的分頁、viewport 估算、非黑色主題下符號和正文同色、畫到點陣圖上確認圓點實心、`circle` 中空、環畫在矩形內側），整套 368 個全過。只畫橫排的 `outside`：直排和 `inside` 的 `ListMarker.make` 回傳 nil，各等第 5、6 步。第 5 節沒量的四組也在這一步量完。

   會靜默少畫符號的兩個地方，都是「不該發生」的內部錯誤：項目沒有序號（`ListMarker.make`：除錯版 assert，正式版往診斷 sink 記一筆 `list item has no ordinal`），以及 `PageWalker` 在堆疊上找不到符號所屬的 list item（只有 assert，walker 沒有診斷 sink，和它既有的步數上限檢查同一種處理）。
5. **直排**（2026-11-03 實作，未提交）：第 10 節。
   - 符號字串走正文的直排處理，發出時由 `LogicalFlow` 換軸。區塊方向的佔位、畫的位置和空項目照第 10 節另寫直排的規則。
   - 動手前先補量了兩組沒量的情況（`lists-9`），結論見第 10 節。
   - 測試：`ListMarkerLayoutTests` 新增 8 個（共 28 個），整套 376 個全過。
     - 編號位置和字向：數字橫躺，「一」直立、「、」用直排字形。
     - 欄寬 8 種情況：25、37、23、不撐寬、42.5。
     - 根行內盒的三組 span、空項目（ol／ul）、大字級往左 6、圓點位置。
     - 點陣圖墨跡間距：decimal、cjk、圓點都在 WebKit 值 0.5 以內。
     - 換主題色後仍是直排字形；分頁和捲動都跟著行走；直排清單照常准入。
     - App 實際傳的 CJK 排版樣式：繁中書是 `.traditional`，測試裡的符號都沒帶這個樣式。帶上後，橫排和直排符號的 rect、基線都和不帶時完全相同，墨跡間距也在 WebKit 值 0.5 以內。
     - 原本「直排不畫」的測試改成只測 `inside`。
   - 已知差異：
     - 橫躺字比 WebKit 偏約 0.38（`centreSideways` 不進位，正文也一樣）。
     - UA 的 40px 縮排當時仍是實體左邊，所以直排清單的符號會畫在頁面上方的邊距裡；測試先用 `ol, ul { padding: 40px 0 0 0 }` 代替。第 8 步已修，這段代替的 CSS 也拿掉了。
   - 只動了 YueduCoreText，App 的舊引擎直排（`CoreTextWritingModeTests`）沒有碰，所以沒有跑那組。
6. **能力掃描兜底**（2026-11-03 實作，未提交）：`inside` 的回退條件，第 4 節。
   - 新增公開的 `UnsupportedFeature.listMarker` case。App 沒有對這個列舉做完整的 `switch`（2026-11-03 grep 過），App 的普查測試也是用自己的列舉。
   - 測試：`ListMarkerAdmissionTests`（3 個，橫排、直排都跑），整套 379 個全過。
   - 版面測試裡直接排 `inside`（不經准入）時仍然不畫，`ListMarker.make` 回傳 nil。
7. **VoiceOver 文字**（2026-11-03 引擎部分實作，未提交；App 改用排在第 9 步）：
   - 新的公開函式 `DisplayList.spokenText(pageText:pageRange:paragraphRanges:)`，寫在 `BrowserLayoutSemanticContent.swift`。輸入是 App 的頁面本來就有的三樣：頁面原文、它的範圍、整章的段落範圍（選取用的那份）。去掉圖片的 U+FFFC、頭尾空白也在函式裡做，宿主不再自己處理。
   - 怎麼認符號：沒有原文字元（`sourceRange` 長度 0）又有 `renderedTextOverride` 的文字項目，`DisplayTextItem.isListMarker`。ruby 注音帶著本文的範圍，不會被當成符號（已測）。沒有加新欄位，因為要穿過約 8 個複製點，漏一個就靜默少唸，和 `followsTextColor` 是同一種風險。以後畫 `::before` 這類生成內容也會符合這個條件，那時要另外區分。
   - 編號照決策 1 去掉後綴尾端的空白：「1.」「一、」。
   - **新增（使用者 2026-11-03 選定一起修）：段落之間換行。** 原文的區塊之間沒有任何分隔，所以 VoiceOver 原本唸「第一章 序幕Fruit:那天下雨。AppleBananaEnd」，舊引擎有換行。現在每個從這一頁開始的段落前面加一個換行；從前一頁延續過來的段落不加。
   - 編號放在項目開頭那一行，後面空一格再接正文：「Fruit:\n1. Apple\n2. Banana」「一、 甲。」。這個空格和換行是我加的分隔，不是決策 1 的內容：區塊之間沒有分隔，不加的話「Apple」會和「2.」黏在一起。
   - 同一個位置開始兩個項目（`<li><ol><li>`，或空項目接下一項）時照文件順序唸：「3. \n1. 甲。」。為此 `ListMarker.anchor` 改成插到陣列最前面（第 8 節）。
   - 頁面範圍包含起點、不含終點。捲動的圖塊會多畫前後鄰居的邊緣行，含終點的話下一塊的第一個編號會唸兩次。代價：頁尾沒有文字的空項目不唸編號，它本來也沒有內容可唸。
   - 跨頁的項目只在第一頁唸編號。
   - 以圖片開頭的項目，編號自己一行：「1. \n前文」。編號在圖片的 U+FFFC 上，段落範圍從圖片後面開始。不把兩者跨圖片合併，因為只有區塊圖片的項目也會被合到下一段（「1. 後文」），那段不屬於這個項目。
   - 測試：YueduCoreText 新增 `ListMarkerSpokenTextTests`（10 個）。涵蓋各種計數樣式、圓點不唸、巢狀與空項目、跨頁、圖塊含鄰居邊緣、ruby 和圖片、以圖片開頭的項目、直排和橫排唸的一樣、段落換行，以及原文和頁面範圍與不畫編號時完全相同。整套 389 個全過。
8. **UA 清單邊距與縮排**（2026-11-03 實作，未提交）：WebKit 給 `ul`／`ol` 上下 1em（巢狀時 0），我們原本完全沒有；40px 縮排改寫成邏輯邊（第 10 節）。這會改到每一章清單的版面，所以拆成獨立一步。`dl`／`dd` 不順手一起改。
   - **WebKit 的規則**（從 iOS 27.2 runtime 的 html.css 讀出）：
     - `ul, menu, dir, ol { margin-block: 1__qem 1em; padding-inline-start: 40px }`。`1__qem` 只在 quirks mode 有差別，EPUB 的 XHTML 不會進 quirks mode，所以就是 1em。
     - `:is(dir, dl, menu, ol, ul) :is(dir, dl, menu, ol, ul) { margin-block: 0 }`：任何深度都算，`dl` 雖然不畫符號也算。
     - 都是邏輯屬性，直排時 1em 在左右、40px 在上方。
   - **實作：**
     - `UserAgentStyle.basis` 拿掉實體的 `paddingLeft = 40`。
     - 新的 `UserAgentStyle.declarations(for:nestedInList:)`（8b 時叫 `logicalBox`）回傳要經過 cascade 的 UA 宣告（清單容器是三條；8b 起也管 `p`、標題、`blockquote`，8c 起再加標題字級和 `pre`、`figure`、`hr`、`dl`、`dd`）。`ComputedStyleTreeBuilder.resolvedStyle` 在找清單祖先的同一個迴圈裡判斷巢狀（`nestedListMarginAncestors`），再經 `ComputedStylePropertyApplier` 套用。這和作者的邏輯屬性走同一條轉換，直排自動換邊。
     - UA 套在作者規則之前，所以作者寫的同一側（實體或邏輯）會蓋掉它，另外幾側保留。
     - 每條路徑都從計算後的樣式拿到：分頁和捲動共用 `PageWalker`；viewport 的區塊邊距同樣由 `BlockLayout` 解析，還沒排版時的高度估算（`BrowserViewportLayoutState.lines(for:)`）只估行內內容的高度，不碰邊距，所以不用改。
     - 沒有加兜底。
   - **測試：**
     - YueduCoreText 新增 `UserAgentDeclarationTests`（第 8 步叫 `ListContainerUserAgentTests`、8b 叫 `UserAgentLogicalBoxTests`；清單的 3 個，橫排、直排都跑）：四種清單容器的邊距和縮排、巢狀（清單裡、`div` 隔一層、`dl` 裡、`menu` 裡的 `dir`）歸零、`blockquote` 裡和不在清單裡的 `li` 下面保留 1em、作者宣告優先（直排時 `padding-left` 是區塊結尾那一側，40px 仍留在上方）。
     - `ListMarkerLayoutTests` 和 `ListMarkerSpokenTextTests` 拿掉代替 UA 的 CSS（直排的 `padding: 40px 0 0 0`、`padding-left: 40px`），改靠 UA；基本 CSS 只留 `ol, ul { margin: 0 }`，讓原本的實測位置不變。
     - 整套 392 個全過。
   - **和 WebView 對照**（用暫時的測試把 S001c、S001d 共 11 章排一次，取每個 `li` 的位置和探針 JSON 比，比完就刪）：
     - 改之前（用 CSS 模擬舊的 UA）：S001c 區塊方向最大偏差 ch01 119.38、ch02 95.58、ch03 262.06、ch04 47.98、ch06 47.98、ch07 24.18、ch08 12.28（ch05 是 0.04，章節自己把邊距歸零）；S001d 區塊／行內方向 ch01 35.00／40、ch02 136.51／40、ch03 64.00／40。偏差往章尾累積，因為每個清單少 2em。
     - 改之後：每個 `li` 區塊方向 0.38 以內、行內方向 0.5 以內。另有 3 個離群值（02-p-indent、11-chinese-range、14-li-p 的第一項）是對照方法的問題：註解段落也有同一段文字，抓錯元素，不是版面差異。
   - **基線語料延到第 9 步一起量**（使用者 2026-11-03 選定）：第 9 步重量時一次涵蓋符號和這一步的邊距。
   - **順帶查到：** 引擎 UA 的 `p` 和 `h1`–`h6` 用實體的上下邊距，WebKit 是 `margin-block`，所以直排時方向錯（S001d 用 `p { margin: 0 }` 蓋掉，看不出來）；`blockquote` 沒有 WebKit 的 `margin-block: 1em`。使用者 2026-11-03 選定在第 9 步之前修，見下面的 8b。
8b. **UA 的 `p`、標題、`blockquote` 改成邏輯邊距**（2026-11-03 實作，未提交）：
   - **WebKit 的規則**（iOS 27.2 runtime 的 html.css）：
     - `p { margin-block: 1__qem; margin-inline: 0 }`：只寫一個值，所以兩端都是 1em。
     - `:heading(1)`～`:heading(6)` 的 `margin-block` 依序是 0.67、0.83、1、1.33、1.67、2.33em，`margin-inline: 0`。27.2 已經沒有「`article`／`section` 裡的 `h1` 變小」那幾條。
     - `blockquote { margin-block: 1__qem 1em; margin-inline: 40px }`。
   - **實作：** `UserAgentStyle.basis` 拿掉這幾個標籤的實體邊距（`p`、`h1`–`h6` 的上下、`blockquote` 的左右 40px），字級和粗細留在原處；邊距併進第 8 步的 `logicalBox`，同一個迴圈套用，沒有第二條路。沒有加兜底。
   - **版面變化：**
     - 直排：段落和標題的邊距從上下（行內方向，等於每段頭尾內縮 1em）移到左右（欄與欄之間）；`blockquote` 的 40px 從左右移到上下。
     - 橫排：`p` 和標題不變；`blockquote` 多了上下各 1em（原本完全沒有）。
   - **測試：**
     - `UserAgentDeclarationTests` 加 3 個（共 6 個）：`p` 和六級標題的 em 值、`blockquote` 四邊（直排是上 40、右 1em、下 40、左 1em）、作者宣告優先（`p { margin: 0 }`、`blockquote { margin-left: 0 }` 兩種方向），以及排版層級的一個：兩個沒有樣式的 `<p>` 沿區塊方向相隔一行（25.5）加 1em（邊距合併，不是 2em），行內方向從 0 開始。
     - 改了一個既有的預期：`LogicalPropertyTests.theEvaluationCascadesForTheWritingModeItJudges` 原本斷言直排 `p` 的 `marginLeft == 0`，那是照舊的錯誤 UA 寫的；改成 `.em(1)`（UA 的 `margin-block-end`），仍能分辨「被當成橫排對應到左邊的 2em」。
     - 整套 395 個全過。
   - **和 WebView 對照**（暫時的測試書，橫排和直排各一章：沒有樣式的 `p`、兩個相鄰的 `p`、六級標題（字級統一 20px，避開下面的字級問題）、`blockquote`、`blockquote` 裡的清單，每個後面接一個 `margin: 0` 的單項清單，用探針量 `li` 的位置；測試書和比對測試都沒留）：
     - 改之前：橫排區塊方向最大差 68.30（`blockquote` 少了上下邊距，往後累積），直排區塊方向 398.12、行內方向 40。
     - 改之後：橫排 0.38 以內（基線的既有 0.38 進位差），直排 0.08 以內，行內方向 0。
     - S001c、S001d 沒有 `blockquote` 和標題，橫排 `p` 不變、S001d 的 `p` 自己歸零，所以第 8 步的對照數字不受影響。
   - **順帶查到：** 標題字級寫死 px；`figure`、`hr`、`pre`、`dl`、`dd` 完全沒有 UA 邊距。使用者 2026-11-03 選定在第 9 步之前一起修，見 8c。
8c. **UA 的標題字級改成相對值，`pre`、`figure`、`hr`、`dl`、`dd` 補上邊距**（2026-11-03 實作，未提交）：
   - **WebKit 的規則**（iOS 27.2 runtime 的 html.css）：
     - 標題字級：`:heading(1)` 2em、`(2)` 1.5em、`(3)` 1.17em、`(4)` 不設（繼承）、`(5)` 0.83em、`(6)` 0.67em，都相對於父元素。引擎原本寫死 32、24、18.72、16、13.28、10.72px，是正文 16px 時的換算值：不跟著閱讀器字級變，正文 17px 時 `h1` 比 WebKit 小 2px。
     - `pre { margin-block: 1em; margin-inline: 0 }`、`figure { margin-block: 1em; margin-inline: 40px }`、`hr { margin-block: 0.5em; margin-inline: auto }`、`dl { margin-block: 1em }`、`dd { margin-inline-start: 40px }`。
     - `dl` 也受清單的巢狀規則管：在 `dir`、`dl`、`menu`、`ol`、`ul` 裡（任何深度）`margin-block: 0`。
   - **實作：**
     - 全部寫進同一個 `UserAgentStyle.declarations(for:nestedInList:)`（由 `logicalBox` 改名，因為字級不是邊距），同一個迴圈經 `ComputedStylePropertyApplier` 套用。字級寫成 `2em` 這種宣告，所以照父元素算，作者的 `font-size` 照樣蓋掉它。
     - `basis` 的標題只留粗體。`applyingUA` 裡處理 UA 絕對字級的那一行（`ua.fontSize != 17`）已經沒有任何標籤會用到，刪掉。
     - 巢狀判斷從只看清單容器改成也看 `dl`。
     - `hr` 的 `margin-inline: auto`：引擎支援 auto 邊距，`basis` 給 `hr` 的寬度是 100%，所以算出來是 0，和 WebKit 相同。
     - 沒有加兜底。
   - **測試：** `UserAgentDeclarationTests` 加 2 個（共 8 個）：`pre`、`figure`、`hr`、`dd`、`dl` 兩個方向的四邊；六級標題在父元素 20px 時是 40、30、23.4、20、16.6、13.4，父元素 10px 時 `h1` 是 20，作者的 `1.2em` 蓋過 UA。清單巢狀的測試另加 `dl` 在清單裡、在 `dl` 裡歸零。既有測試沒有一個依賴舊的絕對字級。整套 397 個全過。
   - **和 WebView 對照**（暫時的測試書，橫排和直排各一章：沒有樣式的六級標題、`pre`、`figure`、`figure` 裡的清單、`hr`、`dl`、`dd` 裡的清單、清單裡的 `dl`，每個後面接一個 `margin: 0` 的單項清單；測試書和比對測試都沒留）：
     - 改之前：橫排區塊方向最大差 207.55、直排 196.67，行內方向 40。標題每級少 4–6pt（字級），`pre`、`figure` 各少 34（2em），`dl` 少 34。
     - 改之後：直排 0.15 以內；橫排在 `hr` 之前 0.38 以內，`hr` 之後固定多差 2.00，正好是 WebKit `hr` 上下各 1px 的 inset 邊框（下面第一條）。行內方向 0。
     - `pre` 只量了邊距：裡面是中文，兩邊都退到 PingFang，等寬字型有沒有差這次量不到（見下面最後一條）。
   - **查到但沒改（都是這次之前就有的）：**
     - **引擎的 `hr` 不畫線**：WebKit 是 `border: 1px inset; color: gray; overflow: hidden`，畫一條 2px 高的灰線；引擎沒有邊框，什麼都不畫，位置也少 2px。
     - **含 `<hr>` 的直排章節整章交給舊引擎**：`basis` 給 `hr` 寫了 `width: 100%`（WebKit 沒有設寬度），而 `VerticalTextSupport.accepts` 只收 auto 或 px 寬度，回 `unsupported(vertical-writing-mode)`。直排的測試書因此拿掉了 `hr`。
     - **`pre`、`code`、`tt`、`kbd`、`samp` 沒有等寬字型**：WebKit 給它們 `font-family: monospace`，引擎的 UA 沒有。
     - 使用者 2026-11-03 選定這三條在第 9 步之前一起修，見 8d。
8d. **`hr` 畫 1px inset 灰邊框、不再設寬度；`pre`、`code` 等改用等寬字型**（2026-11-03 實作，未提交）：
   - **WebKit 實測**（模擬器 Safari，iOS 27.2，dpr 3，暫時的網頁沒留）：
     - 橫排 `hr` 是 2px 高的邊框盒子，寬度和行一樣。上、左兩邊 rgb(44,44,44)，下、右兩邊 rgb(212,212,212)，各 1px，角是斜接。
     - 直排 `hr` 是 2px 寬的一欄，實體左邊暗、右邊亮。所以明暗看**實體**方向，不看邏輯方向。
     - 顏色公式照 WebKit `BorderPainter::calculateBorderStyleColor`：
       - inset 的上、左邊變暗：`max(0, (v − 0.33) / v)` 乘到每個色版（`v` 是最大的色版），亮度不高於 rgb(32,32,32) 的不變。
       - 下、右邊變亮：`min(1, v + 0.33) / v`，亮度不低於 rgb(235,235,235) 的不變；純黑變 84。
       - outset 相反。
       - 灰 128 算出來正好是 44 和 212。
     - `monospace` 是 Menlo：17px 時十個 M 寬 102.35，等於 Menlo 的字寬（Courier 是 102.01）。字級沿用 17px，不縮小。
   - **實作：**
     - 公開的 `BorderStyle` 加 `.inset`、`.outset`。`from(cssRaw:)` 認得這兩個字，groove、ridge、double 仍當 solid。
     - 顏色在 `DisplayListDrawer.drawFill` 一開始解成 solid（`DisplayFillItem.resolvingBevelEdges` → `BorderEdge.paintedBevel(topOrLeft:)`），放在直排換軸之前，因為這時的邊還是實體方向。顏色先量化到 8 位元（WebKit 的 CSS 顏色本來就是 8 位元），門檻 32 本身才會落在正確那一側。
     - UA 的 `hr` 加上 `border-width: 1px; border-style: inset; border-color: rgb(128, 128, 128)`。
       - WebKit 的邊框是 `currentColor`（`hr { color: gray }`），引擎的邊框沒有 currentColor，所以直接寫灰色。
       - 不寫 `gray`：引擎的命名色表把 `gray` 解成 `UIColor.gray`（127.5），會畫出 43 而不是 44。
     - 拿掉 `basis` 的 `hr { width: 100% }`。寬度 auto 會填滿一行，auto 邊距算出 0，和 WebKit 相同。含 `<hr>` 的直排章節現在由新引擎排。
     - **`border-style: none`／`hidden` 的那一邊計算寬度是 0**（CSS Backgrounds §3.3，寫在 `finalizeBorderLengths`）。不這樣的話，`hr { border: none }` 這種最常見的重設會留下看不見、卻佔位置的 1px。
     - 字型：
       - `InlineLayout.installedFont(family:size:)` 把通用字族 `monospace` 對到 Menlo-Regular，逐個 family 比對，所以 `Consolas, monospace` 也落到 Menlo。
       - UA 給 `pre`、`xmp`、`plaintext`、`listing`、`tt`、`code`、`kbd`、`samp` 加上 `font-family: monospace`；`xmp`、`plaintext`、`listing` 也和 `pre` 一樣有 `white-space: pre` 和區塊方向 1em。
       - `tt`、`kbd`、`samp` 原本落到 `basis` 的預設值，變成**區塊**，這次加進行內那一組。
     - App 選了閱讀器字型時，`epubOverride` 對每一段文字都回那個字型，`pre`／`code` 也一樣。舊引擎也沒有等寬對應，所以行為和現在相同。
     - 沒有加兜底。
   - **測試：** 新檔 `HorizontalRuleAndMonospaceTests`（9 個）：
     - `hr` 的計算樣式（兩個方向）。
     - 三種重設（`border: none`、`border: 0`、`hidden`）寬度歸零；`border: none; border-top: 1px solid` 只留上邊。
     - 橫排 `hr` 寬 300、高 2，和段落的邊距合併。
     - 直排章節含 `hr` 會被收下，`hr` 是寬 2 的一欄；作者寫 `width: 50%` 時仍退回舊引擎。
     - inset／outset 顏色公式的各個門檻。
     - 點陣圖驗兩個方向的明暗邊落在哪一側（44／212）。
     - 等寬：八個標籤的字族；`tt`／`kbd`／`samp` 是行內；作者字族蓋過 UA；`pre`、`code`、`kbd`、`Consolas, monospace` 都排成 Menlo 17px，十個 M 寬 102.35。
     - 整套 406 個全過。
   - **和 WebView 對照**（暫時的測試書，橫排和直排各一章，探針 run `ua-blocks-5`；測試書和比對測試都沒留）。內容：三種 `hr`（預設、`border: none`、`border: none; border-top: 1px solid`）、橫排加一條 `width: 50%`；`pre`；清單項目以 `code`、`kbd`、`samp`+`tt`、`li` 裡的 `pre` 開頭；最後一個項目裡有 `font` 和 `big`。
     - 改之前（用 CSS 模擬舊的 UA）：橫排 `hr` 每條少 2px；`kbd`、`samp`、`tt` 各自斷成一行，到 `li` 裡的 `pre` 時已經差 70.12（直排模擬是 74.50）。實際上直排整章退回舊引擎。
     - 改之後：
       - 三種 `hr` 兩個方向都和 WebKit 一樣，橫排只剩原本的固定 0.38。
       - `code`、`kbd`、`samp`、`tt` 的字型是 Menlo。
       - 直排到 `li` 裡的 `pre` 為止都是 0.00；橫排同一段在 1.91 以內，來源見下面第一條。
   - **查到但沒改（都是這次之前就有的）：**
     - **WebKit 的字型 ascent／descent 無條件進位**（8f 已修）：PingFang SC 17px 是 18.02／5.78 → 19／6，Menlo 是 15.78／4.01 → 16／5。三個實測都吻合這個規則：
       - 純 PingFang 行的基線在行頂下 19.25，引擎算 18.87，這就是每次橫排對照都有的固定 0.38。
       - Menlo 和 PingFang 混排的那一行高 26.5，引擎算 25.73，每行少 0.77。
       - Menlo 字框是基線上 16、下 5。
       引擎的 `InlineLayout.halfLeadingBox` 用沒進位的值。要改的話會動到每一行的基線位置，以及每個混用字型的行高，需要另外量語料。
     - **`li` 裡最後一個區塊的下邊距沒有傳出去**（8f 已修）：`<li><pre>…</pre></li>` 後面接一個 `margin: 0` 的清單，WebKit 有 `pre` 的 1em（17），引擎沒有（橫排少 17.77，直排少 17）。下一個兄弟元素的上邊距不小於它時會被蓋掉，所以平常看不出來。8e 查到不只 `li`：任何父元素都一樣，見 8e。
     - **引擎不認得的標籤預設是區塊**（8e 已修）：`basis` 的預設值是 `display: block`，但 CSS 的初始值是 inline。`font`、`big` 這些舊式標籤（另外還有 `var`、`dfn`、`del`、`ins`、`strike`、`bdi`、`bdo`、`data` 等）在引擎裡各自斷成一行。對照測試裡一個含 `font` 和 `big` 的項目，WebKit 是一行，引擎排成五行，後面全部錯開 100。使用者 2026-11-04 要求接著修，見 8e。
     - **單一 `border-color`**（8f 已修）：`hr { border-top: 1px dotted #999 }` 不先重設時，WebKit 只有上邊是 #999，其他三邊仍是灰色 inset；引擎四邊都是 #999。邊框也沒有 currentColor：沒寫顏色時引擎畫黑色，作者寫 `hr { color: red }` 不會改到邊框色。
     - **命名色不是 CSS 的值**（8f 已修）：`gray` 是 127.5（CSS 是 128）、`green` 是 #00FF00（CSS 是 #008000），`orange`、`purple` 也不對。
     - **通用字族只對應 `monospace`**（8f 已修）：`serif`、`sans-serif` 仍落到系統字型（WebKit 的 `serif` 是 Times）。
     - **圓角的 inset 邊框**（8f 已修）：顏色不一致，所以畫成直角；1px 的角是方塊重疊，不是 WebKit 的斜接。
     - **`hr` 的 HTML 屬性**（`noshade`、`size`、`color`、`width`）沒有對應（8f 已修）。2026-11-03 查語料：55 本裡有 15 本用到 `hr`，沒有一個帶這些屬性。最常見的是 `hr.transition { border: none; margin: 0 }`（227 個），靠上面的「none 歸零寬度」才不會多出 2px。
   - **App 這邊查過：**
     - App 的字型 resolver（`EPUBStyleResolver.RegisteredFonts.resolve`）對 `monospace` 回 nil：沒有內嵌字型，`UIFont(name:)` 也找不到，所以 App 裡會走到引擎的 Menlo 對應。
     - `prepareFonts` 收到 `monospace` 請求時，沒有對應的 `@font-face`，會直接跳過，不記錯誤。
     - App 沒有自己畫 fill 的地方：`BrowserLayoutPageEngine` 只讀 fill 的位置做除錯疊圖，邊框都由 `DisplayListDrawer` 畫。
8e. **WebKit html.css 沒列出的標籤改成行內**（2026-11-04 實作，未提交）：
   - **WebKit 實測**（探針 run `ua-inline-1`，橫排和直排各一章，測試書沒留）：
     - `var`、`dfn`、`del`、`ins`、`strike`、`bdi`、`bdo`、`data`、`nobr`、自訂的 `foo`、帶 `color` 的 `font`，都和文字排在同一行（行高 25.5）。
     - `<font><p>甲</p><p>乙</p></font>`：兩段各自成行，邊距照常合併，和放在 `div` 裡一樣（含前面那個項目共 127.5）。
     - `<div><var>甲</var>\n<p>乙</p></div>`：空白不會多出一行。
     - 直接放在 `body` 裡的 `<foo>` 自成一個匿名區塊的一行。
     - `noscript` 裡的段落不佔位置：WKWebView 預設執行腳本，html.css 的 `@media (scripting) { noscript { display: none !important } }` 生效。
     - `center` 是區塊。
     - 有 `big`、`sup`、`sub` 的行會變高（WebKit 的字級和上下標規則，引擎沒有，見下面）：

       | 行裡有 | 橫排行高 | 直排行寬 |
       |---|---|---|
       | `big` | 30.58 | 30.58 |
       | `sup` | 29.03 | 30.03 |
       | `sub` | 28.77 | 27.77 |
       | `small`、`u` | 25.5 | 25.5 |
   - **實作：**
     - `UserAgentStyle.basis` 的預設值從 `display: block` 改成 `inline`（CSS 的初始值）。區塊那一組改成 html.css 列出的全部：
       - 原有的那些，加上 `p`、`h1`–`h6`、`hgroup`、`search`、`center`、`menu`、`dir`、`xmp`、`plaintext`、`listing`、`details`、`summary`、`optgroup`、`option`、`frameset`、`frame`。這些以前靠預設值才是區塊。
       - `legend` 在 html.css 沒有 display，但 fieldset 裡的 legend 繪製時會變成區塊（HTML Standard §15.3.13），所以列為區塊。
     - **`video` 維持區塊，和 WebKit 不同**：WebKit 把它當行內的替換元素。引擎的媒體處理把 `video` 換成一張沿用它樣式的占位圖，這張圖一直是區塊圖片。改成行內會動到 App 的影片占位，不在這次範圍內。
     - 隱藏那一組加上 `area`、`base`、`basefont`、`datalist`、`noembed`、`noframes`、`param`、`noscript`。
     - 拿掉原本的行內清單：預設值已經是行內。`em`／`i` 的斜體、`strong`／`b` 的粗體移到第二個 switch。
     - 沒有加兜底。
   - **對收不收章節的影響：**
     - ruby 的基底包在 `font` 這類標籤裡時，以前因為基底是區塊而整章退回舊引擎，現在和包在 `span` 裡一樣會被收下。
     - 有 `caption` 或 `colgroup` 的表格仍然退回舊引擎：引擎沒有欄和標題的 display，表格檢查不收任何非列的子元素，不管它是區塊還是行內。
   - **語料**（2026-11-04 數 55 本的標籤）：`font`、`big` 都是 0 個，`del` 1 個。上一輪說「舊中文書很常見」沒有語料根據，是推測。這次對現有語料幾乎沒有版面變化，主要是確認其他標籤沒有跟著動。
   - **測試：** 新檔 `UnknownElementDisplayTests`（10 個）：
     - 13 個標籤的計算 display 是行內；23 個 html.css 的區塊標籤是區塊；7 個隱藏標籤不繪製，`noscript` 裡的段落不佔位置。
     - 兩個方向：10 個標籤排起來和 `span` 的基線、位置完全一樣；`font` 裡的兩段和 `div` 裡一樣，`font { color: red }` 傳到段落；行內元素和區塊之間的空白不多一行；ruby 基底包在 `font` 裡會被收下，而且基底和注音的位置都和包在 `span` 裡一樣；`text-indent` 段落以 `font` 開頭會被收下。
     - 有 `caption` 或 `colgroup` 的表格仍然退回。
     - 整套 415 個全過（另外 49 個 XCTest 也過）；之後只加了 ruby 版面那一個測試，程式沒動，單獨跑這個類別 10 個全過。
   - **和 WebView 對照：**
     - 改之前（用 CSS 把這些標籤設回區塊來模擬）：每個含這些標籤的項目多出兩行，到最後橫排差 445.04、直排差 445.42。
     - 改之後，到 `<font>` 包段落的那一項為止：橫排只有固定的 0.38，直排 0.00。
     - 後面先多差 17：這是下面第一條既有的邊距問題，換成 `span` 也一樣。
     - 再後面 `big`、`sup`、`sub` 三行各差 2.5 到 4.5，來源是下面第二條。最後橫排差 29.26、直排差 28.88。
   - **查到但沒改（都是這次之前就有的）：**
     - **父元素最後一個子區塊的下邊距不會穿出父元素**（8f 已修），比 8d 記的「`li` 裡」範圍更大：
       - `<div><p>乙</p></div>` 後面接一個沒有上邊距的元素時，WebKit 是 25.5＋17（`p` 的下邊距穿過 `div` 的底），引擎只有 25.5。
       - 巢狀的 `div`、`li` 都一樣。後面接的是有上邊距的段落時，兩個邊距合併成 17，所以看不出來。
       - 對照裡的 `<div><var>甲</var> <p>乙</p></div>` 少的 17 就是這個。
     - **其他 html.css 的行內規則引擎都沒有**（8f 已修）：
       - `big`／`small` 的 `larger`／`smaller`；`sup`／`sub` 的 `vertical-align` 和 `smaller`。
       - `u`／`ins` 的底線，`s`／`strike`／`del` 的刪除線。
       - `cite`／`var`／`dfn`／`address` 的斜體；`center` 的置中；`q` 的引號；`nobr` 的不換行。
       - 影響最大的是 `sup`：語料有 17,889 個。其中 `deep-work`（14）、`guimi` 和 `guimi-src`（各 49）、`hongwu`（9）、`orv`（87）完全沒有 `sup` 樣式（沒有選到 `sup` 的規則、沒有 class、沒有 style 屬性），在引擎裡是全尺寸、排在基線上的普通文字。其他有 `sup` 的書靠 class 設了 `vertical-align: super`（例如 Calibre 轉出的 `guimi-azw3`）。
       - 引擎已經支援 `vertical-align: super／sub` 的位移（WebKit 的算法），但只有橫排（`InlineLayout.swift:217`），直排要另外量。
     - **`font` 的 `color`、`size`、`face` 屬性沒有對應**（8f 已修）：語料裡沒有 `font`。
     - `display: initial`／`unset` 被丟掉（應該是行內）；`dialog` 沒有 `open` 時應該隱藏，現在是行內。語料都沒有。（8f 已修）
8f. **8d、8e 查到的項目全部修完**（2026-11-04 實作，未提交；使用者 2026-11-04 要求全部做完、中間不問）：
   - **WebKit 實測**（iOS 27.2 WKWebView，dpr 3，橫排和直排）：
     - 測試書留在 `scripts/fidelity/fixtures/gaps/`：`S001e-ua-rules`（橫排）、`S001f-vertical-ua-rules`（同一章的直排，固定尺寸改成實體方向）、`S001g-quotes-and-generic-families`（第 1 章 `q`，第 2 章通用字族）。
     - `list_probe.sh` 加了元素模式（`fixture.json` 的 `"elements": true`）：量每個 `data-m` 元素的框、基線和計算樣式；`data-ink` 的元素另外截圖量墨跡（底線、邊框的像素）。
     - S001f 的 `<hr width="50%">` 會讓整章退回舊引擎（直排的百分比寬度不收），WebKit 當成 auto；對照時拿掉那一行。
   - **修了什麼**（每一項都先量 WebKit，再照量到的寫）：
     1. **最後一個子區塊的下邊距穿出父元素**（CSS 2.1 §8.3.1）：父元素底部沒有 padding、border、height 時，子元素的下邊距和父元素的合併，再和後面的元素合併。浮動、inline-block、表格儲存格不合併。根元素的上邊距照舊由 page walker 讀成頁面內距。九種情況兩個方向都和 WebKit 一樣：
        - 巢狀 `div`、`ul > li > p`、後面接段落：42.5。
        - 父元素有 1px padding 或 1px border 擋住：43.5。
        - 負的下邊距：32.5。固定高度：40。
     2. **`big`、`small`、`sup`、`sub` 的字級和上下標**：
        - `big`／`small` 是父字級的 ×1.2／÷1.2（17px 裡 20.4、14.17）。`sup`／`sub` 加上 `vertical-align` 和 `smaller`。
        - 位移照父框的字級算，而且會往下傳：`<sup><a>1</a></sup>` 的 1 以前不會抬高，現在會。
        - 直排也做位移（CoreText 的 `baselineOffset` 在直排是往右移），直排行寬改成每段文字各自的行高置中後取聯集。
        - 行高（橫排）／行寬（直排）：`big` 30.58／30.58，`sup` 29.03／30.03，`sub` 28.77／27.77，巢狀 `sup` 31.47／33.97。字形的位移（6.67、−4.39、巢狀 12.38）都在 0.05 以內。
     3. **WebKit 的字型度量**（8d 查到的固定 0.38）：每個行內框的 ascent、descent 各自無條件進位（PingFang 18.02 → 19）。WebKit 的 `FontCoreText.cpp` 讓 Times、Helvetica 的上方多 15%，Hiragino 的下方多 3，但正常行距用加之前的值。原始碼也把 Courier 和 Times、Helvetica 列在一起，但 iOS 27.2 實測 Courier 沒有加，所以照實測不加。
        - 17px 的 span 放在 1.5 倍的 PingFang 行裡，行高：Menlo 26.5，system-ui、Hiragino Mincho、Times 26，Apple SD Gothic Neo、Snell Roundhand 27，Zapfino 29，Helvetica 維持 25.5。
        - strut 也改用同一個函式。`BrowserLayoutFloatLayoutTests` 有一個預期值是拿沒進位的 descender 推出來的（不是量測值），改成用同一個函式算。
     4. **文字裝飾線**（新檔 `Engine/TextDecoration.swift`、`Rendering/TextDecorationPainter.swift`）：
        - 屬性：`text-decoration` 簡寫，`-line`、`-style`、`-color`、`-thickness`、`text-underline-offset`、`text-underline-position`、`text-decoration-skip-ink`。UA 規則：`u`、`ins` 畫底線，`s`、`strike`、`del` 畫刪除線。
        - 傳遞照 CSS Text Decoration 4 §2.1：線畫在設定它的那個框的基線上，用那個框的字型和顏色。浮動和 inline-block 不接收。後代寫 `none` 拿不掉祖先的線。
        - 位置照 WebKit（`TextBoxPainter`、`InlineTextBoxStyle`）：auto 粗細是字級的 1/16，畫線時對齊裝置像素。直排的底線畫在整行帶著這條線的最左邊那個框外面。
        - skip-ink：拉丁字的線在字形穿過的地方斷開，中日韓字不斷（WebKit 的 Unicode 區塊清單），直排不斷。
        - 雙線、點線、虛線、波浪線照 WebKit 的演算法。
        - 兩條繪製路徑最後都走 `DisplayListDrawer.draw`，所以線掛在 `DisplayTextItem` 上，只有一份實作。`currentColor` 的線換主題時跟著文字換色，自己有顏色的線不換。
        - 實測：17px PingFang 的底線在基線下 1⅓、粗 1⅓（30px 粗 2），刪除線在基線上 6⅓，上線在內容框頂。底線、上線、刪除線兩個方向都在一個裝置像素以內。skip-ink 的缺口是 0–12.10、30.50–42.90（引擎 12.087、30.498、42.901）。
     5. **斜體、置中、不換行**：
        - `cite`、`var`、`dfn`、`address` 是斜體。
        - `center` 是 `text-align: -webkit-center`，文字和區塊子元素都置中（橫排 149、157.5）。
        - `nobr` 是 `white-space: nowrap`：換行點落在 nowrap 文字中間時，整段換到下一行；已經在行首時整段溢出。WebKit 是 200px 寬裡排三行，nobr 在第二行、寬 289。
     6. **`q` 的引號**（新檔 `Engine/QuoteMarks.swift`）：html.css 的 `q::before`／`::after`。
        - 做法比照清單編號：引號是沒有原文位置的產生文字，原文、閱讀位置、搜尋和選取都碰不到它。
        - 語言表和查表規則照 WebKit：`zh-Hant`、`ja` 是「」『』；`zh-TW`、`zh-HK`、`ko`、`en` 是 “” ‘’；沒有 `lang` 或 `und` 是直引號。巢狀用下一層，超過最後一層就重複最後一層。
        - `quotes` 屬性（`auto`、`none`、字串對）一起做。
     7. **`<font>` 的 `color`、`size`、`face`**：
        - 顏色照 HTML 的舊式顏色解析（`chucknorris` 是 rgb(192, 0, 0)）；`size` 照舊式字級（1–7、`+n`、`-n`）；`face` 是 `font-family` 清單。
        - **字級刻意和 WebKit 不同**（使用者 2026-11-04 選定）：WebKit 的 `medium` 固定是 16px，引擎改用閱讀器的根字級（17）。所以 `<font size>` 和 `small`、`x-large` 這些關鍵字都是 WebKit 的 ×17/16，跟著閱讀器字級變。對照裡只有這一項會累積：`<font size>` 那段之後差 3.86，下一段之後差 4.61，之後一直是 4.61。
     8. **通用字族**（新檔 `Engine/GenericFontFamily.swift`）：`serif`、`sans-serif`、`cursive`、`fantasy`、`monospace`、`system-ui` 照 WebKit 依內容語言選字型，表在檔頭。8d 的 `monospace` → Menlo 併進這裡。
     9. **CSS 色名**（新檔 `HTMLCSS/CSSNamedColors.swift`）：148 個 CSS 色名，取代原本那組不是 CSS 值的（`green` 是 (0, 128, 0)、`gray` 是 128）。
     10. **邊框**：
         - 四個邊各自有顏色。沒寫顏色時是 `currentColor`，也就是元素自己的 `color`；這種邊框換主題時跟著文字換色（`followsTextColor`）。
         - 作者寫的邏輯邊框屬性（`border-block-end` 等）以前被丟掉，現在照書寫方向對應到實體邊。
         - `hr` 的 `noshade`、`size`、`color`、`width`、`align`（照 WebKit 的 `HTMLHRElement`）。
     11. **邊框轉角**：除了四邊同色同樣式的外框，實線的邊改照 WebKit `BorderPainter` 一邊一塊畫：
         - 順序是上、下、左、右。兩邊在轉角沿外角到內角的斜線切開；兩邊同色時切線不反鋸齒，不同色時反鋸齒。
         - 有圓角時，內圓角半徑是外半徑減去相鄰的邊寬。
         - 點線和虛線仍用原本的筆畫。
         - 實測：紅色左邊和黑色下邊交在斜線上，那個像素是 (191, 64, 0)；4px、半徑 10 的 inset 邊框保留弧形。
     12. `display: initial`／`unset` 是行內；沒有 `open` 的 `dialog` 不繪製。
     13. 對照時查到的一個既有 bug：直排 run 的寬度把 `CTRunGetPositions` 的 x 當成行內起點，但那是旋轉後字形空間的座標，第一段多算半個 em（8.5）。改成累加前面各 run 的寬度。
   - **和 WebView 對照**（S001e、S001f）：每一列兩個方向都在 0.11 以內，除了：
     - `<font size>` 那段：上面第 7 項刻意的差異。
     - `sup`／`sub` 裡的字顯示差 6.7／−4.4：這是比對腳本的假差。腳本讀的是片段的行基線，但上下標的位移在字形上（`baselineOffset`），不在片段上。單元測試直接量字形，都在 0.05 以內。
     - 0.11 的累積：WebKit 的版面用 1/64 px 的 LayoutUnit，行框高度會被量化，引擎不量化。每一行的行高都在 1/32 以內，到章末累積 0.11。
     - `q` 的 0.13、0.91 和 `center` 的 0.50：比對腳本取 WebKit 文字座標時取整。框的實際座標 51.125、90.906、157.5 都對上。
   - **測試**（YueduCoreText，新檔 5 個、34 個測試函式，預期值都是 WebView 的實測值；`<font size>` 是 ×17/16）：
     - `UserAgentInlineRuleTests`（10）：下邊距九種情況、字級和行高、字形位移、斜體、`center`、`nobr`、`initial`／`unset`、`dialog`、色名。
     - `TextDecorationTests`（11）：解析和簡寫、UA 規則、傳遞、兩個方向的位置、skip-ink、顏色、點線、虛線、雙線、像素對齊。
     - `QuoteAndFontHintTests`（7）：引號表、引號佔的寬、`<font>` 的字級、顏色和字型、通用字族、WebKit 行高。
     - `BorderHintTests`（3）：`hr` 的屬性、`currentColor`、邏輯邊框。
     - `BorderCornerTests`（3）：在點陣圖上量兩色斜接、圓角 inset 邊框（兩個方向）、不等寬的邊不畫出框外。
     - 整套 455 個全過，另外 49 個 XCTest 也過。
   - **沒加兜底。**
   - **查到但沒改**（不在要修的清單上，只記錄）：
     - html.css 的 `a:any-link`（連結色和底線）、`mark`（黃底）引擎都沒有。
     - `«`、`„`、`‚` 引擎的字型串接退到 Georgia（App 共用的最後補字字型），WebKit 退到 Helvetica。法、德、俄文的引號因此差 0.4～1.5，原文裡的這些字元也一樣。
     - 作者寫的 `::before`／`::after` 生成內容仍然不支援。`display: block` 的 `q` 不加引號（引號只在行內的 `q` 上產生）。
     - 圖片、ruby、直排橫向數字（tate-chu-yoko）、inline-block 和清單符號不畫裝飾線。直排不做 skip-ink（WebKit 也不做）。波浪線、點線、虛線、雙線照原始碼寫，沒有截圖量過。
     - 主題換色時 `DisplayList.items(in:)` 和換色路徑原本就不複製 `paintTransform`，這次沒順手改，只帶上裝飾線。
     - 直排探針截到的上線墨跡只有半個粗細（0.667），測試只比它的左緣。
     - 直排的 `hr` 寫了百分比寬度仍退回舊引擎（8d）。

9. **發佈 YueduCoreText 0.13.0**：App 的套件版本要求改成 0.13.0（`upToNextMinorVersion`），完成第 11 節 App 那幾列的確認，重量基線語料。App 的 `HTMLAttributedStringBuilder.applyPresentationalHints` 要補 `.listStyleType` 的空 case（舊引擎不用它），CHANGELOG 寫明第 6 節的公開 API 變動和 `display: list-item` 的版面變化，以及 `FillFragment`／`DisplayFillItem` 新增的 `followsTextColor`：複製既有 fill 的程式要把它傳下去，否則圓點換主題時不跟著換色。2026-11-03 查過 App，只有測試（`BrowserReaderParityTests`、`BrowserLayoutEngineTests`）自己建新的 fill，沒有複製既有 fill 的地方；升版時再 grep 一次 `DisplayFillItem(`、`FillFragment(`。CHANGELOG 也要寫新的回退原因 `UnsupportedFeature.listMarker`（`list-marker`），以及它造成的閱讀位置偏移（第 4 節）。CHANGELOG 也要寫新的公開 API `DisplayList.spokenText(pageText:pageRange:paragraphRanges:)`。CHANGELOG 也要寫第 8 步的版面變化：沒有作者樣式的清單上下多 1em（巢狀時不多），直排清單的 40px 縮排從左邊移到上方；8b：直排的 `p`、標題邊距改到欄與欄之間，`blockquote` 兩個方向都多了區塊方向的 1em、直排的 40px 移到上下；8c：沒有作者字級的標題改成相對字級（跟著閱讀器字級變，`h1` 是 2em），`pre`、`figure`、`dl` 多了區塊方向 1em，`figure` 兩側、`dd` 開頭各內縮 40px，`hr` 上下 0.5em。8d：公開的 `BorderStyle` 新增 `.inset`、`.outset`（App 沒有對它做完整 switch 的地方，升版時再 grep 一次）；作者寫的 inset／outset 邊框改照 WebKit 分明暗畫；`hr` 多了 1px inset 灰邊框（橫排每條多 2px）；`border-style: none`／`hidden` 的邊不再佔寬度；`pre`、`code`、`tt`、`kbd`、`samp` 改用 Menlo，`tt`、`kbd`、`samp` 從區塊改成行內；**含 `<hr>` 的直排章節從舊引擎改由新引擎排，這些章節的閱讀位置會變**（第 4 節）；作者給 `hr` 寫百分比寬度的直排章節仍退回舊引擎。8e：html.css 沒列出的標籤（`font`、`big`、`var`、`del`、自訂標籤等）從區塊改成行內，`noscript`、`datalist` 等改成不繪製；ruby 基底包在這類標籤裡的章節從舊引擎改由新引擎排；`video` 刻意維持區塊。8f：父元素最後一個子區塊的下邊距會穿出父元素（後面接沒有上邊距的元素時多出那段邊距）；`big`、`small`、`sup`、`sub` 有了字級和上下標，直排也有；行內框的 ascent、descent 照 WebKit 進位（PingFang 每行約多 0.38，Times、Helvetica 上方多 15%）；底線和刪除線（`u`、`ins`、`s`、`strike`、`del` 和作者的 `text-decoration`）；`cite`、`var`、`dfn`、`address` 斜體，`center` 置中，`nobr` 不換行；`q` 加引號（產生文字，不在原文裡，閱讀位置不動）；`<font>` 的 `color`、`size`、`face` 和 `<hr>` 的屬性生效，字級關鍵字以閱讀器字級為 medium（WebKit 是固定 16px）；通用字族照內容語言選字型；色名改成 CSS 的值（例如 `green` 從亮綠變成 (0, 128, 0)）；邊框四邊各自有顏色，沒寫顏色時跟著文字色和主題；作者的邏輯邊框屬性生效；實線邊框的轉角改成斜接；`display: initial`／`unset` 是行內；沒有 `open` 的 `dialog` 不畫；直排第一段寬度多算的半個 em 修掉。公開 API：`HTMLPresentationalHintProperty` 新增 `listStyleType`、`color`、`fontSize`、`fontFamily`、`backgroundColor`、`borderColor`、`borderStyle`、`borderBottomWidth`、`marginLeft`、`marginRight`，`HTMLPresentationalHintValue` 新增 `listStyleType`、`color`、`fontSize`、`fontFamily`、`solidBorderStyle`、`auto`，新型別 `HTMLListStyleType`、`HTMLFontSizeKeyword`、`CSSRGB`、`CSSNamedColors`；App 的舊引擎 `HTMLAttributedStringBuilder` 對它們做完整 switch，要補上這些 case，維持舊引擎原本的行為。基線語料這次一起量第 8 步、8b、8c、8d、8e 和 8f。App 測試裡同時用到新引擎和標題、`figure`、`blockquote`、`pre`、`dl`、`hr` 的（2026-11-03 grep）：`BrowserLayoutCapabilityScannerTests`、`BrowserLayoutImageTests`、`BrowserLayoutPageEngineTests`、`BrowserLayoutRedChamberRegressionTests`、`BrowserLayoutWhiteSpaceTests`、`BrowserViewportTextlessChapterTests`、`CoreTextPerformanceFixtures`、`CoreTextScrollTests`、`CoreTextWritingModeTests`、`EPUBRenderingTests`、`EPUBTestFixtures`、`KF8ConverterTests`、`OnlineReaderPipelineUnificationTests`、`RedChamberProductionRenderingRegressionTests`、`yuedu_appTests`；升版後先跑這些，寫死位置或字級的預期可能要照 WebKit 重定。
   - **App 接上 VoiceOver 文字（第 7 步留下的）：**
     - `BrowserLayoutPageView.accessibilityPageText` 改成 `displayList.spokenText(pageText: pageSourceText, pageRange: pageSourceRange, paragraphRanges:)`。
     - 這個 view 要自己存一份段落範圍。兩條路徑本來就把它傳給 `configureTextInteraction(paragraphRanges:)`：分頁是 `layout.paragraphRanges`，捲動是 `chapter.paragraphRanges`。存下後要 `refreshAccessibility()`。
     - 分頁模式是先建 view controller 才呼叫 `configureTextInteraction`，所以存段落範圍時要重新整理朗讀文字。
     - `pageSourceText` 和 `plainText(forPage:)` 保持原文，不要改：聽書的高亮和 `BrowserLayoutPageView` 624 行都靠它對原文位置。
     - 952 行的 `accessibilityPageText.isEmpty`（只有影音的頁面）照舊成立。
     - App 目前沒有任何測試檢查這個朗讀文字，要補一個，分頁和捲動各一。
     - 捲動的那個測試要用 App 真正切出來的相鄰圖塊，並放一個跨圖塊邊界的清單項目，確認每個編號在所有圖塊裡剛好唸一次。引擎只用拼起來的分頁範圍測過「含起點、不含終點」；如果 App 切圖塊時同一行同時算進兩塊的 `charRange`，編號照樣會唸兩次。
   - **2026-11-04 進度：**
     - YueduCoreText 0.13.0 已發佈：提交 `278365c`、annotated tag `0.13.0`、GitHub Release。CHANGELOG 寫了上面列的全部項目；README 三種語言和 `docs/EngineIntegration.md` 的版本改成 0.13.0。發佈前跑了 `ReleaseMetadataTests`、`CorePackageBoundaryTests`（17 個全過）；整套 455＋49 個是 CHANGELOG 之前跑的，程式之後沒動。
     - App 套件要求改成 0.13.0（`upToNextMinorVersion`），`Package.resolved` 解析到 0.13.0（`278365c`）。
     - 舊引擎 `HTMLAttributedStringBuilder` 只對 `img` 套用 HTML 提示：0.12 只有 `img` 會產生提示，0.13 新增的清單 `type`、`font`、`hr` 提示是新引擎的，舊引擎照舊不吃；switch 補上新 case（不做事）。
     - VoiceOver：`BrowserLayoutPageView.accessibilityPageText` 改用 `DisplayList.spokenText`，段落範圍從 `BrowserTextInteractionController.paragraphRanges` 讀（分頁和捲動兩條路都會先綁定它再刷新）。
     - 第 11 節 App 那幾列：`sourceRange(at:)` 沒有文字互動時的命中、VoiceOver「選取文字」的起點都跳過長度 0 的項目（清單編號、`q` 的引號）；`ReaderScrollItem` 本來就濾掉長度 0；`ReaderViewportFragmentHost` 的高亮橫幅只看帶高亮屬性的字，編號沒有；`characterRect(at:)` 沒有呼叫者，沒動。
     - App 沒有對 `UnsupportedFeature`、`BorderStyle` 做完整 switch；只有測試自己建 fill／text 項目。
     - 測試目標的實驗性 Lexbor 前端用到 0.12 的單一 `ComputedStyle.borderColor` 和舊的 `applyPresentationalHints` 簽名：加了四邊同色的 `uniformBorderColor`，傳 `rootFontSize`。
     - App 測試（上面列的 15 個類別，加上 `HTMLPresentationalHint*`、`BrowserScrollTileCellTests`、`BrowserReaderParityTests`、`BrowserLayoutEngineTests`、`BrowserLayoutSelectionContractTests`、`BrowserTextInteractionTests`、`BrowserViewportRegressionTests`、`BrowserMediaPronunciationParityTests`、`BrowserLayoutInlineFormattingContextCorpusTests`、`LexborComputedStyleCoverageTests`、`BrowserLayoutFragmentedDecorationTests`，iPhone 18 Pro Max／iOS 27.2）：415 個，11 個失敗。這 11 個在上一個提交（0.12.1）跑一模一樣的測試也失敗，16 條失敗訊息逐條相同，不是這次造成的：
       - `BrowserLayoutCapabilityScannerTests` 的 7 個：還在預期浮動和表格會被拒收，但 0.11 起兩者都收了。
       - `BrowserLayoutImageTests.inlineTallImageExpandsLineBoxNotClamped`、`LexborComputedStyleCoverageTests.unsupportedValuesRetainWinningEvidence`（`text-indent: -1em`）、`yuedu_appTests` 的 `htmlBuilderPreservesDecorativeBlockWithWhitespaceContent`、`coreTextPageViewRendersBackgroundImagePixels`。
       - 沒有預期值要照 WebKit 重定。新加的 `BrowserLayoutPageEngineTests.browserPageReadsListNumbersAndParagraphsToVoiceOver`（VoiceOver 唸「1. Apple\n2. Banana\nPear\nEnd.」，原文是「AppleBananaPearEnd.」，「選取文字」從第一個有原文的字開始）通過。
     - App 提交 `252aedff`（未推送）。
   - **2026-11-04 進度：0.13.1、0.13.2**
     - 0.13.1（`c53ce67`）：行框和行首行尾的空白照 WebKit 量、照 WebKit 放（細節在它的 CHANGELOG）。重量基線語料，比的是 0.12 的同一份基線：
       - base 語料 FAIL，只有 redchamber-vertical −1.2；
       - 其餘進步：georgia +8.6、harry-potter +2.1、hongwu +1.5、sherlock +2.2；
       - pub PASS：correspondent +9.2、strangers +6.4；
       - gaps PASS：s001b +10.1、s001c +10.4、s001d +13.2。
     - redchamber-vertical 退步的根因有兩個，都是 0.13.1 造成的：
       - `line-height: normal` 的行內元素吃到所屬區塊的行高。spine 92 的 `sup` 把欄撐到 33.87，WebKit 是 28.26。
       - 直排、`normal` 的區塊拿字級當欄寬。
     - 0.13.2（`1d91ce2`）修掉這兩個，另外照 S001h、S001i 的實測改了兩處：Times／Helvetica 上方的 15% 改成無條件進位；Hiragino 用自己的下緣。
     - 0.13.2 重量，比的仍是 0.12 那份基線：
       - base PASS（297 章）：redchamber-vertical +5.3、georgia +8.6、sherlock +2.2、harry-potter +2.1、hongwu +1.5；最大的退步是 israelsailing −0.4。
       - pub PASS（96 章）：correspondent +9.2、strangers +6.4、deep-work +1.4。
       - gaps PASS（28 章）：s001b +10.1、s001c +10.4、s001d +13.2、s001g +1.4。
     - App 的套件要求改成 0.13.2（`Package.resolved` 解析到 `1d91ce2`）。`CoreTextWritingModeTests`、`AozoraStylesheetGeometryTests`、`AozoraEngineParityTests` 30 個全過（iOS 26.5）。
     - 一起提交的探針：
       - fixture S001c–S001l；
       - `ListMarkerProbeTests`、`scripts/fidelity/list_probe.sh`。只量位置，不計分，`oracle.lock` 不涵蓋。
10. **S001 候選**（另一件事）：清單符號上線後，再處理 `refs/archive/fidelity-S001-attempt3`。

## 14. 決策（2026-11-03，使用者選定）

1. **只讓 VoiceOver 唸有序清單的編號。**
   - 引擎提供一個函式，把頁面的原文和符號組成朗讀文字，宿主直接拿來用、不自己拼。原文位置不變。
   - 「有序」指非符號類的計數樣式：數字、字母、羅馬數字、中文。唸的時候去掉後綴的空白，例如「1.」「一、」。圓點不唸。
   - 聽書不唸：聽書的同步高亮照原文範圍對，插入沒有原文的字會打亂同步；而且每條註腳都唸「一、」只是雜音。
   - 舊引擎兩個都會唸，新引擎目前兩個都不唸。這個決定讓 VoiceOver 使用者在換引擎的章節裡不會少聽到編號。
   - 實作第 7 步時發現新引擎的 VoiceOver 文字段落之間沒有分隔，使用者選定同一個函式一起修（第 13 節第 7 步）。App 改用的時間點選定在第 9 步升版時一起改，因為 main 是多個 session 共用的，提前改會讓它們的建置找不到這個函式。
2. **直排這一輪一起做**（第 10 節）。原本推薦先回退舊引擎；改成一起做之後，回退條件只剩 `inside`。
