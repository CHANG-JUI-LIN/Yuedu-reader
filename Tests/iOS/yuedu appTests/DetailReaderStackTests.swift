import Combine
import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

@MainActor
private final class DetailStackState: ObservableObject {
    @Published var path = NavigationPath()
    @Published var reader: DetailReaderRoute?
    @Published var showsDetail = false
    @Published var revision = 0
    var onAppear: (String, UUID?) -> Void = { _, _ in }
}

private struct StackAppearanceProbe: UIViewControllerRepresentable {
    let appeared: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(appeared: appeared) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.appeared = appeared }
    final class Controller: UIViewController {
        var appeared: () -> Void
        init(appeared: @escaping () -> Void) { self.appeared = appeared; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared() }
    }
}

private struct StackReaderFixture: View {
    @ObservedObject var state: DetailStackState
    @State private var identity = UUID()

    var body: some View {
        ReaderNavigationContainer {
            Text("Reader \(state.revision)")
                .background(StackAppearanceProbe { state.onAppear("reader", identity) }.frame(width: 0, height: 0))
                .onChange(of: state.revision) { _, _ in state.onAppear("refresh", identity) }
                .navigationDestination(isPresented: $state.showsDetail) {
                    Text("Reader detail")
                        .background(StackAppearanceProbe { state.onAppear("readerDetail", nil) }.frame(width: 0, height: 0))
                }
        }
    }
}

private struct DetailStackFixture: View {
    @ObservedObject var state: DetailStackState

    var body: some View {
        NavigationStack(path: $state.path) {
            Text("Explore")
                .background(StackAppearanceProbe { state.onAppear("explore", nil) }.frame(width: 0, height: 0))
                .navigationDestination(for: ExploreNavigationRoute.self) { _ in
                    Text("Book detail \(state.revision)")
                        .background(StackAppearanceProbe { state.onAppear("bookDetail", nil) }.frame(width: 0, height: 0))
                        .navigationDestination(item: $state.reader) { _ in
                            StackReaderFixture(state: state)
                                .environment(\.readerUsesParentNavigationStack, true)
                                .reservingNavigationBackSwipe()
                        }
                }
        }
    }
}

@MainActor
final class DetailReaderStackTests: XCTestCase {
    func testExploreReaderStaysOnSameStackThroughRefreshAndDetailRoundTrip() async throws {
        let state = DetailStackState()
        let host = UIHostingController(rootView: DetailStackFixture(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        var identities: [UUID] = []
        func awaitScreen(_ name: String, line: UInt = #line, action: () -> Void) async {
            let appeared = expectation(description: "\(name) at line \(line)")
            state.onAppear = { screen, identity in
                guard screen == name else { return }
                if let identity { identities.append(identity) }
                appeared.fulfill()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, action)
            await fulfillment(of: [appeared], timeout: 5)
        }
        await awaitScreen("explore") { window.makeKeyAndVisible() }
        await awaitScreen("bookDetail") { state.path.append(ExploreNavigationRoute.search("fixture")) }
        let bookID = UUID()
        await awaitScreen("reader") { state.reader = DetailReaderRoute(id: bookID) }
        let originalIdentity = try XCTUnwrap(identities.first)
        await awaitScreen("refresh") { state.revision += 1 }
        XCTAssertEqual(state.path.count, 1)
        XCTAssertEqual(state.reader?.id, bookID)
        XCTAssertEqual(identities.last, originalIdentity)
        XCTAssertEqual(navigationControllers(in: host).count, 1, "The pushed reader must not create a second SwiftUI NavigationStack")
        let nav = try XCTUnwrap(navigationControllers(in: host).first)
        XCTAssertEqual(nav.viewControllers.count, 3)
        let readerController = nav.topViewController
        XCTAssertTrue(NavigationBackSwipeReservationController.backGesture(in: nav)?.isEnabled == true)
        XCTAssertTrue(NavigationBackSwipeReservationController.backGesture(in: nav)?.delegate is NavigationBackSwipeReservationController)
        await awaitScreen("readerDetail") { state.showsDetail = true }
        XCTAssertEqual(nav.viewControllers.count, 4)
        XCTAssertFalse(NavigationBackSwipeReservationController.backGesture(in: nav)?.delegate is NavigationBackSwipeReservationController)
        await awaitScreen("reader") { state.showsDetail = false }
        XCTAssertEqual(identities.last, originalIdentity)
        XCTAssertTrue(nav.topViewController === readerController)
        XCTAssertTrue(NavigationBackSwipeReservationController.backGesture(in: nav)?.delegate is NavigationBackSwipeReservationController)
        await awaitScreen("bookDetail") { state.reader = nil }
        XCTAssertEqual(state.path.count, 1)
        await awaitScreen("reader") { state.reader = DetailReaderRoute(id: bookID) }
        XCTAssertNotEqual(identities.last, originalIdentity)
    }

    private func navigationControllers(in root: UIViewController) -> [UINavigationController] {
        ((root as? UINavigationController).map { [$0] } ?? []) + root.children.flatMap { navigationControllers(in: $0) }
    }
}
