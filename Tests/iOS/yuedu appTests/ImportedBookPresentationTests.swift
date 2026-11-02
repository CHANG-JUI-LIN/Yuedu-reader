import Testing
import XCTest
import SwiftUI
import UIKit
@testable import yuedu_app

@Suite("Imported book presentation", .serialized)
@MainActor
struct ImportedBookPresentationTests {
    @Test("Cold launch retains its request until the scene has a visible window")
    func coldLaunch() async throws {
        let bridge = ImportedBookPresentationController()
        let destination = UIViewController()
        let requestID = UUID()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        var destinationScene: UIWindowScene?
        let completed: UUID = await withCheckedContinuation { continuation in
            bridge.receive(requestID: requestID, makeDestination: {
                destinationScene = $0
                return destination
            }, didPresent: {
                continuation.resume(returning: $0)
            })
            #expect(bridge.presentedViewController == nil)
            window.rootViewController = bridge
            window.makeKeyAndVisible()
        }
        #expect(bridge.presentedViewController === destination)
        #expect(completed == requestID)
        // The reader is built for the scene it is shown in (`followsScenePhase(of:)`).
        #expect(destinationScene === scene)
    }

    @Test("A document opens above an existing modal instead of being dropped by the root")
    func existingModal() async throws {
        let root = UIViewController()
        let bridge = ImportedBookPresentationController()
        root.addChild(bridge)
        root.view.addSubview(bridge.view)
        bridge.didMove(toParent: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let existing = UIViewController()
        await withCheckedContinuation { continuation in
            root.present(existing, animated: false) { continuation.resume() }
        }
        let destination = UIViewController()
        let requestID = UUID()
        let completed: UUID = await withCheckedContinuation { continuation in
            bridge.receive(requestID: requestID, makeDestination: { _ in destination }, didPresent: {
                continuation.resume(returning: $0)
            })
        }
        #expect(root.presentedViewController === existing)
        #expect(existing.presentedViewController === destination)
        #expect(completed == requestID)
    }

    @Test("A theme arriving during a book transition keeps each request's acknowledgement")
    func overlappingRequests() async throws {
        let bridge = ImportedBookPresentationController()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = bridge
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let book = UIViewController()
        let theme = UIViewController()
        let bookID = UUID()
        let themeID = UUID()
        var bookAcknowledgements: [UUID] = []
        var themeAcknowledgements: [UUID] = []
        let completed = XCTestExpectation(description: "Theme presentation completed")
        bridge.receive(requestID: bookID, makeDestination: { _ in
            // Queue the second handoff only after the first destination is being
            // built; UIWindow attachment itself is asynchronous on cold launch.
            Task { @MainActor in
                bridge.receive(requestID: themeID, makeDestination: { _ in theme }, didPresent: {
                    themeAcknowledgements.append($0)
                    if $0 == themeID { completed.fulfill() }
                })
            }
            return book
        }, didPresent: {
            bookAcknowledgements.append($0)
        })
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        #expect(result == .completed)
        #expect(bookAcknowledgements == [bookID])
        #expect(themeAcknowledgements == [themeID])
        #expect(book.presentedViewController === theme)
    }

    /// SwiftUI gives a host UIKit made no `scenePhase`; the Open In reader is one, and took
    /// its scene's phase from `followsScenePhase(of:)` instead.
    @Test("A tree UIKit hosts takes its scene's phase: where the scene is, then every change")
    func followsScenePhase() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // Not always active: a fresh simulator holds the test host inactive behind RSS's
        // notification-permission alert.
        let current: ScenePhase = switch scene.activationState {
        case .foregroundActive: .active
        case .foregroundInactive: .inactive
        default: .background
        }
        let log = ScenePhaseLog()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: ScenePhaseProbe(log: log).followsScenePhase(of: scene)
        )
        defer { window.isHidden = true; window.rootViewController = nil }
        await log.update { window.makeKeyAndVisible() }
        // Appearing is no change: a reader presented while the app is inactive is not told
        // it came back.
        #expect(log.appeared == current)
        #expect(log.changes.isEmpty)
        let cycle: [(Notification.Name, ScenePhase)] = [
            (UIScene.willDeactivateNotification, .inactive),
            (UIScene.didEnterBackgroundNotification, .background),
            (UIScene.willEnterForegroundNotification, .inactive),
            (UIScene.didActivateNotification, .active),
        ]
        let steps = (current == .active ? [] : [(UIScene.didActivateNotification, ScenePhase.active)]) + cycle
        for (name, _) in steps {
            await log.update { NotificationCenter.default.post(name: name, object: scene) }
        }
        #expect(log.changes == steps.map(\.1))
    }
}

@MainActor
private final class ScenePhaseLog {
    var appeared: ScenePhase?
    var changes: [ScenePhase] = []
    private var updated: (() -> Void)?

    func record(appeared phase: ScenePhase) {
        appeared = phase
        updated?()
    }

    func record(changed phase: ScenePhase) {
        changes.append(phase)
        updated?()
    }

    /// Runs `action`, waits for the probe to see it, then for the next frame: one change at a
    /// time, since SwiftUI coalesces changes it has not drawn yet, and one change a frame,
    /// since iOS 27 drops an `onChange` action that runs several times inside one frame
    /// ("tried to update multiple times per frame"; iOS 27.2 simulator, 2026-11-02). Posted
    /// back to back, the steps of a trip out and back landed within 2 ms and the last was
    /// dropped. A real scene's are not that close: coming back, the Open In reader saw
    /// `inactive` and `active` 20 ms apart (iOS 27.1), and two in a row went through here.
    func update(_ action: () -> Void) async {
        let seen = XCTestExpectation(description: "scene phase reached the probe")
        updated = { seen.fulfill() }
        action()
        _ = await XCTWaiter.fulfillment(of: [seen], timeout: 5)
        updated = nil
        await withCheckedContinuation { continuation in
            let tick = FrameTick(continuation)
            CADisplayLink(target: tick, selector: #selector(FrameTick.fire(_:))).add(to: .main, forMode: .common)
        }
    }
}

/// Resumes once, on the next frame. The display link holds this target until it is invalidated.
private final class FrameTick: NSObject {
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    @objc func fire(_ link: CADisplayLink) {
        link.invalidate()
        continuation.resume()
    }
}

private struct ScenePhaseProbe: View {
    @Environment(\.scenePhase) private var phase
    let log: ScenePhaseLog

    var body: some View {
        Color.clear
            .onAppear { log.record(appeared: phase) }
            .onChange(of: phase) { _, phase in log.record(changed: phase) }
    }
}
