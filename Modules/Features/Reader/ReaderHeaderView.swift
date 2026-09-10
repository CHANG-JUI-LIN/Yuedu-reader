import SwiftUI

// MARK: - Header Fields

/// Info fields the reader header (頁眉) can display. `allCases` order is the
/// rendering order when several fields share one position.
enum ReaderHeaderField: String, CaseIterable, Identifiable {
    case bookTitle
    case chapterTitle
    case page
    case progress
    case time
    case battery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bookTitle: return localized("書名")
        case .chapterTitle: return localized("章節名")
        case .page: return localized("頁碼")
        case .progress: return localized("進度")
        case .time: return localized("時間")
        case .battery: return localized("電量")
        }
    }
}

/// Where a header field sits. Every field independently picks a slot, so all
/// of them can be stacked into the same slot (e.g. everything centered).
enum ReaderHeaderFieldPosition: String, CaseIterable, Identifiable {
    case hidden
    case left
    case center
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hidden: return localized("隱藏")
        case .left: return localized("靠左")
        case .center: return localized("置中")
        case .right: return localized("靠右")
        }
    }
}

enum ReaderHeaderLayout {
    static let defaultFieldPositions: [String: String] = [
        ReaderHeaderField.chapterTitle.rawValue: ReaderHeaderFieldPosition.left.rawValue
    ]

    static func fields(
        at position: ReaderHeaderFieldPosition,
        in positions: [String: String]
    ) -> [ReaderHeaderField] {
        ReaderHeaderField.allCases.filter { field in
            let raw = positions[field.rawValue] ?? ""
            return (ReaderHeaderFieldPosition(rawValue: raw) ?? .hidden) == position
        }
    }
}

// `ReaderOverlayHeader` and `ReaderView.topHeader` lived here. Both are gone:
// 頁眉／頁腳 are drawn by `ReaderBarRenderer` now — into the page in 翻頁 mode and
// as one fixed overlay in 捲動 mode. What is left in this file is the *legacy
// layout model*, which is still live: `ReaderLayoutPresetImporter` and
// `GlobalSettings` read it to migrate old exported presets into `ReaderBarLayout`.
