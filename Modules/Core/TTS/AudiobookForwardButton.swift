import Foundation

/// What the audiobook player's right-hand transport button does (feedback #170): forward
/// 15 seconds, as it always has, or on to the next chapter as a music player's does. One
/// choice for every book, kept on this device. The lock screen's right-hand button follows
/// it (`AudiobookPlayer.applyForwardButton`).
enum AudiobookForwardButton: String, CaseIterable, Hashable {
    case skipForward15
    case nextChapter

    static let storageKey = "yd_audiobook_forward_button"

    /// The choice as last saved; 快轉 15 秒 until someone picks the other.
    static func saved(in defaults: UserDefaults = .standard) -> AudiobookForwardButton {
        defaults.string(forKey: storageKey).flatMap(AudiobookForwardButton.init(rawValue:)) ?? .skipForward15
    }

    var localizedTitle: String {
        switch self {
        case .skipForward15: localized("快轉 15 秒")
        case .nextChapter: localized("下一章")
        }
    }

    var systemImage: String {
        switch self {
        case .skipForward15: "goforward.15"
        case .nextChapter: "forward.end"
        }
    }
}
