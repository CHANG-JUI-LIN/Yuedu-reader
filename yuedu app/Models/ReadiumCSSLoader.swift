/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import Foundation

struct ReadiumCSSConfiguration: Equatable {
    let fontSize: String
    let lineHeight: String
    let theme: String
    let fontFamily: String?
    let colWidth: Int?
    let pageGutter: Int?
    let scroll: Bool

    init(
        fontSize: String = "100%",
        lineHeight: String = "1.5",
        theme: String = "readium-default-on",
        fontFamily: String? = nil,
        colWidth: Int? = nil,
        pageGutter: Int? = nil,
        scroll: Bool = false
    ) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.theme = theme
        self.fontFamily = fontFamily
        self.colWidth = colWidth
        self.pageGutter = pageGutter
        self.scroll = scroll
    }
}

struct ReadiumCSSBundle: Equatable {
    let htmlAttributes: String
    let beforeStyleTag: String
    let defaultStyleTag: String
    let afterStyleTag: String
}

/// 從 App Bundle 加載 Readium CSS 排版樣式表（CJK 橫排專用）。
///
/// Readium CSS 由三個層級組成（必須按「三明治」順序注入）：
/// 1. `ReadiumCSS-cjk-before.css` — 基礎重設（放在所有出版 CSS **之前**）
/// 2. 出版者原書 CSS（headContent + inlineBookCSS）
/// 3. `ReadiumCSS-cjk-default.css` — 預設排版規則（放在出版 CSS **之後**）
/// 4. `ReadiumCSS-cjk-after.css` — 使用者覆蓋 + 高優先級規則（最後注入）
enum ReadiumCSSLoader {

    // MARK: - 快取（只讀一次磁碟）

    private static var cache: (before: String, default_: String, after: String)?

    /// 取得完整的 Readium CSS（三個檔案），已快取。
    static func load() -> (before: String, default_: String, after: String) {
        if let cached = cache { return cached }

        let before = readCSS("ReadiumCSS-cjk-before")
        let default_ = readCSS("ReadiumCSS-cjk-default")
        let after = readCSS("ReadiumCSS-cjk-after")

        let result = (before: before, default_: default_, after: after)
        cache = result
        return result
    }

    static func bundle(configuration: ReadiumCSSConfiguration) -> ReadiumCSSBundle {
        ReadiumCSSBundle(
            htmlAttributes: htmlAttributes(configuration: configuration),
            beforeStyleTag: beforeCSS(),
            defaultStyleTag: defaultCSS(),
            afterStyleTag: afterCSS()
        )
    }

    /// 三明治第一層：before.css — 放在出版 CSS 之前
    static func beforeCSS() -> String {
        let css = load()
        return """
        <style data-readium-css="before">\(css.before)</style>
        """
    }

    /// 三明治第三層：default.css — 放在出版 CSS 之後
    static func defaultCSS() -> String {
        let css = load()
        return """
        <style data-readium-css="default">\(css.default_)</style>
        """
    }

    /// 三明治第四層：after.css — 最高優先級覆蓋
    static func afterCSS() -> String {
        let css = load()
        return """
        <style data-readium-css="after">\(css.after)</style>
        """
    }

    // MARK: - 向後兼容（保留舊名稱，內部轉發）

    /// 生成注入到 `<head>` 開頭的 CSS（before + default）
    @available(*, deprecated, message: "Use beforeCSS() + defaultCSS() for correct sandwich order")
    static func headCSS() -> String {
        return beforeCSS() + "
" + defaultCSS()
    }

    /// 生成注入到 `</head>` 之前的 CSS（after），覆蓋優先級最高
    @available(*, deprecated, message: "Use afterCSS()")
    static func tailCSS() -> String {
        return afterCSS()
    }

    /// Readium CSS 需要的 `<html>` 屬性，用來啟用使用者設定。
    /// - Parameters:
    ///   - fontSize: 使用者字體大小（百分比，如 "112%"）
    ///   - lineHeight: 行高倍數
    ///   - theme: 閱讀主題（readium-default-on / readium-night-on / readium-sepia-on）
    ///   - fontFamily: 使用者字體（可選）
    ///   - colWidth: 欄寬（像素），通常 = viewport 寬度
    ///   - pageGutter: 頁面左右邊距（像素）
    ///   - scroll: 是否為滾動模式（true → readium-scroll-on）
    static func htmlAttributes(
        fontSize: String = "100%",
        lineHeight: String = "1.5",
        theme: String = "readium-default-on",
        fontFamily: String? = nil,
        colWidth: Int? = nil,
        pageGutter: Int? = nil,
        scroll: Bool = false
    ) -> String {
        let viewMode = scroll ? "readium-scroll-on" : "readium-paged-on"
        var style = "--USER__view: \(viewMode)"
        style += "; --USER__fontSize: \(fontSize)"
        style += "; --USER__lineHeight: \(lineHeight)"
        style += "; --USER__appearance: \(theme)"
        if let font = fontFamily {
            style += "; --USER__fontFamily: \(font)"
        }
        if let w = colWidth {
            style += "; --RS__colWidth: \(w)px"
            style += "; --RS__colCount: 1"
            style += "; --RS__colGap: 0px"
        }
        if let g = pageGutter {
            style += "; --RS__pageGutter: \(g)px"
        }

        return """
        dir="ltr" style="\(style)" data-viewer-theme="\(theme)"
        """
    }

    static func htmlAttributes(configuration: ReadiumCSSConfiguration) -> String {
        htmlAttributes(
            fontSize: configuration.fontSize,
            lineHeight: configuration.lineHeight,
            theme: configuration.theme,
            fontFamily: configuration.fontFamily,
            colWidth: configuration.colWidth,
            pageGutter: configuration.pageGutter,
            scroll: configuration.scroll
        )
    }

    // MARK: - 磁碟讀取

    private static func readCSS(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "css") else {
            print("[ReadiumCSSLoader] ⚠️ 找不到 CSS 檔案: \(name).css")
            return ""
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            print("[ReadiumCSSLoader] ⚠️ 讀取失敗: \(name).css — \(error)")
            return ""
        }
    }
}
*/
