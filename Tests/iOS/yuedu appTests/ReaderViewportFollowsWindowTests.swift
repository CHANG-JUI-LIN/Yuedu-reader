import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The reader used to size itself from `UIScreen.main.bounds`, and refreshed that only on a
/// device rotation. On an iPad window that is not the screen (Stage Manager, Split View) it
/// laid the text out for the whole screen and drew it squeezed into the window; opening the
/// book in a 375-pt window printed `renderSize=(820.0, 1180.0)`. These tests pin the two ends
/// of the fix: the view reports its *own* window size every time it changes, and the engine
/// waits for that size instead of starting at the screen's.
@Suite("Reader viewport follows its own window", .serialized)
struct ReaderViewportFollowsWindowTests {

    // MARK: The renderer waits for the view's size

    @Test(.timeLimit(.minutes(1))) @MainActor
    func reflowableStartWaitsForTheViewToReportItsSize() async throws {
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            text: "第1章 一\n" + String(repeating: "窗口尺寸測試。", count: 200),
            title: "Viewport",
            bookIdentifier: UUID().uuidString,
            renderSize: .zero,
            settings: EPUBTestFixtures.renderSettings()
        )
        let engine = try #require(renderer.engine)

        // A view that has not been laid out yet has no size to lay out for: the start is held.
        #expect(renderer.isCoreTextReady == false)

        let window = CGSize(width: 360, height: 800)
        renderer.notifyViewportSize(window)
        for await ready in renderer.$isCoreTextReady.values where ready { break }

        #expect(engine.renderSize == window, "the first layout must be for the window, not UIScreen")
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func layoutRefreshBeforeTheViewHasASizeLeavesTheEngineForTheDeferredStart() async throws {
        let renderer = EPUBPageRenderer()
        let settings = EPUBTestFixtures.renderSettings()
        renderer.loadTXT(
            text: "第1章 一\n" + String(repeating: "窗口尺寸測試。", count: 200),
            title: "Viewport",
            bookIdentifier: UUID().uuidString,
            renderSize: .zero,
            settings: settings
        )
        let engine = try #require(renderer.engine)

        // Something asks for a layout in the same pass that opened the reader, before the first
        // size arrives (a settings change, the spread mode settling). With nothing to lay out at,
        // it must not run: `invalidateLayout(newSize: .zero)` would leave the engine at zero.
        let early = await renderer.refresh(ReaderRenderRefreshRequest(
            intent: .layout,
            mode: .paged,
            settings: settings,
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: 0),
            viewportSize: .zero
        ))
        #expect(early.isCompleted)
        #expect(engine.renderSize == .zero)

        let window = CGSize(width: 360, height: 800)
        renderer.notifyViewportSize(window)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        #expect(engine.renderSize == window)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func fixedLayoutStartWaitsForTheViewToReportItsSize() async throws {
        let url = try await FixedLayoutEPUBRendererTests.makeFixedLayoutEPUB(pageCount: 2)
        let session = try await PublicationSession.open(sourceURL: url)
        let renderer = EPUBPageRenderer()
        renderer.load(
            publicationSession: session,
            bookIdentifier: UUID().uuidString,
            renderSize: .zero,
            settings: EPUBTestFixtures.renderSettings()
        )
        let engine = try #require(renderer.engine)

        #expect(renderer.isCoreTextReady == false)

        let window = CGSize(width: 360, height: 800)
        renderer.notifyViewportSize(window)
        for await ready in renderer.$isCoreTextReady.values where ready { break }

        #expect(engine.renderSize == window)
    }

    // MARK: The view reports its own size

    @Test(.timeLimit(.minutes(1))) @MainActor
    func reporterFollowsTheWindowAcrossResizes() async throws {
        let host = try ViewportHost(window: CGSize(width: 400, height: 700))
        defer { host.tearDown() }

        await host.waitForReport(CGSize(width: 400, height: 700))

        // What Stage Manager, Split View and folding do: the same window, a new size. No
        // orientation change happens, so no device-orientation notification is posted.
        host.resize(to: CGSize(width: 300, height: 500))
        await host.waitForReport(CGSize(width: 300, height: 500))

        host.resize(to: CGSize(width: 500, height: 900))
        await host.waitForReport(CGSize(width: 500, height: 900))

        // A rotation is the same thing with the two sides swapped.
        host.resize(to: CGSize(width: 900, height: 500))
        await host.waitForReport(CGSize(width: 900, height: 500))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func reporterReportsTheWholeWindowNotTheSafeAreaRectangle() async throws {
        let host = try ViewportHost(
            window: CGSize(width: 400, height: 700),
            additionalSafeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        )
        defer { host.tearDown() }

        // SwiftUI proposes 400×607 to content here; the reader's engines subtract the bars'
        // insets themselves, so the viewport has to stay the window.
        await host.waitForReport(CGSize(width: 400, height: 700))
    }

    @Test func windowSizeAddsTheInsetsBack() {
        let size = ReaderViewportMetrics.windowSize(
            containerSize: CGSize(width: 375, height: 689),
            safeAreaInsets: EdgeInsets(top: 116, leading: 0, bottom: 10, trailing: 0)
        )
        #expect(size == CGSize(width: 375, height: 815))
    }
}

/// A reader-shaped root in a real window of the test host's scene, with the same modifier
/// `ReaderView` carries.
@MainActor
private final class ViewportHost {
    private let window: UIWindow
    private let controller: UIHostingController<AnyView>
    private var reports: [CGSize] = []
    private var waiter: (expected: CGSize, resume: () -> Void)?

    init(window size: CGSize, additionalSafeArea: UIEdgeInsets = .zero) throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { throw HostError.noScene }
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        // The box is built before `self` is usable, so the callback goes through a weak hop.
        var sink: ((CGSize) -> Void)?
        controller = UIHostingController(rootView: AnyView(
            Color.clear.reportsReaderViewport { sink?($0) }
        ))
        controller.additionalSafeAreaInsets = additionalSafeArea
        sink = { [weak self] in self?.record($0) }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    func resize(to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    /// Returns once the callback has delivered `expected`. It awaits the callback itself — no
    /// polling, no delay — so a view that never reports leaves the test to its time limit.
    func waitForReport(_ expected: CGSize) async {
        if reports.last == expected { return }
        await withCheckedContinuation { continuation in
            waiter = (expected, { continuation.resume() })
        }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func record(_ size: CGSize) {
        reports.append(size)
        if let waiter, waiter.expected == size {
            self.waiter = nil
            waiter.resume()
        }
    }

    enum HostError: Error { case noScene }
}
