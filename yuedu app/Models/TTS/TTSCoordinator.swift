import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - TTS 協調器
//
// 統一對外介面：ReaderView 和 TTSPanelView 只依賴 TTSCoordinator。
// 根據 GlobalSettings.ttsEngine 選擇底層引擎（TTSManager / HTTPTTSEngine）。
// 管理：sleep timer、MPNowPlayingInfo、AVAudioSession。

final class TTSCoordinator: ObservableObject {

    // MARK: - Published 狀態（與 TTSPanelView 繫結）
    @Published var isPlaying = false
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
    private let systemEngine = TTSManager()
    private let httpEngine   = HTTPTTSEngine()
    private var currentEngine: TTSPlayable { engineFor(GlobalSettings.shared.ttsEngine) }

    private var gsCancellable: AnyCancellable?
    private var sleepTimer: Timer?
    private var audioSessionActive = false

    init() {
        rewireCallbacks()
        gsCancellable = GlobalSettings.shared.$ttsEngine
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleEngineSwitch() }
    }

    // MARK: - 對外控制

    func speak(text: String, title: String = "") {
        guard !text.isEmpty else { return }
        activateAudioSession()
        currentEngine.speak(text: text, title: title, rate: speechRate)
        isPlaying = true
        updateNowPlaying(title: title)
        if sleepMinutes > 0 { startSleepTimer() }
    }

    func pause() {
        currentEngine.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        activateAudioSession()
        currentEngine.resume()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func stop() {
        currentEngine.stop()
        isPlaying = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    func updateRate(_ rate: Float) {
        speechRate = max(AVSpeechUtteranceMinimumSpeechRate,
                         min(rate, AVSpeechUtteranceMaximumSpeechRate))
    }

    func setSleepTimer(minutes: Int) {
        sleepMinutes = minutes
        if isPlaying && minutes > 0 { startSleepTimer() } else { cancelSleepTimer() }
    }

    // MARK: - 引擎切換

    private func engineFor(_ type: GlobalSettings.TTSEngineType) -> TTSPlayable {
        type == .system ? systemEngine : httpEngine
    }

    private func handleEngineSwitch() {
        if isPlaying { stop() }
        rewireCallbacks()
    }

    private func rewireCallbacks() {
        // system engine
        systemEngine.onPageFinished = { [weak self] in
            guard let self, self.isPlaying else { return nil }
            return self.onPageFinished?()
        }
        systemEngine.onStop = { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.onStop?()
            }
        }
        // http engine
        httpEngine.onPageFinished = { [weak self] in
            guard let self, self.isPlaying else { return nil }
            return self.onPageFinished?()
        }
        httpEngine.onStop = { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.onStop?()
            }
        }
    }

    // MARK: - 音頻會話

    private func activateAudioSession() {
        guard !audioSessionActive else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
        audioSessionActive = true
        UIApplication.shared.beginReceivingRemoteControlEvents()
        setupRemoteCommands()
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        UIApplication.shared.endReceivingRemoteControlEvents()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        audioSessionActive = false
    }

    // MARK: - 鎖屏控制面板

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled  = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.stopCommand.isEnabled  = true

        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.stopCommand.removeTarget(nil)

        c.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.toggle() }
            return .success
        }
        c.stopCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
            return .success
        }
    }

    private func updateNowPlaying(title: String = "") {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title.isEmpty ? "正在朗讀" : title
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 定時停止

    private func startSleepTimer() {
        cancelSleepTimer()
        guard sleepMinutes > 0 else { return }
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(sleepMinutes * 60),
            repeats: false
        ) { [weak self] _ in DispatchQueue.main.async { self?.stop() } }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    deinit { stop() }
}
