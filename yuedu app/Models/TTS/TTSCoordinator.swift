import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum TTSPlaybackState {
    case stopped
    case playing
    case paused
}

// MARK: - TTS 協調器
//
// 統一對外介面：ReaderView 和 TTSPanelView 只依賴 TTSCoordinator。
// 底層只使用 HTTP TTS 音訊播放器。
// 管理：sleep timer、MPNowPlayingInfo、AVAudioSession。

final class TTSCoordinator: ObservableObject {

    // MARK: - Published 狀態（與 TTSPanelView 繫結）
    @Published var isPlaying = false
    @Published private(set) var playbackState: TTSPlaybackState = .stopped
    @Published var speechRate: Float = 0.5
    @Published var sleepMinutes: Int = 0

    // MARK: - 回調（ReaderView 設定）
    var onPageFinished: (() -> String?)? {
        didSet { rewireCallbacks() }
    }
    var onStop: (() -> Void)? {
        didSet { rewireCallbacks() }
    }

    // MARK: - 引擎
    private let httpEngine = HTTPTTSEngine()
    private var currentEngine: TTSPlayable { httpEngine }
    private static weak var activeSystemMediaCoordinator: TTSCoordinator?

    private var sleepTimer: Timer?
    private var audioSessionActive = false
    private var nowPlayingTitle = "正在朗讀"
    private var nowPlayingElapsed: TimeInterval = 0
    private var nowPlayingDuration: TimeInterval = 1
    private var nowPlayingStartedAt: Date?
    private var audioInterruptionCancellable: AnyCancellable?
    private var routeChangeCancellable: AnyCancellable?
    private var shouldResumeAfterInterruption = false

    init() {
        rewireCallbacks()
        setupAudioSessionNotifications()
        ttsLog("[TTS][Coordinator] init")
    }

    // MARK: - 對外控制

    func speak(text: String, title: String = "") {
        ttsLog("[TTS][Coordinator] speak requested engine=http textCount=\(text.count) title=\(title) rate=\(speechRate)")
        guard !text.isEmpty else {
            ttsLog("[TTS][Coordinator] speak ignored empty text")
            return
        }
        guard activateAudioSession() else {
            ttsLog("[TTS][Coordinator] speak aborted audio session activation failed")
            return
        }
        ttsLog("[TTS][Coordinator] configure engine audio session ownership")
        currentEngine.configureAudioSessionOwnership(true)
        nowPlayingTitle = title.isEmpty ? "正在朗讀" : title
        nowPlayingElapsed = 0
        nowPlayingDuration = estimatedDuration(for: text)
        nowPlayingStartedAt = Date()
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
        ttsLog("[TTS][Coordinator] resume done coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
    }

    func toggle() {
        playbackState == .playing ? pause() : resume()
    }

    func stop(reason: String = "direct") {
        ttsLog("[TTS][Coordinator] stop requested reason=\(reason) coordinatorPlaying=\(isPlaying) enginePlaying=\(currentEngine.isPlaying)")
        let ownsSystemMedia = Self.activeSystemMediaCoordinator === self
        currentEngine.stop()
        isPlaying = false
        playbackState = .stopped
        cancelSleepTimer()
        if ownsSystemMedia {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            ttsLog("[TTS][Coordinator] stop skipped clearing system media because coordinator is not active owner")
        }
        nowPlayingTitle = "正在朗讀"
        nowPlayingElapsed = 0
        nowPlayingDuration = 1
        nowPlayingStartedAt = nil
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
        httpEngine.onPageFinished = { [weak self] in
            guard let self, self.isPlaying else { return nil }
            return self.onPageFinished?()
        }
        httpEngine.onStop = { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.playbackState = .stopped
                self?.onStop?()
            }
        }
    }

    // MARK: - 音頻會話

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

    // MARK: - 鎖屏控制面板

    private func setupRemoteCommands() {
        ttsLog("[TTS][Coordinator] configuring remote commands owner=\(ObjectIdentifier(self))")

        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled  = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.stopCommand.isEnabled  = false
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = false

        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.stopCommand.removeTarget(nil)

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
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
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
        info[MPMediaItemPropertyArtist] = "語音朗讀"
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentNowPlayingElapsed()
        info[MPMediaItemPropertyPlaybackDuration] = max(nowPlayingDuration, 1)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        ttsLog("[TTS][NowPlaying] update title=\(nowPlayingTitle) elapsed=\(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?? "?") duration=\(info[MPMediaItemPropertyPlaybackDuration] ?? "?") rate=\(info[MPNowPlayingInfoPropertyPlaybackRate] ?? "?") state=\(isPlaying ? "playing" : "paused")")
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

    // MARK: - 定時停止

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
