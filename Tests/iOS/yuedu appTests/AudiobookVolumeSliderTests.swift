import Testing
import UIKit
import MediaPlayer
@testable import yuedu_app

/// The volume track lines up with the speakers beside it only when MPVolumeView centres its
/// slider: the track is drawn in the slider's middle. MPVolumeView frames the slider through
/// `volumeSliderRect(forBounds:)` — from layout, and from route discovery, which a real device
/// runs on its own and which never lays the view out again. Its own rect hangs a 28pt slider off
/// the 18pt route button, which put the track 6pt above the speakers (device, 2026-11-05).
@MainActor
struct AudiobookVolumeSliderTests {
    /// A volume view in the state a device puts it in: the simulator has no volume to set, so
    /// MPVolumeView never shows its slider there and frames nothing.
    private func deviceVolumeView(height: Double) throws -> AudiobookVolumeSlider.StyledVolumeView {
        let view = AudiobookVolumeSlider.StyledVolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: height))
        let selector = Selector(("_setShowsVolumeSlider:"))
        try #require(view.responds(to: selector))
        typealias SetShowsVolumeSlider = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(view.method(for: selector), to: SetShowsVolumeSlider.self)(view, selector, true)
        return view
    }

    @Test(arguments: [28.0, 30.0, 34.0])
    func sliderRectIsCentred(height: Double) throws {
        let view = try deviceVolumeView(height: height)
        let rect = view.volumeSliderRect(forBounds: view.bounds)
        #expect(rect.height > 0)
        #expect(rect.midY == view.bounds.midY)
    }

    /// Route discovery's own path: `_setShowsRouteButton:animated:` frames the slider directly.
    @Test func routeDiscoveryKeepsTheSliderCentred() throws {
        let view = try deviceVolumeView(height: 30)
        let slider = try #require(view.value(forKey: "volumeSlider") as? UISlider)
        let selector = Selector(("_setShowsRouteButton:animated:"))
        try #require(view.responds(to: selector))
        typealias SetShowsRouteButton = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        unsafeBitCast(view.method(for: selector), to: SetShowsRouteButton.self)(view, selector, true, false)
        #expect(slider.frame.height > 0)
        #expect(slider.frame.midY == view.bounds.midY)
    }
}
