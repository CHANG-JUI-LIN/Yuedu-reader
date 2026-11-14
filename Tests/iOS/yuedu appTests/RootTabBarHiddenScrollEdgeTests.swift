import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// A sheet with a bar of its own at the bottom, opened from a page.
private struct PageWithSheet: View {
    var body: some View {
        Color.clear.sheet(isPresented: .constant(true)) {
            NavigationStack {
                List(0..<200, id: \.self) { Text(verbatim: "Row \($0)") }
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) { Button("完成") {} }
                    }
                    .softScrollEdges()
            }
        }
    }
}

@Suite("Hidden root tab bar and scroll edges", .serialized)
@MainActor
struct RootTabBarHiddenScrollEdgeTests {
    /// The bottom edge effect views under a view, as (alpha, description).
    private func bottomEdgeEffects(in view: UIView) -> [(alpha: CGFloat, description: String)] {
        var found: [(CGFloat, String)] = []
        func walk(_ view: UIView) {
            let description = String(describing: view)
            if String(describing: type(of: view)).contains("ScrollEdgeEffectView"), description.contains("edge = bottom") {
                found.append((view.alpha, description))
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.map { (alpha: $0.0, description: $0.1) }
    }

    private func sheetBottomEdgeAlphas(hidesTabBar: Bool) async throws -> [CGFloat] {
        let root = UIHostingController(rootView: TabView {
            NavigationStack {
                if hidesTabBar { PageWithSheet().hidesRootTabBar() } else { PageWithSheet() }
            }
            .tabItem { Label("One", systemImage: "1.circle") }
        })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let deadline = ContinuousClock.now + .seconds(8)
        var effects: [(alpha: CGFloat, description: String)] = []
        while ContinuousClock.now < deadline {
            if let sheet = root.presentedViewController, sheet.isBeingPresented == false, let view = sheet.viewIfLoaded {
                view.layoutIfNeeded()
                effects = bottomEdgeEffects(in: view)
                if !effects.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        root.presentedViewController?.dismiss(animated: false)
        return effects.map(\.alpha)
    }

    /// `hidesRootTabBar()` drops the bottom edge effect of its own page's scroll views
    /// (`HiddenBottomScrollEdge`). A sheet the page opens has bars of its own, and keeps its.
    @Test("a sheet opened from a page that hides the tab bar keeps its bottom edge effect")
    func sheetKeepsItsBottomEdge() async throws {
        let plain = try await sheetBottomEdgeAlphas(hidesTabBar: false)
        let hiding = try await sheetBottomEdgeAlphas(hidesTabBar: true)
        #expect(!plain.isEmpty, "the sheet's bottom bar drew no edge effect to compare")
        #expect(plain == hiding, "plain \(plain) hiding \(hiding)")
    }
}
