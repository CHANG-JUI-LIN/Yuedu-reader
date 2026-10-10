import Foundation

/// The events legado-E and MD3 hand a book source's `ruleContent.callBackJs` (as `event`), with
/// the same names, so a source written for them branches the same way here (`SourceCallBack`).
enum SourceCallBackEvent: String, CaseIterable, Sendable {
    // Taps the source may take over. The script returning `true` means it handled the tap;
    // anything else and the app does what it does without a source script.
    case clickAuthor
    case longClickAuthor
    case clickBookName
    case longClickBookName
    case clickCustomButton
    case longClickCustomButton
    case clickShareBook
    case clickClearCache
    case clickCopyBookUrl
    case clickCopyTocUrl
    case clickCopyPlayUrl
    case clickBookLabel
    case longClickBookLabel

    // Notifications: the app does not wait for, or look at, the answer.
    case addBookShelf
    case delBookShelf
    case saveRead
    case startRead
    case endRead
    case startShelfRefresh
    case endShelfRefresh

    /// A tap the script may take over (legado `callBackBtn`), as opposed to a notification
    /// (`callBackBook` / `callBackSource`).
    var isInteractive: Bool {
        switch self {
        case .addBookShelf, .delBookShelf, .saveRead, .startRead, .endRead,
             .startShelfRefresh, .endShelfRefresh:
            return false
        default:
            return true
        }
    }
}
