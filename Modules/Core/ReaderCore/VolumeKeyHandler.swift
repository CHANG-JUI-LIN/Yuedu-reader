import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - Volume Key Page Turn

/// Intercepts hardware volume buttons and converts them to page-turn commands.
/// Uses MPVolumeView to hide the system volume HUD + KVO to monitor outputVolume changes.
final class VolumeKeyHandler: NSObject, ObservableObject {

    enum PageDirection { case prev, next }

    /// Page-turn callback
    var onPageTurn: ((PageDirection) -> Void)?

    /// Whether volume-based page turning is enabled
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled { startListening() } else { stopListening() }
            UserDefaults.standard.set(isEnabled, forKey: "yd_volume_page")
        }
    }

    // Internal state
    private var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?
    private let audioSession = AVAudioSession.sharedInstance()
    private var previousVolume: Float = 0.5
    private var isAdjusting = false  // Prevents feedback loop when restoring volume

    override init() {
        super.init()
        isEnabled = UserDefaults.standard.bool(forKey: "yd_volume_page")
    }

    deinit { stopListening() }

    // MARK: - Start Listening

    func startListening() {
        guard observation == nil else { return }

        // Activate audio session (only when listening)
        try? audioSession.setActive(true)
        previousVolume = audioSession.outputVolume

        // Hide the system volume HUD: place an MPVolumeView off-screen
        if volumeView == nil {
            let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            view.alpha = 0.001  // Cannot be exactly 0, otherwise the system ignores it
            if let windowScene = UIApplication.shared.connectedScenes.first(where: {
                $0.activationState == .foregroundActive
            }) as? UIWindowScene,
                let window = windowScene.windows.first(where: { $0.isKeyWindow })
            {
                window.addSubview(view)
            }
            volumeView = view
        }

        // KVO monitoring of outputVolume changes
        observation = audioSession.observe(\.outputVolume, options: [.new]) {
            [weak self] _, change in
            guard let self = self, !self.isAdjusting,
                let newValue = change.newValue
            else { return }

            let diff = newValue - self.previousVolume
            if abs(diff) < 0.01 { return }  // Ignore minor floating-point drift

            DispatchQueue.main.async {
                if diff > 0 {
                    self.onPageTurn?(.prev)  // Volume+ → previous page
                } else {
                    self.onPageTurn?(.next)  // Volume- → next page
                }
                // Silently restore volume so consecutive presses continue to trigger
                self.restoreVolume()
            }
        }
    }

    func stopListening() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    // MARK: - Silent Volume Restore

    private func restoreVolume() {
        isAdjusting = true
        // Find the UISlider inside MPVolumeView to set the volume
        if let slider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.value = previousVolume
        }
        // Brief delay before unlocking to avoid KVO callback loop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isAdjusting = false
        }
    }
}
