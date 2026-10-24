import Foundation

/// A book-scoped action offered by the reader chrome — refresh the chapter, change
/// source, download, 來源配置登入, AI 助手, 翻譯, 開啟網頁. Which ones apply depends on
/// the book (a local EPUB gets no download), so `ReaderView` builds the lists once: the
/// book card behind the cover thumbnail renders `readerSecondaryActions`, and 更多 in the
/// bottom bar renders `readerMoreActions` (the AI ones).
struct ReaderSecondaryAction: Identifiable {
    enum ID: String {
        case download
        case changeSource
        case refresh
        case aiAssistant
        case translation
        case openWebPage
        /// The book source's own button (legado `customButton`), whose tap goes to its
        /// `callBackJs` as `clickCustomButton`. Not a chrome customization item: it exists
        /// only for a source that asks for it.
        case sourceCustomButton
        /// 來源配置登入, for a source that has a login. Not a chrome customization item
        /// either: like the source's own button, it is there only when the source asks.
        case sourceLogin
    }

    let id: ID
    let icon: String
    let label: String
    /// Needs Yuedu Pro the reader does not have (AI 助手, 翻譯): shown marked, and `action`
    /// opens the paywall instead.
    let isLocked: Bool
    let action: () -> Void

    init(id: ID, icon: String, label: String, isLocked: Bool = false, action: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.label = label
        self.isLocked = isLocked
        self.action = action
    }
}

/// What the 現代 book-card popover was asked to open.
///
/// Every one of these opens a sheet, and iOS drops a sheet requested while the popover
/// it came from is still dismissing — 聽書, when the card still had it, was the visible
/// casualty: the card slid back into the cover thumbnail and no TTS panel ever appeared. So the tap records the route
/// here and `ReaderView` opens it from the popover's real dismissal, never in the same
/// turn as `showModernBookCard = false`.
enum ReaderModernBookCardRoute: Hashable {
    case secondary(ReaderSecondaryAction.ID)
    case bookDetail
    /// 搜尋書籍. Not a `ReaderSecondaryAction`: the card offers it for every book, so it
    /// stays out of the list the book-scoped actions share and out of 自定義's show/hide
    /// roster.
    case search
}

/// What the reader quick panel asked to open after it closes.
///
/// Both destinations are sheets, and iOS drops a sheet requested while the sheet
/// it came from is still dismissing. Recording the request and running it from the
/// panel's real `onDismiss` is the contract in
/// `Technotes/iOS17MenuModalPresentation.md`.
enum ReaderQuickPanelRoute: Hashable {
    case settings
    /// A locked control in the panel (導入圖片背景 without Pro).
    case paywall(PremiumFeature)
}
