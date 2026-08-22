import Foundation

/// Visibility rules for reader customization surfaces that should not be
/// discoverable until the single Yuedu Pro entitlement is active.
struct ReaderPremiumVisibilityPolicy {
    let isProActive: Bool

    var showsReaderDecoration: Bool { isProActive }
    var showsBottomTabCustomization: Bool { isProActive }
    var showsBackgroundImageImport: Bool { isProActive }
    var showsLayoutPresetImport: Bool { isProActive }
    var showsTouchZoneEditor: Bool { isProActive }

    /// 新增／編輯段落筆記。**只鎖入口**：已經寫過的筆記，圓圈照常畫、內容照常讀得到，
    /// 過期只是不能再改——和專案其他 Pro 功能一樣，不動使用者已經產生的資料。
    var allowsParagraphNoteEditing: Bool { isProActive }

    func showsCommentBubbleSettings(hasParagraphReviews: Bool) -> Bool {
        isProActive && hasParagraphReviews
    }
}
