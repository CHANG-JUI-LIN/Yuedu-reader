#if DEBUG
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct ReaderDebugLayoutABTests {
    @Test("DEBUG EPUB layout A/B switch rebuilds the effective engine")
    func switchesLegacyBrowserForcedLegacy() async throws {
        defer { BrowserLayoutFeature.mode = .legacy }
        BrowserLayoutFeature.mode = .legacy

        let fixture = EPUBTestFixtures.proseSmoke()
        let url = try await EPUBTestFixtures.makeArchive(entries: fixture.entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let renderer = EPUBPageRenderer()
        let size = CGSize(width: 390, height: 844)
        let settings = ReaderRenderSettings(
            theme: "paper",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 12,
            marginV: 12,
            footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )

        renderer.load(
            publicationSession: session,
            bookIdentifier: url.standardizedFileURL.path,
            renderSize: size,
            settings: settings
        )
        renderer.engine?.cancelPendingWork(cause: .engineModeSwitch)
        #expect(renderer.debugEffectiveLayoutEngine == .legacy)

        #expect(renderer.debugReloadPublication(
            mode: .browserForced,
            renderSize: size,
            settings: settings
        ))
        renderer.engine?.cancelPendingWork(cause: .engineModeSwitch)
        #expect(renderer.engine is BrowserLayoutPageEngine)
        #expect(renderer.debugEffectiveLayoutEngine == .browserForced)

        #expect(renderer.debugReloadPublication(
            mode: .legacy,
            renderSize: size,
            settings: settings
        ))
        renderer.engine?.cancelPendingWork(cause: .engineModeSwitch)
        #expect(renderer.engine is CoreTextPageEngine)
        #expect(renderer.debugEffectiveLayoutEngine == .legacy)
    }

    @Test("DEBUG A/B labels expose only Legacy and BrowserForced")
    func exposesTheTwoAcceptanceModes() {
        #expect(ReaderDebugLayoutEngine.allCases == [.legacy, .browserForced])
        #expect(ReaderDebugLayoutEngine.legacy.featureMode == .legacy)
        #expect(ReaderDebugLayoutEngine.browserForced.featureMode == .browserForced)
    }
}
#endif
