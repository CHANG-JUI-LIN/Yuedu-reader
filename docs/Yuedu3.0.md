---
title: Yuedu 下一代架構：統一探索、刮削與模組系統
date: 2026-10-08
tags:
  - Yuedu
  - 閱讀器
  - 產品設計
  - 系統架構
  - Metadata
  - Discovery
  - Module-System
status: 構想與架構規劃
---

# Yuedu 下一代架構：Unified Library & Discovery

> **核心願景：將 Emby 的媒體庫與封面牆體驗、Forward 的模組化系統，以及小幻閱讀的書籍刮削能力結合，打造以「作品」為中心的開放式閱讀平台。**

GitHub：https://github.com/CHANG-JUI-LIN/Yuedu-reader

## 1. 背景：目前 Yuedu 的根本問題

### 1.1 應用功能割裂

目前 Yuedu 已經支援：

- 本地 EPUB、TXT 等書籍
- WebDAV
- OPDS
- Calibre
- 自訂網路書源
- 公有電子書庫

但是各功能相對獨立，缺乏統一的書籍發現與管理架構。

例如目前 WebDAV、OPDS、Calibre 的操作流程：

`匯入 → 選擇來源 → 開啟獨立 Sheet → 瀏覽書籍 → 匯入`

這三個功能雖然使用不同協定，但本質上都是**可供使用者探索的書籍集合**，不應完全被定義成匯入工具。

### 1.2 探索頁的設計問題

目前正在實作的方案：

- 沒有自訂書源時，顯示公有電子書庫。
- 已經新增書源時，顯示書源內容。
- 使用者需要手動切換公有書庫與自訂書源。

這個方案能避免探索頁空白，但治標不治本。

**公有書庫、私人遠端書庫、網路書源本來就不應互斥。**

### 1.3 搜尋功能割裂

目前搜尋主要圍繞網路書源。

理想情況下，使用者搜尋一本書時，不需要知道書籍存在於哪一個來源。

搜尋應該覆蓋：

- 本地書庫
- WebDAV
- OPDS
- Calibre
- 公有電子書庫
- 自訂網路書源
- 書籍 Metadata 資料庫

---

## 2. 產品願景

### 2.1 參考產品

**Emby / Jellyfin**

借鑑：

- 統一媒體庫
- 自動 Metadata 刮削
- 精美封面牆
- 統一作品詳情
- 跨來源搜尋
- 作品分類與聚合
- 個人化推薦

**Forward / Rex**

借鑑：

- JavaScript Widget 模組架構
- 模組安裝與更新
- 每個模組宣告自己的能力
- 列表、搜尋、詳情、資源取得相互分離
- 第三方開發者擴充生態

**小幻閱讀（Rodel Reader）**

借鑑：

- 獨立書籍 Metadata 刮削器
- 起點、番茄、晉江等網文資訊匹配
- 將本地 EPUB 與線上作品關聯
- 選擇刮削結果及更新欄位
- 自動補齊封面、簡介、作者、標籤

小幻閱讀的段落評論功能不是 Yuedu 現階段重點。

### 2.2 Yuedu 的定位

從：

**本地閱讀器 + 網文閱讀器 + 遠端書庫匯入工具**

轉變為：

**統一作品管理 + 多來源內容探索 + 可擴充模組生態的開放閱讀平台。**

這不代表必須建立小說內容平台，也不代表需要自行託管大量正版小說正文。

---

## 3. 統一探索首頁（Unified Discovery）

### 3.1 核心原則

探索頁不再代表某一個特定書源。

它是一個由不同資料提供者共同組成的內容首頁。

例如：

```text
Discover
│
├── 繼續閱讀
│   └── Local Library
│
├── 為你推薦
│   └── Recommendation Engine
│
├── 英文經典
│   └── Project Gutenberg
│
├── 日本文學
│   └── 青空文庫
│
├── 熱門網路小說
│   └── Discovery Provider
│
├── 我的 Calibre 書庫
│   └── Calibre Provider
│
├── 私人 WebDAV
│   └── WebDAV Provider
│
└── 自訂推薦欄目
    └── Third-party Modules
```

### 3.2 預設體驗

即使使用者：

- 沒有新增書源
- 沒有設定 WebDAV
- 沒有 Calibre
- 沒有匯入任何書籍

探索首頁依然可以顯示公有領域文學作品，並提供合法的免費下載。

使用者加入新來源後，首頁自動增加可選內容欄目，而不是切換成另一套介面。

### 3.3 首頁模組化

使用者可以：

- 啟用或停用首頁欄目
- 調整欄目順序
- 選擇指定資料來源
- 自訂分類與推薦
- 安裝第三方 Discovery 模組

首頁的內容應由標準化的 `HomeSection` 模型驅動，而不是為每個書源單獨建立 UI。

---

## 4. 統一來源架構（Collection Provider）

### 4.1 重新定位現有功能

| 來源 | 原有定位 | 新定位 |
|---|---|---|
| WebDAV | 匯入工具 | 遠端書籍集合 |
| OPDS | 匯入工具 | 線上圖書目錄 |
| Calibre | 匯入工具 | 個人數位圖書館 |
| Gutenberg | 公有書庫 | 公開探索模組 |
| 青空文庫 | 公有書庫 | 公開探索模組 |
| 網路書源 | 線上閱讀入口 | 搜尋與閱讀來源 |

### 4.2 CollectionProvider

建立統一集合抽象：

```swift
protocol CollectionProvider {
    var id: String { get }
    var capabilities: Set<CollectionCapability> { get }

    func browse(
        path: String?,
        cursor: String?
    ) async throws -> CollectionPage
}
```

不同 Provider 不需要具備完全相同的能力。

例如：

- WebDAV：資料夾、檔案瀏覽、下載。
- OPDS：目錄、作品資訊、搜尋、取得連結（依來源支援）。
- Calibre：作者、分類、搜尋、封面、下載。
- Gutenberg：書籍目錄、推薦、Metadata、下載。

### 4.3 技術原則

**保留現有通訊實作，重構上層資料介面。**

不要重新開發已經正常運作的 WebDAV、OPDS、Calibre 網路功能。

優先以 Adapter 包裝既有程式，再讓所有來源共用統一的探索 UI。

同時區分：

- Provider Type：WebDAV、OPDS 等來源種類。
- Source Instance：使用者實際建立的連線，例如 NAS A、Calibre B。

---

## 5. Forward 式模組系統（YueduModules）

### 5.1 核心設計

不再將所有能力強制綁定到「小說書源」。

一個模組可以提供一種或多種 Capability。

| Capability | 職責 |
|---|---|
| Catalog | 瀏覽書籍集合 |
| Discovery | 首頁推薦、排行榜、新書 |
| Metadata | 封面、簡介、作者、分類等 |
| Search | 搜尋作品 |
| BookSource | 取得網路小說目錄與正文 |
| Acquisition | 下載、取得或匯入書籍 |
| Sync | 遠端資料同步 |

例如：

**Gutenberg Module**

- Catalog
- Discovery
- Metadata
- Search
- Acquisition

**Qidian Metadata Module**

- Metadata
- Search
- Discovery（可選）

**Calibre Module**

- Catalog
- Search
- Metadata
- Acquisition

### 5.2 模組與 UI 分離

第三方模組只需要返回符合 Yuedu 規範的資料。

Yuedu 自行負責：

- 首頁渲染
- 搜尋結果
- 作品詳情
- 封面牆
- 下載操作
- 快取與錯誤處理

### 5.3 模組實作方式

研究兩種方向：

1. 宣告式 JSON 規則：HTTP、JSONPath、CSS Selector、OPDS 等。
2. 受限制的 JavaScript 模組：參考 Forward Widget。

iOS App Store 對動態下載與執行程式碼存在審核限制，因此不能直接假設 Forward 的整套 JavaScript 執行模式能照搬。

模組需要網路權限控制、隔離、逾時限制、版本管理及錯誤回退。

---

## 6. 書籍 Metadata 刮削系統

### 6.1 核心結論

**書籍內容來源（BookSource）與 Metadata 來源必須分離。**

使用者即使從普通 EPUB、TXT 或網路書源取得作品，也應能透過另一個 MetadataProvider 補齊書籍資料。

### 6.2 可研究的 Metadata 來源

**一般出版書籍**

- Open Library
- Google Books
- Wikidata
- 日本國立國會圖書館書目資料

**網路小說**

- 起點中文網
- 番茄小說
- 晉江文學城
- 其他網文平台

**輕小說與日本作品**

- Bangumi
- 其他合法可用書目資料庫

### 6.3 起點和番茄的實作可行性

此次討論的重要結論：

起點和番茄的公開作品頁面包含：

- 書名
- 作者
- 封面
- 簡介
- 分類與標籤
- 作品 ID
- 字數
- 連載狀態

因此，可以研究不依賴官方合作 API 的 Metadata 解析方法。

候選技術：

- 公開 HTML 解析
- 已授權或允許使用的結構化資料接口
- 第三方 Metadata 服務

**但可從公開網頁取得資料，不代表自動擁有商業重用、批量採集和封面再分發權利。**

需要另外驗證平台條款、授權範圍、接口穩定性。

閱文的正式開放 API 需商務合作，不適合作為 Yuedu 初期唯一的可行方案。

### 6.4 刮削流程

```text
匯入 EPUB / TXT
       ↓
解析原始 Metadata
       ↓
Metadata Coordinator
       ↓
搜尋不同 Metadata Provider
       ↓
收集候選作品
       ↓
作品名稱 / 作者 / 作品 ID 匹配
       ↓
選擇最佳結果
       ↓
補齊封面、簡介、分類等
       ↓
寫入統一作品資料庫
```

支援自動匹配，也必須保留人工選擇和修改能力。

不要直接、不可逆地覆蓋 EPUB 原始 Metadata。

### 6.5 暫時不研究段評

小幻閱讀聲稱能將本地 EPUB 與起點、番茄段評關聯。

但其具體資料取得方式尚未確認。

Yuedu 現階段不需要：

- 起點付費章節取得
- 帳號池
- 段評接口逆向
- 複雜段落匹配
- 段評同步

重點是 **Metadata + Discovery**，而不是複製所有網文閱讀器功能。

---

## 7. 統一作品模型（Unified Book Model）

這是整套架構最重要的底層設計。

**書籍作品應成為第一級實體，來源只是存取方式。**

例如：

```text
Work: 三體
│
├── Edition
│   ├── 簡體中文版
│   └── 繁體中文版
│
├── Metadata
│   ├── 書名
│   ├── 作者
│   ├── 封面
│   ├── 簡介
│   └── 分類
│
└── Source Records
    ├── Local EPUB
    ├── WebDAV
    ├── Calibre
    ├── OPDS
    └── 網路書源
```

建議至少區分：

- `Work`：抽象作品。
- `Edition`：版本、語言、譯本。
- `SourceRecord`：不同來源對該作品的記錄。
- `Acquisition`：具體取得或閱讀方式。
- `MetadataRecord`：元資料及其來源、可信度。

注意：

- 同名作品不一定是同一部書。
- 譯本、修訂版、漫畫改編不能盲目合併。
- 每個 Metadata 欄位最好保留來源和人工覆蓋記錄。
- 去重需要可信度評估，不能只靠書名。

---

## 8. 統一搜尋（Unified Search）

### 8.1 目標

搜尋體驗參考 Emby。

使用者搜尋「三體」，應該看到一個統一作品結果，而不是分別搜尋 Calibre、WebDAV、OPDS 和網路書源。

### 8.2 搜尋範圍

- 本地書籍
- 已建立索引的 WebDAV 書籍
- Calibre 書庫
- OPDS 目錄
- Gutenberg、青空文庫
- 使用者配置的網路書源
- Metadata Provider
- 作者、系列、分類

### 8.3 UnifiedSearchCoordinator

搜尋採取兩階段：

**第一階段：本地搜尋**

優先從本地索引查詢，快速顯示結果。

**第二階段：遠端搜尋**

非同步向支援 Search Capability 的 Provider 發出請求。

再經過：

`Identity Resolution → Deduplication → Ranking → Unified Results`

需要：

- Debounce
- 並發控制
- 遠端逾時
- 快取
- 分頁
- 來源錯誤隔離
- 搜尋範圍與隱私控制

仍然保留「來源內搜尋」，但全域搜尋不再依賴某個特定書源。

---

## 9. 統一作品詳情頁

無論從哪裡打開一本書，使用者都應進入同一種作品詳情頁。

包含：

- 封面
- 書名與作者
- 作品簡介
- 分類與標籤
- 作品系列
- 版本資訊
- 可用來源
- 下載與閱讀
- 相關作品

例如：

```text
《三體》
劉慈欣

科幻 / 小說

[開始閱讀]

可用來源：
✓ 本地 EPUB（已下載）
  我的 Calibre（可下載）
  私人 WebDAV（可取得）
  網路書源 A（可閱讀）

相關作品：
三體 II
三體 III
```

要特別區分：

- 加入書庫
- 下載檔案
- 線上閱讀
- 查看作品資料

這些不是同一種操作。

作品被探索到，不代表使用者一定有權閱讀或下載。

---

## 10. Yuedu 的整體架構

```text
                  Yuedu UI
                     │
        ┌────────────┼────────────┐
        │            │            │
      Library      Discover     Search
        │            │            │
        └────────────┼────────────┘
                     │
           Unified Book Model
                     │
        ┌────────────┼────────────┐
        │            │            │
   Collection     Metadata     Discovery
    Providers     Providers    Providers
        │            │            │
   WebDAV         Open Library  Gutenberg
   OPDS           Google Books  青空文庫
   Calibre        起點          網文排行榜
   BookSource     番茄          自訂模組
        │            │            │
        └────────────┼────────────┘
                     │
               Module Runtime
                     │
           Cache / Storage / Auth
```

此圖是概念性關係，不代表 Module Runtime 必須位於所有內建 Provider 的底層。內建 Swift Provider 與第三方模組可以共享能力協定，但使用不同執行機制。

---

## 11. 建議的開發階段

### Phase 1：統一資料模型

優先級：最高

- 定義 Work、Edition、SourceRecord。
- 建立來源 ID 映射。
- 保留既有書庫資料與閱讀紀錄。
- 制定去重、匹配和 Metadata 合併策略。

### Phase 2：CollectionProvider

優先級：最高

- 抽象現有 WebDAV、OPDS、Calibre。
- 保留目前通訊、認證與下載邏輯。
- 讓三種來源使用統一瀏覽模型。
- 將 Gutenberg、青空文庫納入同一體系。

### Phase 3：MetadataProvider

優先級：高

- 定義 MetadataProvider 協定。
- 接入 Open Library。
- 研究起點、番茄的 Metadata 原型。
- 完成作品搜尋、匹配與手動修改。

### Phase 4：Unified Search

優先級：高

- 建立本地搜尋索引。
- 實作跨來源搜尋協調。
- 合併相同作品。
- 保留來源內搜尋能力。

### Phase 5：Discovery Home

優先級：高

- 統一首頁內容模型。
- 支援多來源推薦欄目。
- 支援使用者自訂欄目。
- 不再使用公有書庫與書源二選一方案。

### Phase 6：YueduModules

優先級：中高

- Capability Protocol
- 模組 Manifest
- 模組安裝與更新
- 受限執行環境
- 模組權限與錯誤隔離
- 第三方開發文件

### Phase 7：進階推薦

優先級：後期

- 作者作品集
- 系列作品
- 相關作品
- 個人化推薦
- 跨來源分類
- 更完整的作品探索

---

## 12. 技術風險與待驗證事項

### 元資料取得

- 起點、番茄的公開頁面解析穩定性。
- 是否存在允許第三方使用的正式資料接口。
- 封面、簡介與榜單資料的授權。
- 刮削失敗後的降級處理。

### iOS 模組系統

- App Store 對第三方 JavaScript 模組的限制。
- 任意網路請求權限。
- 安全隔離與資源消耗。
- 模組版本相容性。

### 資料與效能

- WebDAV 大量檔案索引的性能。
- 跨來源作品去重的準確率。
- 多個 Metadata 來源互相衝突。
- 多個遠端書源的網路延遲。
- 私人書庫的隱私保護。
- 離線快取與資料更新。

### 架構相容性

- 不破壞既有書庫。
- 不丟失閱讀進度和使用者設定。
- 不將本次重構與 EPUB 排版引擎工程耦合。
- 支援漸進式遷移，避免全面重寫。

---

## 13. 目前確立的方向

1. 探索頁是聚合首頁，不是單一書源瀏覽器。
2. WebDAV、OPDS、Calibre 都屬於可探索的書籍集合。
3. 公有圖書館是預設內容提供者，不應與自訂書源互斥。
4. MetadataProvider 與 BookSource 必須獨立。
5. 搜尋應以作品為中心，跨來源聚合。
6. 同一部作品可以對應多個來源與版本。
7. 模組系統參考 Forward 的 Capability 設計。
8. 作品詳情 UI 應統一，不因來源改變。
9. 起點、番茄先研究 Metadata，不處理段評與付費正文。
10. 優先改造資料架構，再全面重構 UI。
11. 現有 WebDAV、OPDS、Calibre 實作應盡可能重用。
12. 模組系統需要兼顧可擴充性、資料授權及 App Store 合規性。

## 14. 下一步

**目前最應該完成的是現有 Yuedu 專案架構審計，而不是直接開始編寫整個新系統。**

審計範圍：

- 目前 Library 資料模型
- WebDAV / OPDS / Calibre 具體實作
- 公有書庫架構
- 現有網路書源解析機制
- 搜尋邏輯
- 探索頁與匯入 Sheet
- 書籍 Metadata 儲存方式
- 閱讀進度和書籍識別方式

審計後先制定資料模型和遷移計畫，再開始分階段實作。

最小可行驗證應能做到：

**同一個搜尋框搜尋本地書庫、Calibre、OPDS 和一個網文 Metadata 來源，並將同一部作品合併成統一詳情頁。**

完成這個驗證，才代表新架構真正建立起來。

---

## 核心總結

> Emby 定義使用者體驗，Forward 提供模組化思路，小幻閱讀提供書籍刮削的產品參考。
>
> **Yuedu 的核心不再是書源，而是作品。**
>
> 書源負責提供內容，刮削器負責提供 Metadata，Discovery 模組負責發現作品，CollectionProvider 負責瀏覽書籍集合。
>
> Yuedu 則負責將所有內容整合成一套連貫的閱讀體驗。

**專案暫定名稱：Yuedu Unified Library & Discovery Architecture**
