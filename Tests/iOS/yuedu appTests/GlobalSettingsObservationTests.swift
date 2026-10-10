import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// `GlobalSettings` is `@Observable`: a view updates for the settings it reads. These pin
/// down both halves — an unrelated setting no longer redraws it, and the things that used to
/// rely on "any setting redraws every observer" (fonts drawn from `GlobalAppTypography`'s
/// statics) still reach it.
@Suite("GlobalSettings observation", .serialized)
@MainActor
struct GlobalSettingsObservationTests {
    final class Counter { var bodies = 0 }

    private struct ReadsColumnCount: View {
        let counter: Counter
        var body: some View {
            counter.bodies += 1
            return Text("\(GlobalSettings.shared.bookshelfGridColumnCount)")
        }
    }

    private struct UsesInterfaceFont: View {
        let counter: Counter
        var body: some View {
            counter.bodies += 1
            return Text("字").font(DSFont.body)
        }
    }

    private func settle(_ host: WindowHost) {
        RunLoop.main.run(until: Date())
        host.controller.view.layoutIfNeeded()
    }

    @Test("a view redraws for the setting it reads and not for another")
    func narrowsToReadSettings() throws {
        let settings = GlobalSettings.shared
        let previousColumns = settings.bookshelfGridColumnCount
        let previousBrightness = settings.readerBrightness
        defer {
            settings.bookshelfGridColumnCount = previousColumns
            settings.readerBrightness = previousBrightness
        }
        let counter = Counter()
        let host = try WindowHost(ReadsColumnCount(counter: counter))
        defer { host.tearDown() }
        settle(host)
        let afterMount = counter.bodies

        settings.readerBrightness = previousBrightness == 0.5 ? 0.6 : 0.5
        settle(host)
        #expect(counter.bodies == afterMount, "an unrelated setting redrew the view")

        settings.bookshelfGridColumnCount = previousColumns == 3 ? 4 : 3
        settle(host)
        #expect(counter.bodies > afterMount, "the setting the view reads did not redraw it")
    }

    @Test("a view drawing an interface font redraws when the font or Bold Text changes")
    func typographyReachesFontUsers() throws {
        let counter = Counter()
        let host = try WindowHost(UsesInterfaceFont(counter: counter))
        defer { host.tearDown() }
        settle(host)
        let afterMount = counter.bodies

        GlobalSettings.shared.typographyDidChange()
        settle(host)
        #expect(counter.bodies > afterMount)
    }
}
