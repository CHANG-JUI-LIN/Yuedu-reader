import UIKit

/// The one writer of `UIApplication.isIdleTimerDisabled`.
///
/// Three things keep the screen on — 自動閱讀, 朗讀 with 朗讀時保持螢幕開啟, and an open
/// reader with 閱讀時螢幕常亮 — and each used to write the idle timer itself, so whichever
/// wrote last won: 朗讀 stopping switched the screen back to sleeping under a running
/// 自動閱讀. Each now holds a reason here, and the screen stays on while any reason is
/// held.
///
/// A reason is held *by an owner*, so two readers never release each other's: closing
/// one reader can land after the next one opened (a 換源 or a version swap), and a bare
/// `.reading` would have let the old reader's `onDisappear` drop the new one's hold.
@MainActor
final class ScreenAwakeController {
    enum Reason: String, Hashable, Sendable {
        /// 自動閱讀 is running in a reader.
        case autoRead
        /// 朗讀 is playing and 朗讀時保持螢幕開啟 is on.
        case narration
        /// A reader is on screen, in the foreground, and 閱讀時螢幕常亮 is on.
        case reading
    }

    private struct Hold: Hashable {
        let reason: Reason
        let owner: ObjectIdentifier
    }

    static let shared = ScreenAwakeController()

    private var holds: Set<Hold> = []
    private let applyIdleTimerDisabled: @MainActor (Bool) -> Void

    /// `applyIdleTimerDisabled` is the only seam: tests pass a recorder instead of the app.
    init(
        applyIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = {
            UIApplication.shared.isIdleTimerDisabled = $0
        }
    ) {
        self.applyIdleTimerDisabled = applyIdleTimerDisabled
    }

    /// A key for a holder that is not an object itself: a SwiftUI view keeps one in
    /// `@State` for as long as it lives.
    final class Owner {}

    var keepsScreenAwake: Bool { !holds.isEmpty }

    func isHeld(_ reason: Reason, by owner: AnyObject) -> Bool {
        holds.contains(Hold(reason: reason, owner: ObjectIdentifier(owner)))
    }

    /// Holds or releases `owner`'s `reason`. Idempotent: holding twice is one hold, and
    /// releasing what was never held does nothing.
    func setHeld(_ held: Bool, _ reason: Reason, by owner: AnyObject) {
        let hold = Hold(reason: reason, owner: ObjectIdentifier(owner))
        let wasAwake = keepsScreenAwake
        if held {
            holds.insert(hold)
        } else {
            holds.remove(hold)
        }
        guard keepsScreenAwake != wasAwake else { return }
        applyIdleTimerDisabled(keepsScreenAwake)
        AppLogger.info(
            "[ScreenAwake] idle timer \(keepsScreenAwake ? "disabled" : "enabled")",
            context: [
                "changed": "\(reason.rawValue)=\(held)",
                "reasons": holds.map(\.reason.rawValue).sorted().joined(separator: ","),
            ]
        )
    }
}
