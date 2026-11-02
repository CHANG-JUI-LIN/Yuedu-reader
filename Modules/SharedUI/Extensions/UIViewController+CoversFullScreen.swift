import UIKit

extension UIViewController {
    /// Covers the whole window the way SwiftUI's `fullScreenCover` does: `.overFullScreen`,
    /// with the status bar its own (the cover's controller reported both, iOS 27.2 simulator,
    /// 2026-11-02). VoiceOver keeps to it as under `.fullScreen`: UIKit marks the
    /// presentation's container view modal either way.
    ///
    /// Not `.fullScreen`: once its transition ends, that takes the presenter's view out of the
    /// window, and SwiftUI updates nothing out of the window. A SwiftUI tree under it missed
    /// the scene's changes while it was up and was not handed them after it went (same
    /// simulator; `CoversFullScreenTests`), so the reader under an image preview missed the
    /// app leaving and coming back.
    func coversFullScreen() {
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }
}
