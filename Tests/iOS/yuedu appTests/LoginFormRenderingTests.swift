import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

@MainActor
final class LoginFormRenderingTests: XCTestCase {
    func testEqualColumnsHaveEqualRenderedWidthsAndDoNotOverlap() async {
        let ready = expectation(description: "SwiftUI placed all controls")
        var measured: [Int: CGRect] = [:]
        let content = LoginGridLayout(
            specs: [6, 6, 4, 4, 4].map {
                LoginGridSpec(colSpan: $0, rowSpan: 1, wrapBefore: false)
            },
            horizontalSpacing: DSSpacing.md
        ) {
            ForEach(0..<5) { index in
                Text("Action \(index)")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: LoginControlFrames.self,
                                value: [index: geometry.frame(in: .named("grid"))]
                            )
                        }
                    }
            }
        }
        .coordinateSpace(name: "grid")
        .onPreferenceChange(LoginControlFrames.self) { frames in
            if frames.count == 5, measured.isEmpty {
                measured = frames
                ready.fulfill()
            }
        }
        let host = mount(content)
        defer { host.isHidden = true; host.rootViewController = nil }
        await fulfillment(of: [ready], timeout: 5)
        guard measured.count == 5 else { return }
        XCTAssertEqual(measured[0]!.width, measured[1]!.width, accuracy: 0.5)
        XCTAssertEqual(measured[2]!.width, measured[4]!.width, accuracy: 0.5)
        XCTAssertEqual(measured[1]!.minX - measured[0]!.maxX, DSSpacing.md, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(measured[2]!.minY, measured[0]!.maxY)
        XCTAssertEqual(measured[1]!.maxX, measured[4]!.maxX, accuracy: 0.5)
    }

    func testSourceLoginRendersLightDarkAndAccessibility() async throws {
        let json = """
        {"bookSourceUrl":"https://login-layout.example","bookSourceName":"Login layout",
         "loginUi":[
          {"name":"— 正文用戶系統 —","type":"button","style":{"cols":1}},
          {"name":"源作者","type":"text"},
          {"name":"臨時口令","type":"text"},
          {"name":"尚未授權","type":"button","style":{"cols":2}},
          {"name":"申請訪客 Token","type":"button","style":{"cols":2}},
          {"name":"網頁註冊／登入","type":"button","style":{"cols":2}},
          {"name":"查看使用次數","type":"button","style":{"cols":2}},
          {"name":"退出用戶系統","type":"button","style":{"cols":1}},
          {"name":"— 自訂正文憑證 —","type":"button","style":{"cols":1}},
          {"name":"ywkey","type":"text"},
          {"name":"ywguid","type":"text"}
         ]}
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        for (name, scheme, typeSize) in [
            ("light", ColorScheme.light, DynamicTypeSize.large),
            ("dark", ColorScheme.dark, DynamicTypeSize.large),
            ("accessibility", ColorScheme.light, DynamicTypeSize.accessibility3)
        ] {
            let ready = expectation(description: "Mounted \(name) login sheet")
            let view = BookSourceFormLoginView(source: source, onDismiss: {})
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
                .onAppear { ready.fulfill() }
            let window = mount(view)
            defer { window.isHidden = true; window.rootViewController = nil }
            await fulfillment(of: [ready], timeout: 5)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.size.height, 0)
            let attachment = XCTAttachment(image: image)
            attachment.name = "source-login-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func mount(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        return window
    }
}

private struct LoginControlFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
