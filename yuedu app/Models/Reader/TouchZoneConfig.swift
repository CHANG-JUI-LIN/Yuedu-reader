import Foundation

// MARK: - 九宮格觸控區域動作
enum TouchAction: String, CaseIterable, Codable {
    case prevPage = "上一頁"
    case nextPage = "下一頁"
    case toggleMenu = "選單"
    case none = "無動作"
}

// MARK: - 九宮格觸控配置

/// 3×3 九宮格：index 0-8 由左上到右下
/// ┌───────┬────────┬───────┐
/// │ 0 左上 │ 1 中上 │ 2 右上 │
/// ├───────┼────────┼───────┤
/// │ 3 左中 │ 4 正中 │ 5 右中 │
/// ├───────┼────────┼───────┤
/// │ 6 左下 │ 7 中下 │ 8 右下 │
/// └───────┴────────┴───────┘
struct TouchZoneConfig: Codable {
    var zones: [TouchAction]  // 恆為 9 個元素

    static let `default` = TouchZoneConfig(zones: [
        .prevPage, .prevPage, .nextPage,  // 上排：左上←, 中上←, 右上→
        .prevPage, .toggleMenu, .nextPage,  // 中排：左中←, 正中選單, 右中→
        .prevPage, .nextPage, .nextPage,  // 下排：左下←, 中下→, 右下→
    ])

    /// 持久化 key
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

    /// 根據觸控位置比例（0~1, 0~1）回傳動作
    func action(at point: CGPoint, in size: CGSize) -> TouchAction {
        let col = min(2, Int(point.x / size.width * 3))
        let row = min(2, Int(point.y / size.height * 3))
        let idx = row * 3 + col
        return zones[idx]
    }
}
