import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// What the reader's text and bars keep clear of. A folded iPhone Duo reports an 84pt safe area
/// down its whole right side for a camera housing that covers only the top 82pt of it; the text
/// below runs the full width, as a page of 微信讀書 does, and only the 頁眉 beside the camera
/// keeps clear (maintainer's choice, 2026-10-27).
@Suite("Reader window obstructions", .serialized)
struct ReaderWindowObstructionsTests {

    /// Measured on the iPhone Duo simulator, iOS 27.1, folded, status bar hidden.
    private static let foldedDuo = ReaderWindowObstructions(
        windowWidth: 466,
        windowHeight: 678,
        sideSafeArea: ReaderSideInsets(left: 0, right: 84),
        occlusions: [
            CGRect(x: 382, y: 0, width: 84, height: 82),
            CGRect(x: 399.67, y: 29.33, width: 37, height: 37),
        ]
    )

    @Test func foldedDuoTextRunsFullWidthBelowTheCameraHousing() {
        #expect(Self.foldedDuo.sideInsets(across: 96...640) == .zero)
    }

    @Test func foldedDuoHeaderBesideTheCameraKeepsClear() {
        #expect(Self.foldedDuo.sideInsets(across: 66...84) == ReaderSideInsets(left: 0, right: 84))
    }

    /// Text that runs up to the top of the screen — scroll mode with the 頁眉 off — passes
    /// under the housing, so it keeps the whole safe area.
    @Test func foldedDuoTextReachingTheHousingKeepsClear() {
        #expect(Self.foldedDuo.sideInsets(across: 0...640) == ReaderSideInsets(left: 0, right: 84))
    }

    @Test func foldedDuoFooterRunsFullWidth() {
        #expect(Self.foldedDuo.sideInsets(across: 630...648) == .zero)
    }

    /// iPhone landscape: the Dynamic Island sits halfway down a side, never in a corner, so it
    /// is not a housing and nothing changes from the safe area — even taking its frame, margins
    /// included, to reach the edge and fill the inset. (Not measured: the simulator runs iOS
    /// 27.1 only on the iPhone Duo.)
    @Test func iPhoneLandscapeKeepsItsSafeArea() {
        let landscape = ReaderWindowObstructions(
            windowWidth: 932,
            windowHeight: 430,
            sideSafeArea: ReaderSideInsets(left: 59, right: 59),
            occlusions: [CGRect(x: 0, y: 140, width: 59, height: 150)]
        )
        #expect(landscape.sideInsets(across: 300...400) == ReaderSideInsets(left: 59, right: 59))
        #expect(landscape.sideInsets(across: 20...40) == ReaderSideInsets(left: 59, right: 59))
    }

    /// The folded Duo turned over: the housing is in the bottom-left corner, and the text above
    /// it, clear of it, runs the full width.
    @Test func foldedDuoUpsideDownClearsTheBottomCorner() {
        let turned = ReaderWindowObstructions(
            windowWidth: 466,
            windowHeight: 678,
            sideSafeArea: ReaderSideInsets(left: 84, right: 0),
            occlusions: [CGRect(x: 0, y: 596, width: 84, height: 82)]
        )
        #expect(turned.sideInsets(across: 40...580) == .zero)
        #expect(turned.sideInsets(across: 600...640) == ReaderSideInsets(left: 84, right: 0))
    }

    /// Before iOS 27.1 nothing is reported but the safe area, which is kept as it is.
    @Test func withoutReportedRegionsTheSafeAreaStands() {
        var duo = Self.foldedDuo
        duo.occlusions = []
        #expect(duo.sideInsets(across: 96...640) == ReaderSideInsets(left: 0, right: 84))
    }

    @Test func spreadPagesClearTheFold() {
        let open = ReaderWindowObstructions(
            windowWidth: 900,
            windowHeight: 678,
            folds: [CGRect(x: 444, y: 0, width: 12, height: 678)]
        )
        #expect(open.hasVerticalFold)
        // Two 450pt pages meeting at a mid spine: the left page ends at the fold's left edge,
        // the right page starts at its right edge.
        let insets = open.spreadPageInsets(across: 96...640, pageWidth: 450, gutter: 0)
        #expect(insets == ReaderSideInsets(left: 6, right: 6))
    }

    @Test func spreadPagesKeepTheWindowsSafeAreaWhereItIsWider() {
        let open = ReaderWindowObstructions(
            windowWidth: 900,
            windowHeight: 678,
            sideSafeArea: ReaderSideInsets(left: 20, right: 0),
            folds: [CGRect(x: 448, y: 0, width: 4, height: 678)]
        )
        let insets = open.spreadPageInsets(across: 96...640, pageWidth: 450, gutter: 0)
        #expect(insets == ReaderSideInsets(left: 20, right: 2))
    }

    @Test func aFoldAcrossTheScreenIsNotASpine() {
        let laptop = ReaderWindowObstructions(
            windowWidth: 900,
            windowHeight: 678,
            folds: [CGRect(x: 0, y: 330, width: 900, height: 12)]
        )
        #expect(!laptop.hasVerticalFold)
        #expect(laptop.spreadPageInsets(across: 96...640, pageWidth: 450, gutter: 0) == .zero)
    }

    // MARK: The reporter

    /// The reporter reads SwiftUI's regions, which are in the reader root's own space; the
    /// reader's surfaces draw from the window's corner. Whatever the window itself reports
    /// through UIKit, the reporter must hand on in the same place.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func reporterHandsOnTheWindowsOwnRegions() async throws {
        let host = try ObstructionsHost()
        defer { host.tearDown() }
        let reported = await host.firstReport()
        host.layout()
        let latest = host.latest ?? reported

        #expect(latest.windowWidth == host.window.bounds.width)
        #expect(latest.windowHeight == host.window.bounds.height)
        let safeArea = host.window.safeAreaInsets
        #expect(latest.sideSafeArea == ReaderSideInsets(left: safeArea.left, right: safeArea.right))
        guard #available(iOS 27.1, *) else { return }
        let occlusions = host.window.reservedRegions(kind: .occlusion).map(\.frame)
        let folds = host.window.reservedRegions(kind: .division, options: .includeInactive).map(\.frame)
        #expect(Self.same(latest.occlusions, occlusions), "reported \(latest.occlusions), window \(occlusions)")
        #expect(Self.same(latest.folds, folds), "reported \(latest.folds), window \(folds)")
    }

    /// A reader pushed into a tab: the tab keeps its tab bar's side after the reader hides the
    /// bar (an open iPhone Duo in landscape, 84pt on the right). The container's inset stands
    /// in for it here; the reader still keeps clear of only what the window does.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func reporterKeepsToTheWindowNotItsContainer() async throws {
        let host = try ObstructionsHost(containerRightInset: 84)
        defer { host.tearDown() }
        let reported = await host.firstReport()
        host.layout()
        let latest = host.latest ?? reported

        let safeArea = host.window.safeAreaInsets
        #expect(host.hostedSafeArea.right == safeArea.right + 84, "the container's inset reaches the reader's view")
        #expect(latest.sideSafeArea == ReaderSideInsets(left: safeArea.left, right: safeArea.right))
    }

    private static func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        guard a.count == b.count else { return false }
        return b.allSatisfy { rect in
            a.contains {
                abs($0.minX - rect.minX) < 0.5 && abs($0.minY - rect.minY) < 0.5
                    && abs($0.width - rect.width) < 0.5 && abs($0.height - rect.height) < 0.5
            }
        }
    }
}

/// A reader-shaped root in a real window of the test host's scene, with the modifiers
/// `ReaderView` carries. `containerRightInset` is what a container adds to the reader's safe
/// area on the right, as a tab does for its hidden tab bar.
@MainActor
private final class ObstructionsHost {
    let window: UIWindow
    private let controller: UIHostingController<AnyView>
    private let readerWindow: ReaderWindowReference
    private(set) var latest: ReaderWindowObstructions?
    private var waiter: ((ReaderWindowObstructions) -> Void)?

    var hostedSafeArea: UIEdgeInsets { controller.view.safeAreaInsets }

    init(containerRightInset: CGFloat = 0) throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { throw HostError.noScene }
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let reference = ReaderWindowReference()
        readerWindow = reference
        var sink: ((ReaderWindowObstructions) -> Void)?
        controller = UIHostingController(rootView: AnyView(
            Color.clear.reportsReaderWindowObstructions(in: reference) { sink?($0) }
        ))
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: containerRightInset)
        sink = { [weak self] in self?.record($0) }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// Awaits the callback itself; a view that never reports leaves the test to its time limit.
    func firstReport() async -> ReaderWindowObstructions {
        if let latest { return latest }
        return await withCheckedContinuation { continuation in
            waiter = { continuation.resume(returning: $0) }
        }
    }

    func layout() {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func record(_ obstructions: ReaderWindowObstructions) {
        latest = obstructions
        if let waiter {
            self.waiter = nil
            waiter(obstructions)
        }
    }

    enum HostError: Error { case noScene }
}
