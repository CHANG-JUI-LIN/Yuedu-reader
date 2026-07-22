import Foundation
import Testing

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

        #expect(TouchZoneConfig.effective(saved: saved, isProActive: false, isRTL: false) == .default)
        #expect(TouchZoneConfig.effective(saved: saved, isProActive: true, isRTL: true) == saved)
    }

    @Test("left-opening books mirror the unsaved default grid")
    func leftOpeningDefaultIsMirrored() {
        let ltr = TouchZoneConfig.defaultForReadingDirection(isRTL: false)
        let rtl = TouchZoneConfig.defaultForReadingDirection(isRTL: true)

        #expect(ltr == .default)
        #expect(rtl.zones == [
            .nextPage, .prevPage, .prevPage,
            .nextPage, .toggleMenu, .prevPage,
            .nextPage, .nextPage, .prevPage,
        ])
    }

    @Test("left-opening defaults apply until a Pro reader saves a custom grid")
    func directionalDefaultPrecedesCustomization() {
        let saved = TouchZoneConfig(zones: Array(repeating: .none, count: 9))
        let rtlDefault = TouchZoneConfig.defaultForReadingDirection(isRTL: true)

        #expect(TouchZoneConfig.effective(saved: nil, isProActive: true, isRTL: true) == rtlDefault)
        #expect(TouchZoneConfig.effective(saved: saved, isProActive: false, isRTL: true) == rtlDefault)
        #expect(TouchZoneConfig.effective(saved: saved, isProActive: true, isRTL: true) == saved)
    }

    @Test("left-opening and right-opening grids persist independently")
    func directionProfilesPersistIndependently() throws {
        let suiteName = "TouchZoneConfigTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ltr = TouchZoneConfig(zones: Array(repeating: .previousChapter, count: 9))
        let rtl = TouchZoneConfig(zones: Array(repeating: .nextChapter, count: 9))

        ltr.save(isRTL: false, defaults: defaults)
        rtl.save(isRTL: true, defaults: defaults)

        #expect(TouchZoneConfig.loadSaved(isRTL: false, defaults: defaults) == ltr)
        #expect(TouchZoneConfig.loadSaved(isRTL: true, defaults: defaults) == rtl)
    }
}
