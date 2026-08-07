# 閱讀器記憶體面優化設計（純數字調整，不動架構）

> 日期：2026-08-07
> 決策脈絡：`Technotes/ReaderArchitectureDecision-2026-08-07.md` §5 之後，使用者決定**不動架構、只優化效能**，且在測量優先與低風險路線之間選了「**只做記憶體面＋純數字調整**」。
> 目標症狀（使用者回報）：**舊機特別明顯、發熱明顯**——典型記憶體壓力 → 反覆回收 → CPU 升高的循環。

## 1. 目標與非目標

**目標**：降低舊機（<4GB 記憶體）的常駐記憶體壓力，縮短 memory warning 後的回收時間，且**不改任何架構結構**——不引入新協調器、不刪 refresh transactions、不改變頁面生命週期。

**非目標**：
- 不動 `CoreTextPagedView.Coordinator`、`ReaderNavigator`、`ReaderSessionCoordinator`、`EPUBPageRenderer.refresh` 的責任邊界
- 不調 `windowRadius`/三槽視窗（那是 8/5 已實機失敗的架構路線）
- 不優化 CPU/繪製路徑（`draw(_:)`、圖片 decode、preload 並行度）——那是另一輪
- 不改 scroll engine 的常駐策略（`EPUBPageRenderer` 同時建立 paged＋scroll 是架構層決定）

## 2. 四項改動

### 2.1 snapshot cache 依裝置等級分級

**位置**：`Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift:112-119`

現況：

```swift
let budget = min(max(physicalMemory / 20, 64 * 1024 * 1024), 256 * 1024 * 1024)
cache.totalCostLimit = Int(budget)
cache.countLimit = 12
```

問題：
- `64MB` 下限對 3GB/4GB 舊機過高（3x 螢幕一張 snapshot ≈ 10-12MB，64MB ≈ 5-6 張）
- countLimit 12 = 6 章的 snapshots（每章 2 張）

改為：

```swift
let budget: Int
let countLimit: Int
switch physicalMemory {
case ..<(4 * 1024 * 1024 * 1024):   // < 4GB 舊機（XR/11/SE 2）
    budget = 16 * 1024 * 1024
    countLimit = 4
case ..<(6 * 1024 * 1024 * 1024):   // 4-6GB
    budget = 32 * 1024 * 1024
    countLimit = 6
default:                             // ≥ 6GB（含 iPad）
    budget = min(max(physicalMemory / 20, 64 * 1024 * 1024), 128 * 1024 * 1024)
    countLimit = 12
}
```

注意：
- **不歸零 snapshots**——curl/cover 動畫的跨章 handoff 依賴它們；全清會破壞動畫（`ReaderRenderRefresh` 之外的另一條視覺路徑）。舊機 count 4 = 目前章±1 的首末頁，剛好覆蓋相鄰章節動畫。
- ≥6GB 上限從 256MB 降到 128MB：snapshot 對 iPad 的價值低於記憶體成本，且 countLimit 12 已限制張數，兩者取低者生效。

### 2.2 LayoutCache capacity 8→5

**位置**：`Modules/Core/ReaderCore/CoreText/LayoutCache.swift:24`（`init(capacity: Int = 8)`）

理由：
- jump 只 preload ±1（`ReaderView+Logic.swift:100-101`），warmUpNext 只到下一章——實際需要 cur±2（含邊界）已非常寬裕
- 每章 layout 帶整章 attributed string＋page ranges，8 章是最大的非快取常駐塊
- distance-LRU 保留的是「距離 current 最近」的章，capacity 5 完全覆蓋實際使用模式

改動：`init(capacity: Int = 5)`。

### 2.3 LayoutCache 新增 `trim(keeping:)`＋memory warning 使用

**位置**：
- `Modules/Core/ReaderCore/CoreText/LayoutCache.swift` 新增方法
- `Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift:171-182`（memory warning handler）

新增方法：

```swift
/// Keeps only chapters within `radius` of the current chapter; drops the rest.
/// Used under memory pressure — a layout rebuild on return is cheaper than
/// dying in the background. No-op when there is nothing to drop.
func trim(keeping radius: Int) {
    guard storage.count > (radius * 2 + 1) else { return }
    storage = storage.filter { abs($0.key - currentChapter) <= radius }
}
```

memory warning handler 加一行（在現有 `chapterSnapshots.removeAllObjects()` 之後）：

```swift
self?._layouts.trim(keeping: 0)
```

即只保留目前章 layout；翻回上一章會重新 paginate（幾百 ms，可接受）——保命優先於快取。`trim(keeping: 0)` 後 `storage.count` 通常仍 > (0*2+1)=1（因為只留目前章），filter 後剩 1 章，符合預期。

### 2.4 DEBUG-only footprint helper（新檔）

**新檔**：`Modules/Core/ReaderCore/CoreText/MemoryFootprint.swift`

```swift
import Foundation
import Darwin

enum MemoryFootprint {
    /// Physical footprint of this process in bytes (`task_vm_info.phys_footprint`).
    /// DEBUG/diagnostics only — reading it on every page turn has a cost.
    static func current() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), p, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
    }

    /// Logs footprint in MB via AppLogger (render channel), e.g. "⟐ MEM footprint=123.4MB".
    static func log(_ context: String) {
        #if DEBUG
        let bytes = current()
        guard bytes >= 0 else { return }
        AppLogger.render("⟐ MEM \(context) footprint=\(String(format: "%.1f", Double(bytes) / 1_000_000))MB")
        #endif
    }
}
```

使用點（僅 DEBUG 生效，release 零成本）：
- memory warning handler 前後各打一次：`MemoryFootprint.log("warning-before")` / `MemoryFootprint.log("warning-after")`
- 連續翻頁 10 頁後打一次（驗證 snapshot/layout 累積）

> 注意：`AppLogger.render` 是既有 render 頻道（CoreTextPagedView 大量使用 `⟐` 前綴），沿用同一風格。

## 3. 驗證

### 3.1 編譯

```bash
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### 3.2 既有測試

- `ReaderRenderRefreshTests`（動到 engine cache 相關）
- `ReaderViewModelChapterStateTests`（fetch 相關，確保未破壞）

### 3.3 實機/模擬 footprint 對比

固定一本書、固定動作（開書 → 翻 20 頁 → 換 3 章 → 觸發 memory warning 或直接看 log）：

| 指標 | 改動前 | 改動後 |
|---|---|---|
| 開書後 footprint | （記錄） | （記錄） |
| 翻 20 頁後 footprint | （記錄） | （記錄） |
| memory warning 後回收量 | （記錄） | （記錄） |

- 模擬器：`xcrun simctl spawn <udid> notifyutil -p com.apple.UIKit.didReceiveMemoryWarning` 或 Instruments 手動觸發
- 真機：低記憶體舊機（iPhone XR/11）最佳

## 4. 風險

| 風險 | 影響 | 緩解 |
|---|---|---|
| snapshot count 4 太緊，curl/cover 動畫缺圖 | 視覺回退 | 舊機先測 curl 跨章；若缺圖升到 count 6（24MB 預算內仍可） |
| `trim(keeping: 0)` 後翻回上一章重新 paginate 慢 | 體驗下降 | 只發生在 memory warning 後（非常態）；幾百 ms 可接受 |
| `task_info` 在模擬器回傳異常 | log 不輸出 | `guard kr == KERN_SUCCESS` 靜默失敗，不影響主路徑 |
| 改 capacity 影響測試假設 | 測試失敗 | 跑 LayoutCache/engine 相關測試確認 |

## 5. 回滾

四項互相獨立：
- 2.1：revert `CoreTextPageEngine.swift` snapshot 常量
- 2.2：revert `LayoutCache.swift` 預設值
- 2.3：revert `trim(keeping:)` 與 warning handler 的一行
- 2.4：刪 `MemoryFootprint.swift` 與呼叫點

無需整輪回退。
