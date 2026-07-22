import Foundation

// MARK: - Grid Touch Zone Actions
enum TouchAction: String, CaseIterable, Codable, Equatable {
    case prevPage = "上一頁"
    case nextPage = "下一頁"
    case toggleMenu = "選單"
    case none = "無動作"
    case previousChapter = "上一章"
    case nextChapter = "下一章"
    case toggleBookmark = "添加/移除書籤"
    case tableOfContents = "目錄"
}

enum ReaderTouchCommand: Equatable {
    case none
    case toggleMenu
    case previousPage
    case nextPage
    case previousChapter
    case nextChapter
    case toggleBookmark
    case tableOfContents
}

extension TouchAction {
    static let editorCases: [TouchAction] = [
        .none, .toggleMenu, .prevPage, .nextPage,
        .previousChapter, .nextChapter, .toggleBookmark, .tableOfContents,
    ]

    var readerCommand: ReaderTouchCommand {
        switch self {
        case .none: return .none
        case .toggleMenu: return .toggleMenu
        case .prevPage: return .previousPage
        case .nextPage: return .nextPage
        case .previousChapter: return .previousChapter
        case .nextChapter: return .nextChapter
        case .toggleBookmark: return .toggleBookmark
        case .tableOfContents: return .tableOfContents
        }
    }
}

// MARK: - Grid Touch Configuration

/// 3x3 grid: indices 0-8 from top-left to bottom-right
/// ┌───────┬────────┬───────┐
/// │ 0 TL  │ 1 TC   │ 2 TR  │
/// ├───────┼────────┼───────┤
/// │ 3 ML  │ 4 MC   │ 5 MR  │
/// ├───────┼────────┼───────┤
/// │ 6 BL  │ 7 BC   │ 8 BR  │
/// └───────┴────────┴───────┘
struct TouchZoneConfig: Codable, Equatable {
    var zones: [TouchAction]  // Always 9 elements

    static let `default` = TouchZoneConfig(zones: [
        .prevPage, .prevPage, .nextPage,  // Top row: TL←, TC←, TR→
        .prevPage, .toggleMenu, .nextPage,  // Middle row: ML←, MC menu, MR→
        .prevPage, .nextPage, .nextPage,  // Bottom row: BL←, BC→, BR→
    ])

    static func defaultForReadingDirection(isRTL: Bool) -> TouchZoneConfig {
        guard isRTL else { return .default }
        return TouchZoneConfig(zones: stride(from: 0, to: 9, by: 3).flatMap { rowStart in
            Array(TouchZoneConfig.default.zones[rowStart..<(rowStart + 3)].reversed())
        })
    }

    /// Persistence key
    private static let key = "yd_touch_zones"

    static func loadSaved() -> TouchZoneConfig? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(TouchZoneConfig.self, from: data),
              config.zones.count == 9
        else { return nil }
        return config
    }

    static func load() -> TouchZoneConfig {
        loadSaved() ?? .default
    }

    static func effective(
        saved: TouchZoneConfig? = loadSaved(),
        isProActive: Bool,
        isRTL: Bool
    ) -> TouchZoneConfig {
        guard isProActive, let saved, saved.zones.count == 9 else {
            return defaultForReadingDirection(isRTL: isRTL)
        }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Returns the action for a given normalized touch position (0~1, 0~1)
    func action(at point: CGPoint, in size: CGSize) -> TouchAction {
        guard zones.count == 9,
              size.width > 0, size.height > 0,
              point.x >= 0, point.x <= size.width,
              point.y >= 0, point.y <= size.height else { return .none }
        let col = min(2, Int(point.x / size.width * 3))
        let row = min(2, Int(point.y / size.height * 3))
        let idx = row * 3 + col
        return zones[idx]
    }
}
