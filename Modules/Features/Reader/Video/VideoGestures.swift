import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

// MARK: - What a drag does

/// What a one-finger drag on the picture does, decided once from where it starts and which way it
/// first moves: across seeks (Swiftfin), up and down on the left third sets the brightness and on
/// the right third the volume (plezy's edge tracker), and up in the middle opens 選集 (plezy).
enum VideoPanKind: Equatable, Sendable {
    case seek
    case brightness
    case volume
    case episodes

    init(start: CGPoint, translation: CGSize, in size: CGSize) {
        if abs(translation.width) > abs(translation.height) {
            self = .seek
            return
        }
        let fraction = start.x / max(size.width, 1)
        if fraction < DSLayout.videoEdgeGestureFraction {
            self = .brightness
        } else if fraction > 1 - DSLayout.videoEdgeGestureFraction {
            self = .volume
        } else {
            self = .episodes
        }
    }
}

/// A drag in progress: what it does, the time or level it began from, and what it points at now.
struct VideoPan: Equatable {
    let kind: VideoPanKind
    let origin: Double
    var value: Double

    /// Seconds a quick swipe across jumps instead of scrubbing (Swiftfin's jump interval).
    static let jumpSeconds: Double = 10

    /// Seconds a pan across the picture's whole width scrubs in a timeline this long: the whole of
    /// a short one, `videoScrubSecondsPerWidth` of a mid-length one, and
    /// `videoScrubDurationShareOfWidth` of a long one.
    static func secondsPerWidth(span: Double) -> Double {
        guard span > 0 else { return DSLayout.videoScrubSecondsPerWidth }
        return min(span, max(DSLayout.videoScrubSecondsPerWidth, span * DSLayout.videoScrubDurationShareOfWidth))
    }

    /// The time a pan across points at, kept inside the seekable range.
    static func seekTime(origin: Double, translation: CGFloat, width: CGFloat, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        let target = origin + Double(translation / max(width, 1)) * secondsPerWidth(span: span)
        return min(max(target, range.lowerBound), range.upperBound)
    }

    /// The level an edge pan sets: the picture's whole height spans the whole range, up raises.
    static func level(origin: Double, translation: CGFloat, height: CGFloat) -> Double {
        min(1, max(0, origin - Double(translation / max(height, 1))))
    }

    /// A short, quick swipe across: it jumps `jumpSeconds` rather than scrubbing.
    static func isFlick(translation: CGFloat, elapsed: TimeInterval) -> Bool {
        elapsed <= DSAnimation.videoFlickSeconds && abs(translation) >= DSLayout.videoSwipeThreshold
    }
}

// MARK: - Recognizers

/// The picture's gestures, through UIKit's recognizers: a long press reports when it begins and
/// when the finger lifts, and the recognizers keep one another apart — a pan does not start under a
/// held long press, and two fingers pinch instead of panning.
struct VideoGestureSurface: UIViewRepresentable {
    enum PanEvent {
        case began(start: CGPoint, translation: CGSize, size: CGSize)
        case changed(translation: CGSize, size: CGSize)
        case ended(translation: CGSize, elapsed: TimeInterval)
        case cancelled
    }

    /// Only a tap while locked: it shows or hides the unlock button.
    let isLocked: Bool
    let onTap: () -> Void
    let onLongPress: (Bool) -> Void
    let onPan: (PanEvent) -> Void
    /// The pinch's final scale.
    let onPinch: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // VoiceOver reaches the controls instead; every gesture here has one.
        view.accessibilityElementsHidden = true
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.longPressed(_:)))
        longPress.minimumPressDuration = DSAnimation.videoLongPressSeconds
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        for recognizer in [tap, longPress, pan, pinch] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
        coordinator.lockable = [longPress, pan, pinch]
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
        for recognizer in context.coordinator.lockable { recognizer.isEnabled = !isLocked }
    }

    @MainActor
    final class Coordinator: NSObject {
        var surface: VideoGestureSurface?
        var lockable: [UIGestureRecognizer] = []
        private var panBegan: TimeInterval = 0

        @objc func tapped() {
            surface?.onTap()
        }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: surface?.onLongPress(true)
            case .ended, .cancelled, .failed: surface?.onLongPress(false)
            default: break
            }
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = CGSize(recognizer.translation(in: view))
            switch recognizer.state {
            case .began:
                panBegan = ProcessInfo.processInfo.systemUptime
                let point = recognizer.location(in: view)
                let start = CGPoint(x: point.x - translation.width, y: point.y - translation.height)
                surface?.onPan(.began(start: start, translation: translation, size: view.bounds.size))
            case .changed:
                surface?.onPan(.changed(translation: translation, size: view.bounds.size))
            case .ended:
                let elapsed = ProcessInfo.processInfo.systemUptime - panBegan
                surface?.onPan(.ended(translation: translation, elapsed: elapsed))
            case .cancelled, .failed:
                surface?.onPan(.cancelled)
            default:
                break
            }
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .ended { surface?.onPinch(recognizer.scale) }
        }
    }
}

private extension CGSize {
    init(_ point: CGPoint) {
        self.init(width: point.x, height: point.y)
    }
}

// MARK: - Brightness and volume

/// The screen's brightness and the system volume, for the edge pans.
///
/// iOS has no API that sets the system volume; an `MPVolumeView`'s own slider does, as every
/// third-party player sets it. While that view is on screen iOS also leaves out its own volume
/// HUD, for the hardware buttons too — so the volume is observed, and the player shows its own
/// level whenever it changes.
@MainActor
@Observable
final class VideoSystemControls {
    /// The system volume, 0–1, as the audio session reports it.
    private(set) var volume: Double
    /// Bumped whenever the volume changes, by a pan or by the hardware buttons.
    private(set) var volumeChanges = 0

    @ObservationIgnored fileprivate weak var volumeView: MPVolumeView?
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    /// The brightness before the first pan changed it, put back when the player closes or the app
    /// leaves the foreground.
    @ObservationIgnored private var originalBrightness: CGFloat?
    @ObservationIgnored private var reportedMissingSlider = false

    init() {
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in
                self?.volume = Double(value)
                self?.volumeChanges += 1
            }
        }
    }

    private var screen: UIScreen? { volumeView?.window?.windowScene?.screen }

    var brightness: Double {
        Double(screen?.brightness ?? 0)
    }

    func setBrightness(_ level: Double) {
        guard let screen else { return }
        if originalBrightness == nil { originalBrightness = screen.brightness }
        screen.brightness = CGFloat(level)
    }

    func restoreBrightness() {
        guard let originalBrightness, let screen else { return }
        screen.brightness = originalBrightness
        self.originalBrightness = nil
    }

    func setVolume(_ level: Double) {
        guard let slider = volumeView?.subviews.lazy.compactMap({ $0 as? UISlider }).first else {
            if !reportedMissingSlider {
                reportedMissingSlider = true
                AppLogger.info("[Video] MPVolumeView has no slider; the volume pan does nothing", level: .error)
            }
            return
        }
        slider.value = Float(level)
    }
}

/// The `MPVolumeView` whose slider `VideoSystemControls` moves. It has to be on screen to set the
/// volume, so it is a single, nearly transparent point.
struct VideoVolumeHost: UIViewRepresentable {
    let controls: VideoSystemControls

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        controls.volumeView = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        controls.volumeView = view
    }
}
