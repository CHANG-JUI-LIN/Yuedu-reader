import Foundation
import Testing
import CoreGraphics
@testable import yuedu_app

@Suite("Touch Zone Config")
struct TouchZoneConfigTests {
    @Test("all reader actions round-trip through Codable")
    func actionsRoundTrip() throws {
        let actions: [TouchAction] = [
            .none, .toggleMenu, .prevPage, .nextPage,
            .previousChapter, .nextChapter, .toggleBookmark, .tableOfContents,
        ]

        let data = try JSONEncoder().encode(actions)
        #expect(try JSONDecoder().decode([TouchAction].self, from: data) == actions)
    }

    @Test("nine cell centers resolve in row-major order")
    func cellCentersResolve() {
        let actions = Array(TouchAction.allCases.prefix(8)) + [.nextPage]
        let config = TouchZoneConfig(zones: actions)
        let size = CGSize(width: 300, height: 300)

        for index in 0..<9 {
            let row = index / 3
            let column = index % 3
            let point = CGPoint(x: CGFloat(column * 100 + 50), y: CGFloat(row * 100 + 50))
            #expect(config.action(at: point, in: size) == actions[index])
        }
    }

    @Test("invalid geometry and malformed grids are safe")
    func invalidInputsAreSafe() {
        let malformed = TouchZoneConfig(zones: [.nextPage])

        #expect(malformed.action(at: .zero, in: .zero) == .none)
        #expect(malformed.action(at: CGPoint(x: -20, y: 500), in: CGSize(width: 300, height: 300)) == .none)
    }

    @Test("free readers use defaults while Pro readers use their saved grid")
    func entitlementResolution() {
        let saved = TouchZoneConfig(zones: Array(repeating: .none, count: 9))

        #expect(TouchZoneConfig.effective(saved: saved, isProActive: false).zones == TouchZoneConfig.default.zones)
        #expect(TouchZoneConfig.effective(saved: saved, isProActive: true).zones == saved.zones)
    }
}
