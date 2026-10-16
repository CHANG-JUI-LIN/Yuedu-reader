import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct ReaderScrollDiagnosticsTests {
    @Test @MainActor func observerMountsAndReleasesWithScrollView() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let scroll = UIScrollView()
        controller.view = scroll
        var observer: ReaderScrollFrameDiagnostics? = ReaderScrollFrameDiagnostics(scrollView: scroll)
        weak let releasedObserver = observer
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        observer = nil
        #expect(releasedObserver == nil, "update actions must not keep their observer alive")
        window.isHidden = true
        window.rootViewController = nil
    }

    @Test func activeCadenceKeepsDeadlineAndIdleGapsSeparate() throws {
        var timeline = ReaderScrollFrameTimeline()
        func sample(_ time: Double, active: Bool = true, y: Double = 0) -> ReaderScrollFrameSample? {
            timeline.sample(active: active, model: time, presentation: time + 0.016,
                started: time, completed: time + 0.003, deadline: time + 0.008, offset: y)
        }
        #expect(try #require(sample(10)).modelDelta == 0)
        let next = try #require(sample(10 + 1.0 / 120, y: 2))
        #expect(abs(next.modelDelta - 1.0 / 120) < 0.000001)
        #expect(abs(next.deadlineSlack - 0.005) < 0.000001)
        #expect(next.offsetDelta == 2)
        #expect(sample(11, active: false) == nil)
        #expect(try #require(sample(20)).modelDelta == 0, "idle time must not be reported as a scroll stall")
        let reverse = try #require(sample(20 + 1.0 / 60, y: -3))
        #expect(abs(reverse.presentationDelta - 1.0 / 60) < 0.000001)
        #expect(reverse.offsetDelta == -3)
        let lateSample = timeline.sample(active: true, model: 21, presentation: 21.016,
            started: 21, completed: 21.02, deadline: 21.008, offset: -5)
        let late = try #require(lateSample)
        #expect(late.deadlineSlack < 0 && abs(late.updateDuration - 0.02) < 0.000001)
    }
}
