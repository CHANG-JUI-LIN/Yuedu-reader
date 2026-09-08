import XCTest
import SwiftUI
@testable import yuedu_app

@MainActor
final class FootnotePopoverTests: XCTestCase {
    func testNativeBackdropOwnsShortAndLongPopoverSurfaces() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let notes = ["工作忙，生活累，作书令我很疲惫。拖了大半年开始动手。",
                     "《绍宋》那本书里曾经搞过一套时间线，收过那书的人应该知道。那版有些卡通了，不适合这种出版书，重新设计了一套样式。"]
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = appearance
            presenter.view.backgroundColor = .systemIndigo
            for (index, note) in notes.enumerated() {
                FootnotePopoverHost.present(text: note, from: presenter, sourceView: presenter.view,
                    sourceRect: CGRect(x: 230, y: 430, width: 15, height: 15))
                let host = try XCTUnwrap(presenter.presentedViewController as? FootnotePopoverHost)
                if let transition = host.transitionCoordinator {
                    await withCheckedContinuation { continuation in
                        transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                    }
                }
                window.layoutIfNeeded()
                let color = host.view.backgroundColor?.resolvedColor(with: host.traitCollection)
                print("FOOTNOTE_SURFACE appearance=\(appearance.rawValue) note=\(index) background=\(String(describing: color)) opaque=\(host.view.isOpaque) frame=\(host.view.frame)")
                XCTAssertEqual(color?.cgColor.alpha ?? 0, 0, "Hosting content must not cover UIKit's backdrop while its arrow remains translucent")
                XCTAssertEqual(host.rootView.text, note)
                XCTAssertEqual(host.popoverPresentationController?.sourceRect.width, 15)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let png = try XCTUnwrap(image.pngData())
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("footnote-\(appearance.rawValue)-\(index).png")
                try png.write(to: output)
                print("FOOTNOTE_CAPTURE \(output.path)")
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "footnote-\(appearance.rawValue)-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
                await withCheckedContinuation { continuation in
                    presenter.dismiss(animated: false) { continuation.resume() }
                }
            }
        }
    }
}
