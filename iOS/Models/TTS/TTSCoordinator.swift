import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum TTSPlaybackState {
    case stopped
    case playing
    case paused
}

extension Notification.Name {
    static let ttsFloatingPlayerOpenPanel = Notification.Name("ttsFloatingPlayerOpenPanel")
}

@MainActor
final class TTSFloatingPlayerState: ObservableObject {
    static let shared = TTSFloatingPlayerState()

    @Published private(set) var isVisible = false
    @Published private(set) var title = ""
    @Published private(set) var playbackState: TTSPlaybackState = .stopped
    @Published private(set) var currentSegmentIndex = 0
    @Published private(set) var totalSegments = 0
    @Published var isPanelPresented = false

    private weak var coordinator: TTSCoordinator?
    private var allowsReaderOverlay = false

    var progressText: String {
        guard totalSegments > 0 else { return "" }
        return "\(currentSegmentIndex + 1)/\(totalSegments)"
    }

    func attach(_ coordinator: TTSCoordinator) {
        self.coordinator = coordinator
        update(from: coordinator)
    }

    func update(from coordinator: TTSCoordinator) {
        guard self.coordinator === coordinator else { return }
        title = coordinator.floatingTitle
        playbackState = coordinator.playbackState
        currentSegmentIndex = coordinator.currentSegmentIndex
        totalSegments = coordinator.totalSegments
        isVisible = allowsReaderOverlay && coordinator.playbackState != .stopped
    }

    func detach(_ coordinator: TTSCoordinator) {
        guard self.coordinator === coordinator else { return }
        self.coordinator = nil
        title = ""
        playbackState = .stopped
        currentSegmentIndex = 0
        totalSegments = 0
        isVisible = false
        isPanelPresented = false
    }

    func setReaderOverlayVisible(_ visible: Bool) {
        allowsReaderOverlay = visible
        if let coordinator {
            update(from: coordinator)
        } else {
            isVisible = false
        }
    }

    func openPanel() {
        NotificationCenter.default.post(name: .ttsFloatingPlayerOpenPanel, object: nil)
        isPanelPresented = true
    }

    func togglePlayback() {
        coordinator?.toggle()
    }

    func skipBackward() {
        coordinator?.skipBackward()
    }

    func skipForward() {
        coordinator?.skipForward()
    }

    func stop() {
        coordinator?.stop(reason: "floating player stop")
    }

#if DEBUG
    func configurePreview(
        title: String,
        playbackState: TTSPlaybackState,
        currentSegmentIndex: Int,
        totalSegments: Int
    ) {
        self.title = title
        self.playbackState = playbackState
        self.currentSegmentIndex = currentSegmentIndex
        self.totalSegments = totalSegments
        allowsReaderOverlay = true
        isVisible = playbackState != .stopped
    }
#endif
}

// MARK: - TTS Coordinator
//
// Unified external interface: ReaderView and TTSPanelView depend only on TTSCoordinator.
// The underlying layer uses only the HTTP TTS audio player.
// Manages: sleep timer, MPNowPlayingInfo, AVAudioSession.

final class TTSCoordinator: ObservableObject {

    // MARK: - Published State (bound to TTSPanelView)
    @Published var isPlaying = false
    @Published private(set) var playbackState: TTSPlaybackState = .stopped
    @Published private(set) var currentSegmentIndex = 0
    @Published private(set) var totalSegments = 0
    @Published private(set) var currentSegmentText = ""
    @Published var speechRate: Float = 0.5
    @Published var sleepMinutes: Int = 0
    var showsGlobalFloatingPlayer = false

    // MARK: - Callbacks (set by ReaderView)
    var onPageFinished: (() -> String?)? {
        didSet { rewireCallbacks() }
    }
    var onStop: (() -> Void)? {
        didSet { rewireCallbacks() }
    }
    var onNextTrackRequested: (() -> Bool)?
    var onPreviousTrackRequested: (() -> Bool)?
    // MARK: - Engine
    private let httpEngine = HTTPTTSEngine()
    private let systemEngine = SystemTTSEngine()
    /// Engine bound for the current playback session; resolved at `speak` time so toggling the
    /// system-voice setting never redirects pause/stop to the wrong engine mid-session.
    private lazy var activeEngine: TTSPlayable = httpEngine
    private var currentEngine: TTSPlayable { activeEngine }
    private static weak var activeSystemMediaCoordinator: TTSCoordinator?

    /// Use the on-device offline voice when the user forces it, or as an automatic fallback
    /// whenever no HTTP TTS source is configured. Otherwise use the HTTP engine.
    private func resolveEngine() -> TTSPlayable {
        if GlobalSettings.shared.ttsUseSystemVoice { return systemEngine }
        let template = GlobalSettings.shared.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return template.isEmpty ? systemEngine : httpEngine
    }

    private var sleepTimer: Timer?
    private var audioSessionActive = false
    private var nowPlayingTitle = "Reading Aloud"
    private var nowPlayingElapsed: TimeInterval = 0
    private var nowPlayingDuration: TimeInterval = 1
    private var nowPlayingStartedAt: Date?
    private var audioInterruptionCancellable: AnyCancellable?
    private var routeChangeCancellable: AnyCancellable?
    private var shouldResumeAfterInterruption = false
    private var isStoppingFromCoordinator = false

    var floatingTitle: String {
        nowPlayingTitle
    }

    init() {
        rewireCallbacks()
        setupAudioSessionNotifications()
        ttsLog("[TTS][Coordinator] init")
    }

    // MARK: - External Controls

    func speak(text: String, title: String = "") {
        guard !text.isEmpty else {
            ttsLog("[TTS][Coordinator] speak ignored empty text")
            return
        }
        activeEngine = resolveEngine()
        ttsLog("[TTS][Coordinator] speak requested engine=\(currentEngine === systemEngine ? "system" : "http") textCount=\(text.count) title=\(title) rate=\(speechRate)")
        guard activateAudioSession() else {
            ttsLog("[TTS][Coordinator] speak aborted audio session activation failed")
            return
        }
        ttsLog("[TTS][Coordinator] configure engine audio session ownership")
        currentEngine.configureAudioSessionOwnership(true)
        nowPlayingTitle = title.isEmpty ? "Reading Aloud" : title
        nowPlayingElapsed = 0
        nowPlayingDuration = estimatedDuration(for: text)
        nowPlayingStartedAt = Date()
        currentSegmentIndex = 0
        totalSegments = 0
        currentSegmentText = ""
        currentEngine.speak(text: text, title: title, rate: speechRate)
        ttsLog("[TTS][Coordinator] engine speak returned enginePlaying=\(currentEngine.isPlaying)")
        guard currentEngine.isPlaying else {
            ttsLog("[TTS][Coordinator] engine not playing after speak; stopping")
            stop()
            return
        }
        isPlaying = true
        playbackState = .playing
        updateNowPlaying()
        publishFloatingPlayerState()
        if sleepMinutes > 0 { startSleepTimer() }
    }

    func pause() {
        ttsLog("[TTS][Coordinator] pause requested coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
        guard hasActivePlaybackSession else {
            ttsLog("[TTS][Coordinator] pause ignored no active playback session")
            return
        }
        currentEngine.pause()
        freezeNowPlayingElapsed()
        isPlaying = currentEngine.isPlaying
        playbackState = .paused
        updateNowPlaying()
        publishFloatingPlayerState()
        ttsLog("[TTS][Coordinator] pause done coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
    }

    func resume() {
        ttsLog("[TTS][Coordinator] resume requested coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
        guard hasActivePlaybackSession else {
            ttsLog("[TTS][Coordinator] resume ignored no active playback session")
            return
        }
        guard activateAudioSession() else { return }
        currentEngine.configureAudioSessionOwnership(true)
        currentEngine.resume()
        isPlaying = currentEngine.isPlaying
        playbackState = isPlaying ? .playing : .paused
        if nowPlayingStartedAt == nil {
            nowPlayingStartedAt = Date()
        }
        updateNowPlaying()
        publishFloatingPlayerState()
        ttsLog("[TTS][Coordinator] resume done coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
    }

    func toggle() {
        playbackState == .playing ? pause() : resume()
    }

    func stop(reason: String = "direct") {
        ttsLog("[TTS][Coordinator] stop requested reason=\(reason) coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
        isStoppingFromCoordinator = true
        currentEngine.stop()
        isStoppingFromCoordinator = false
        finishStopped(reason: reason)
    }

    func skipForward() {
        ttsLog("[TTS][Coordinator] skipForward requested state=\(playbackState)")
        guard hasActivePlaybackSession else { return }
        if onNextTrackRequested?() == true {
            resetNowPlayingClockForCurrentAudio()
            updateNowPlaying()
            publishFloatingPlayerState()
            return
        }
        currentEngine.skipForward()
        isPlaying = currentEngine.isPlaying
        playbackState = isPlaying ? .playing : .paused
        resetNowPlayingClockForCurrentAudio()
        updateNowPlaying()
        publishFloatingPlayerState()
    }

    func skipBackward() {
        ttsLog("[TTS][Coordinator] skipBackward requested state=\(playbackState)")
        guard hasActivePlaybackSession else { return }
        if onPreviousTrackRequested?() == true {
            resetNowPlayingClockForCurrentAudio()
            updateNowPlaying()
            publishFloatingPlayerState()
            return
        }
        currentEngine.skipBackward()
        isPlaying = currentEngine.isPlaying
        playbackState = isPlaying ? .playing : .paused
        resetNowPlayingClockForCurrentAudio()
        updateNowPlaying()
        publishFloatingPlayerState()
    }

    func seekToProgress(_ progress: Double) {
        ttsLog("[TTS][Coordinator] seekToProgress requested progress=\(progress) totalSegments=\(totalSegments)")
        guard hasActivePlaybackSession, totalSegments > 0 else { return }
        let clamped = min(max(progress, 0), 1)
        let segment = Int(round(clamped * Double(max(totalSegments - 1, 0))))
        currentEngine.seekToSegment(segment)
        isPlaying = currentEngine.isPlaying
        playbackState = isPlaying ? .playing : .paused
        resetNowPlayingClockForCurrentAudio()
        updateNowPlaying()
        publishFloatingPlayerState()
    }

    func updateNowPlayingTitle(_ title: String) {
        nowPlayingTitle = title.isEmpty ? "Reading Aloud" : title
        updateNowPlaying()
        publishFloatingPlayerState()
    }

    private func finishStopped(reason: String) {
        let ownsSystemMedia = Self.activeSystemMediaCoordinator === self
        isPlaying = false
        playbackState = .stopped
        cancelSleepTimer()
        if ownsSystemMedia {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            ttsLog("[TTS][Coordinator] stop skipped clearing system media because coordinator is not active owner")
        }
        nowPlayingTitle = "Reading Aloud"
        nowPlayingElapsed = 0
        nowPlayingDuration = 1
        nowPlayingStartedAt = nil
        currentSegmentIndex = 0
        totalSegments = 0
        currentSegmentText = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            TTSFloatingPlayerState.shared.detach(self)
        }
        if ownsSystemMedia {
            setRemoteCommandsEnabled(false)
            deactivateAudioSession()
            if Self.activeSystemMediaCoordinator === self {
                Self.activeSystemMediaCoordinator = nil
            }
        }
        ttsLog("[TTS][Coordinator] stop done reason=\(reason)")
    }

    func refreshNowPlayingForSystemSurfaces() {
        ttsLog("[TTS][Coordinator] refreshNowPlayingForSystemSurfaces audioSessionActive=\(audioSessionActive) coordinatorPlaying=\(isPlaying)")
        guard audioSessionActive else { return }
        setupRemoteCommands()
        updateNowPlaying()
    }

    func updateRate(_ rate: Float) {
        speechRate = max(0.1, min(rate, 0.65))
    }

    func setSleepTimer(minutes: Int) {
        sleepMinutes = minutes
        if isPlaying && minutes > 0 { startSleepTimer() } else { cancelSleepTimer() }
    }

    private func rewireCallbacks() {
        wireCallbacks(to: httpEngine)
        wireCallbacks(to: systemEngine)
    }

    private func wireCallbacks(to engine: TTSPlayable) {
        engine.onPageFinished = { [weak self] in
            guard let self, self.isPlaying else { return nil }
            return self.onPageFinished?()
        }
        engine.onStop = { [weak self] in
            let handleStop = {
                guard let self else { return }
                guard !self.isStoppingFromCoordinator else { return }
                self.finishStopped(reason: "engine finished")
                self.onStop?()
            }
            if Thread.isMainThread {
                handleStop()
            } else {
                DispatchQueue.main.async(execute: handleStop)
            }
        }
        engine.onPlaybackStarted = { [weak self] duration in
            DispatchQueue.main.async {
                self?.handleEnginePlaybackStarted(duration: duration)
            }
        }
        engine.onSegmentChanged = { [weak self] index, total, text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentSegmentIndex = index
                self.totalSegments = total
                self.currentSegmentText = text
                self.publishFloatingPlayerState()
            }
        }
    }

    private func publishFloatingPlayerState() {
        guard showsGlobalFloatingPlayer else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.playbackState == .stopped {
                TTSFloatingPlayerState.shared.detach(self)
            } else {
                TTSFloatingPlayerState.shared.attach(self)
            }
        }
    }

    // MARK: - Audio Session

    @discardableResult
    private func activateAudioSession() -> Bool {
        guard !audioSessionActive else {
            ttsLog("[TTS][Coordinator] audio session already active")
            claimSystemMediaSession()
            setupRemoteCommands()
            setRemoteCommandsEnabled(true)
            return true
        }
        ttsLog("[TTS][Coordinator] activating audio session")
        claimSystemMediaSession()
        setupRemoteCommands()
        setRemoteCommandsEnabled(true)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .spokenAudio, options: [])
            try s.setActive(true)
            audioSessionActive = true
            UIApplication.shared.beginReceivingRemoteControlEvents()
            ttsLog("[TTS][Coordinator] audio session active category=\(s.category.rawValue) mode=\(s.mode.rawValue) secondarySilenced=\(s.secondaryAudioShouldBeSilencedHint)")
            return true
        } catch {
            audioSessionActive = false
            ttsLog("[TTS] Failed to activate audio session: \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else {
            ttsLog("[TTS][Coordinator] deactivate skipped audio session inactive")
            return
        }
        ttsLog("[TTS][Coordinator] deactivating audio session")
        UIApplication.shared.endReceivingRemoteControlEvents()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        audioSessionActive = false
    }

    private func claimSystemMediaSession() {
        if let activeCoordinator = Self.activeSystemMediaCoordinator,
           activeCoordinator !== self {
            ttsLog("[TTS][Coordinator] replacing active system media coordinator old=\(ObjectIdentifier(activeCoordinator)) new=\(ObjectIdentifier(self))")
            activeCoordinator.stop(reason: "replaced by another TTS coordinator")
        }
        Self.activeSystemMediaCoordinator = self
    }

    // MARK: - Lock Screen Controls

    private func setupRemoteCommands() {
        ttsLog("[TTS][Coordinator] configuring remote commands owner=\(ObjectIdentifier(self))")

        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled  = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.stopCommand.isEnabled  = false
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = false

        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.stopCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)

        c.playCommand.addTarget { [weak self] _ in
            ttsLog("[TTS][Remote] playCommand")
            return self?.performRemoteCommand(requiresActiveSession: true) { $0.resume() } ?? .commandFailed
        }
        c.pauseCommand.addTarget { [weak self] _ in
            ttsLog("[TTS][Remote] pauseCommand")
            return self?.performRemoteCommand(requiresActiveSession: true) { $0.pause() } ?? .commandFailed
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            ttsLog("[TTS][Remote] togglePlayPauseCommand")
            return self?.performRemoteCommand(requiresActiveSession: true) { $0.toggle() } ?? .commandFailed
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            ttsLog("[TTS][Remote] nextTrackCommand")
            return self?.performRemoteCommand(requiresActiveSession: true) { $0.skipForward() } ?? .commandFailed
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            ttsLog("[TTS][Remote] previousTrackCommand")
            return self?.performRemoteCommand(requiresActiveSession: true) { $0.skipBackward() } ?? .commandFailed
        }
    }

    private func setupAudioSessionNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        audioInterruptionCancellable = center.publisher(
            for: AVAudioSession.interruptionNotification,
            object: session
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }

        routeChangeCancellable = center.publisher(
            for: AVAudioSession.routeChangeNotification,
            object: session
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaying
            ttsLog("[TTS][Coordinator] audio interruption began shouldResume=\(shouldResumeAfterInterruption)")
            if isPlaying {
                pause()
            }
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            ttsLog("[TTS][Coordinator] audio interruption ended shouldResume=\(shouldResumeAfterInterruption) options=\(options.rawValue)")
            guard shouldResumeAfterInterruption else { return }
            shouldResumeAfterInterruption = false
            guard options.contains(.shouldResume) else { return }
            guard activateAudioSession() else { return }
            resume()
        @unknown default:
            ttsLog("[TTS][Coordinator] audio interruption unknown type=\(type.rawValue)")
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        ttsLog("[TTS][Coordinator] audio route changed reason=\(reason.rawValue)")
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = enabled
        c.pauseCommand.isEnabled = enabled
        c.togglePlayPauseCommand.isEnabled = enabled
        c.stopCommand.isEnabled = false
        c.nextTrackCommand.isEnabled = enabled
        c.previousTrackCommand.isEnabled = enabled
        c.changePlaybackPositionCommand.isEnabled = false
        ttsLog("[TTS][Coordinator] remote commands enabled=\(enabled)")
    }

    private var hasActivePlaybackSession: Bool {
        audioSessionActive || isPlaying || nowPlayingStartedAt != nil
    }

    private func performRemoteCommand(
        requiresActiveSession: Bool = false,
        _ action: @escaping (TTSCoordinator) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        if requiresActiveSession && !hasActivePlaybackSession {
            ttsLog("[TTS][Remote] ignored no active playback session")
            return .noActionableNowPlayingItem
        }
        if Thread.isMainThread {
            action(self)
        } else {
            DispatchQueue.main.sync {
                action(self)
            }
        }
        return .success
    }

    private func updateNowPlaying() {
        guard Self.activeSystemMediaCoordinator === self else {
            ttsLog("[TTS][NowPlaying] update skipped because coordinator is not active owner")
            return
        }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = "TTS Narration"
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentNowPlayingElapsed()
        info[MPMediaItemPropertyPlaybackDuration] = max(nowPlayingDuration, 1)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        ttsLog("[TTS][NowPlaying] update title=\(nowPlayingTitle) elapsed=\(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?? "?") duration=\(info[MPMediaItemPropertyPlaybackDuration] ?? "?") rate=\(info[MPNowPlayingInfoPropertyPlaybackRate] ?? "?") state=\(isPlaying ? "playing" : "paused")")
    }

    private func handleEnginePlaybackStarted(duration: TimeInterval) {
        guard Self.activeSystemMediaCoordinator === self else {
            ttsLog("[TTS][NowPlaying] playback started ignored because coordinator is not active owner")
            return
        }
        nowPlayingDuration = max(duration, 1)
        resetNowPlayingClockForCurrentAudio()
        updateNowPlaying()
        publishFloatingPlayerState()
    }

    private func resetNowPlayingClockForCurrentAudio() {
        nowPlayingElapsed = 0
        nowPlayingStartedAt = playbackState == .playing ? Date() : nil
    }

    private func currentNowPlayingElapsed() -> TimeInterval {
        guard isPlaying, let startedAt = nowPlayingStartedAt else {
            return nowPlayingElapsed
        }
        return nowPlayingElapsed + Date().timeIntervalSince(startedAt)
    }

    private func freezeNowPlayingElapsed() {
        nowPlayingElapsed = currentNowPlayingElapsed()
        nowPlayingStartedAt = nil
    }

    private func estimatedDuration(for text: String) -> TimeInterval {
        let characterCount = max(text.count, 1)
        let baseCharactersPerSecond: Double = 5.5
        let rateFactor = max(Double(speechRate) / 0.5, 0.5)
        return max(Double(characterCount) / (baseCharactersPerSecond * rateFactor), 1)
    }

    // MARK: - Sleep Timer

    private func startSleepTimer() {
        cancelSleepTimer()
        guard sleepMinutes > 0 else { return }
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(sleepMinutes * 60),
            repeats: false
        ) { [weak self] _ in DispatchQueue.main.async { self?.stop(reason: "sleep timer") } }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    deinit { stop(reason: "coordinator deinit") }
}
