import Foundation

// MARK: - Grid Touch Zone Actions
enum TouchAction: String, CaseIterable, Codable {
    case prevPage = "上一頁"
    case nextPage = "下一頁"
    case toggleMenu = "選單"
    case none = "無動作"
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
struct TouchZoneConfig: Codable {
    var zones: [TouchAction]  // Always 9 elements

    static let `default` = TouchZoneConfig(zones: [
        .prevPage, .prevPage, .nextPage,  // Top row: TL←, TC←, TR→
        .prevPage, .toggleMenu, .nextPage,  // Middle row: ML←, MC menu, MR→
        .prevPage, .nextPage, .nextPage,  // Bottom row: BL←, BC→, BR→
    ])

    /// Persistence key
    private static let key = "yd_touch_zones"

    static func load() -> TouchZoneConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
            let config = try? JSONDecoder().decode(TouchZoneConfig.self, from: data),
            config.zones.count == 9
        else { return .default }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Returns the action for a given normalized touch position (0~1, 0~1)
    func action(at point: CGPoint, in size: CGSize) -> TouchAction {
        let col = min(2, Int(point.x / size.width * 3))
        let row = min(2, Int(point.y / size.height * 3))
        let idx = row * 3 + col
        return zones[idx]
    }
}
