import SwiftUI
import XCTest
@testable import yuedu_app

@MainActor
final class ReaderQuickThemePanelLayoutTests: XCTestCase {
    func testPresentedPanelDoesNotAddEmptySpaceBelowMeasuredContent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let appeared = expectation(description: "Quick panel finished presentation")
            var measuredHeight: CGFloat = 0
            let root = Color.gray.sheet(isPresented: .constant(true)) {
                ReaderQuickThemePanelView(
                    fontSize: .constant(18), readerTheme: .constant(.white),
                    pageTurnOption: .fastFade, isVerticalWritingMode: false,
                    onSelectPageTurnOption: { _ in }, onStartAutoRead: {}, onCustomize: {}
                )
                .environment(\.dynamicTypeSize, .large)
                .onPreferenceChange(ReaderQuickPanelContentHeightKey.self) { measuredHeight = $0 }
                .background(QuickPanelAppearanceProbe { appeared.fulfill() })
            }
            let host = UIHostingController(rootView: root)
            window.overrideUserInterfaceStyle = appearance
            window.rootViewController = host
            window.makeKeyAndVisible()
            await fulfillment(of: [appeared], timeout: 10)
            window.layoutIfNeeded()
            let sheet = try XCTUnwrap(host.presentedViewController)
            XCTAssertGreaterThan(measuredHeight, 0)
            XCTAssertEqual(sheet.view.bounds.height, measuredHeight, accuracy: 2,
                           "The sheet must fit its measured content; a second bottom safe area recreates the dead band")
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "quick-panel-\(appearance == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("QUICK_PANEL_LAYOUT content=\(measuredHeight) sheet=\(sheet.view.bounds.height) safeBottom=\(sheet.view.safeAreaInsets.bottom)")
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
    }
}

private struct QuickPanelAppearanceProbe: UIViewControllerRepresentable {
    let onAppear: () -> Void
    func makeUIViewController(context: Context) -> ProbeController {
        ProbeController(onAppear: onAppear)
    }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}

    final class ProbeController: UIViewController {
        let onAppear: () -> Void
        init(onAppear: @escaping () -> Void) {
            self.onAppear = onAppear
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear()
        }
    }
}
