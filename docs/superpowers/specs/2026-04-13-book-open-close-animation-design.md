# 開書／關書動畫 設計文件

**日期**：2026-04-13  
**狀態**：已核准

---

## 目標

使用者在書架點擊書籍時，閱讀器從該書籍列表格子的位置縮放展開到全螢幕；關閉閱讀器時，閱讀器縮小收回到該書籍在書架上的位置。

---

## 架構

### 替換 fullScreenCover

移除 `HomeView` 現有的 `.fullScreenCover`，改在最外層包一個 `ZStack`：

```
ZStack {
    NavigationView { ... }   // 書架（底層）
    if readerBookId != nil {
        BookReaderOverlay(...)  // 閱讀器覆蓋層（最上層）
    }
}
```

### 新增 State

`HomeView` 新增三個 state：

| State | 型別 | 用途 |
|-------|------|------|
| `readerBookId` | `UUID?` | 現有，目前哪本書在閱讀器中 |
| `selectedBookFrame` | `CGRect` | 被點擊書籍的全域螢幕座標 |
| `isReaderExpanded` | `Bool` | 驅動展開/收合動畫（false=縮小狀態，true=全螢幕） |

---

## Frame 追蹤

### PreferenceKey

新增 `BookFramePreferenceKey: PreferenceKey`，value 型別為 `[UUID: CGRect]`：

```swift
struct BookFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
```

### BookRow 回報 frame

在 `BookRow` 的 `.background` 中放 `GeometryReader`，讀取 `.global` 座標系的 frame 並透過 preference 往上傳：

```swift
.background(GeometryReader { geo in
    Color.clear.preference(
        key: BookFramePreferenceKey.self,
        value: [book.id: geo.frame(in: .global)]
    )
})
```

### HomeView 收集 frames

```swift
.onPreferenceChange(BookFramePreferenceKey.self) { frames in
    bookFrames = frames
}
```

點擊書籍時：
```swift
selectedBookFrame = bookFrames[book.id] ?? UIScreen.main.bounds
readerBookId = book.id
// 下一個 runloop 觸發展開動畫
DispatchQueue.main.async {
    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
        isReaderExpanded = true
    }
}
```

---

## 動畫細節

### BookReaderOverlay

一個輕量包裝 view，負責：
1. 根據 `isExpanded` 計算 `scaleEffect` 與 `offset`
2. 用 `clipShape(RoundedRectangle(cornerRadius:))` 動畫 corner radius（8 → 0）
3. 在底層鋪一個黑色半透明背景，與展開同步從 opacity 0 → 1

計算邏輯（在 `GeometryReader` 取得螢幕尺寸後）：

```
let screenSize = proxy.size
let scaleX = sourceFrame.width  / screenSize.width
let scaleY = sourceFrame.height / screenSize.height
let offsetX = sourceFrame.midX - screenSize.width  / 2
let offsetY = sourceFrame.midY - screenSize.height / 2
```

`isExpanded = false` 時套用 `scaleEffect(CGSize(width: scaleX, height: scaleY)).offset(x: offsetX, y: offsetY)`；`isExpanded = true` 時兩者都為預設值（scale=1, offset=0）。

動畫曲線：`.spring(response: 0.45, dampingFraction: 0.82)`

### 關閉動畫

`BookReaderOverlay` 接收 `onClose: () -> Void` callback，傳給內部的 `ReaderView`（替換現有的 `presentationMode.dismiss()`）。

`HomeView` 提供的 closure：
```swift
onClose: {
    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
        isReaderExpanded = false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
        readerBookId = nil
    }
}
```

延遲 0.42 秒（略長於動畫 response）才清除 `readerBookId`，確保動畫播完再移除 view。

---

## ReaderView 改動

`ReaderView` 新增可選的 `onClose: (() -> Void)?` 參數（預設 `nil`）：

```swift
struct ReaderView: View {
    let bookId: UUID
    var onClose: (() -> Void)? = nil
    ...
}
```

所有呼叫 `presentationMode.wrappedValue.dismiss()` 的地方改為：

```swift
if let onClose { onClose() } else { presentationMode.wrappedValue.dismiss() }
```

保留 `presentationMode` fallback，確保 ReaderView 在其他地方直接 present 時仍可正常關閉。

---

## 修改清單

| 檔案 | 改動 |
|------|------|
| `Views/HomeView.swift` | 移除 fullScreenCover、加 ZStack + 3 個新 state、onPreferenceChange |
| `Views/HomeView.swift` `BookRow` | 加 background GeometryReader preference |
| `Views/HomeView.swift` | 新增 `BookFramePreferenceKey` |
| `Views/HomeView.swift` | 新增 `BookReaderOverlay` view（或同檔案私有）|
| `Views/ReaderView.swift` | 新增 `onClose` 參數，改寫 dismiss 呼叫 |

---

## 驗證

1. 點擊書架任意書籍 → 閱讀器從該書格子縮放展開，spring 動畫順暢
2. 在閱讀器點關閉 → 閱讀器縮回同一書籍在書架的位置
3. 捲動書架後再開另一本書 → frame 正確對應新書位置（不是舊位置）
4. 無書封面的書籍（色塊）同樣正常
5. 快速連續開關不崩潰（`isReaderExpanded` 狀態一致）
