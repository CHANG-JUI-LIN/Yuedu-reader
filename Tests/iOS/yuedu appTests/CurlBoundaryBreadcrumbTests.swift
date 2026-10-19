import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Crashlytics c5efe011 / 658b2c27: "The number of view controllers provided (0) doesn't match
/// the number required (2)". UIKit (26.6–27.2) checks the curl pair's count when the built-in
/// pan asks to begin, then re-derives the direction in the pan's `.began` action and hands
/// whatever the data source answers straight to the transition, unchecked. A nil from the
/// curl data source there is the crash, so every nil it returns must leave a breadcrumb that
/// says which boundary it was and what the pan was doing.
@Suite("Curl boundary breadcrumbs", .serialized)
@MainActor
struct CurlBoundaryBreadcrumbTests {
    @Test("a curl page with no neighbour leaves a breadcrumb", arguments: [false, true])
    func curlNilNeighbourIsRecorded(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: [String(repeating: "Reading page.\n", count: 80)]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        try #require(engine.totalPages > 1)
        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: isRTL, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.isDoubleSided = true
        func forward(_ page: UIViewController) -> UIViewController? {
            isRTL ? coordinator.pageViewController(pvc, viewControllerBefore: page)
                  : coordinator.pageViewController(pvc, viewControllerAfter: page)
        }
        func backward(_ page: UIViewController) -> UIViewController? {
            isRTL ? coordinator.pageViewController(pvc, viewControllerAfter: page)
                  : coordinator.pageViewController(pvc, viewControllerBefore: page)
        }

        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        let last = engine.pageViewController(at: engine.totalPages - 1)
        #expect(forward(last) == nil)
        #expect(backward(engine.pageViewController(at: 0)) == nil)
        // A page that has neighbours both ways answers without a breadcrumb.
        #expect(forward(engine.pageViewController(at: 0)) != nil)

        let lines = DiagnosticLog.shared.snapshot()
            .filter { !before.contains($0.id) && $0.message.contains("curl no page") }
            .map(\.message)
        #expect(lines.count == 2, "\(lines)")
        let atEnd = try #require(lines.first { $0.contains("page=\(engine.totalPages - 1)") })
        #expect(atEnd.contains("total=\(engine.totalPages)"))
        #expect(atEnd.contains("rtl=\(isRTL ? 1 : 0)"))
        #expect(atEnd.contains("pan="))
        #expect(lines.contains { $0.contains("page=0") })
    }
}
