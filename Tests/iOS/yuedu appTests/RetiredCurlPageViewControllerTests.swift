import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Crashlytics 658b2c27 / 1e94b6ec, "The number of view controllers provided (0) doesn't match
/// the number required (2)". In UIKit 27.2 `-[UIPageViewController _handlePanGesture:]` asks for
/// the curl's incoming pages again at `.began` and hands them to the transition unchecked, and
/// `_viewControllerBefore:viewController:` answers nil without asking the data source when
/// `_canHandleGestures` is false — which it is once the weak data source (the Coordinator) is
/// gone. Neither crash had a data-source breadcrumb at the throw, so the Coordinator was gone:
/// a page view controller SwiftUI is retiring (`.id(readerPageViewIdentity)` rebuild, a source
/// switch) let a curl pan that had already passed its begin check reach `.began`.
///
/// A retired controller must therefore take no more touches, and its built-in pans must be off:
/// disabling a recognizer cancels a recognition in flight synchronously.
@Suite("Retired curl page view controller", .serialized)
@MainActor
struct RetiredCurlPageViewControllerTests {
    @Test("dismantling the reader switches the curl's built-in gestures off")
    func dismantleDisablesBuiltInCurlGestures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: [String(repeating: "Reading page.\n", count: 80)]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.dataSource = coordinator
        pvc.delegate = coordinator
        pvc.setViewControllers(
            [engine.pageViewController(at: 0)],
            direction: .forward, animated: false
        )
        let builtIn = pvc.gestureRecognizers
        try #require(builtIn.contains { $0 is UIPanGestureRecognizer })
        try #require(builtIn.allSatisfy { $0.isEnabled })

        CoreTextPageEngineView.dismantleUIViewController(pvc, coordinator: coordinator)

        #expect(pvc.gestureRecognizers.allSatisfy { !$0.isEnabled })
        #expect(!pvc.view.isUserInteractionEnabled)
        // Deterministic, rather than whenever the Coordinator happens to be released.
        #expect(pvc.dataSource == nil)
        #expect(pvc.delegate == nil)
    }
}
