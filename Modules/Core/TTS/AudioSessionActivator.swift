import AVFoundation
import Foundation

/// Centralizes AVAudioSession activation off the main thread.
///
/// `setCategory`/`setActive` are synchronous and can block long enough that calling
/// them on the main thread trips Xcode's runtime "AVAudioSession Hang Risk" warning
/// (and can stall the UI). These helpers hop the blocking calls onto a shared serial
/// queue — serial so an `activate` and a following `deactivate` cannot reorder — while
/// callers keep any main-thread-only work (remote-control registration, flags) on the
/// main thread.
///
/// Use only for fire-and-forget activation where the caller does not depend on the
/// synchronous success/failure result. Paths that gate behavior on activation success
/// (e.g. TTS refusing to speak when the session can't activate) must keep their own
/// synchronous handling.
enum AudioSessionActivator {
    private static let queue = DispatchQueue(label: "com.yuedu.audio.session", qos: .userInitiated)

    static func activate(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode = .default,
        options: AVAudioSession.CategoryOptions = []
    ) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(category, mode: mode, options: options)
            try? session.setActive(true)
        }
    }

    /// Toggle activation on an already-configured session (no category change).
    static func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions = []) {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(active, options: options)
        }
    }
}
