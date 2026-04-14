import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - TTS 語音朗讀管理器

/// AVSpeechSynthesizer 朗讀 + 背景播放 + 鎖屏控制面板 + 定時停止
final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    // MARK: - 狀態
    @Published var isPlaying = false
    @Published var speechRate: Float = 0.5  // AVSpeechUtteranceDefaultSpeechRate
    @Published var sleepMinutes: Int = 0  // 0 = 不定時停止

    // 回調
    var onPageFinished: (() -> String?)?  // 朗讀完當前頁 → 取得下一頁文本
    var onStop: (() -> Void)?

    // 內部
    private let synthesizer = AVSpeechSynthesizer()
    private var sleepTimer: Timer?
    private var currentText: String = ""
    private var audioSessionActive = false

    override init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommands()
    }

    // MARK: - 音頻會話（背景播放）
    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            audioSessionActive = true
        } catch { }
    }

    private func deactivateAudioSessionIfNeeded() {
        guard audioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch { }
        audioSessionActive = false
    }

    // MARK: - 鎖屏控制面板
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.toggle()
            return .success
        }

        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
    }

    private func updateNowPlaying(title: String = "正在朗讀") {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 控制方法

    func speak(text: String, title: String = "") {
        self.currentText = text
        synthesizer.stopSpeaking(at: .immediate)
        activateAudioSessionIfNeeded()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = speechRate
        utterance.voice =
            AVSpeechSynthesisVoice(language: "zh-TW")
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        synthesizer.speak(utterance)
        isPlaying = true
        updateNowPlaying(title: title.isEmpty ? "正在朗讀" : title)

        if sleepMinutes > 0 {
            startSleepTimer()
        }
    }

    func pause() {
        guard isPlaying else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
        deactivateAudioSessionIfNeeded()
    }

    func resume() {
        guard !isPlaying else { return }
        activateAudioSessionIfNeeded()
        synthesizer.continueSpeaking()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSessionIfNeeded()
        onStop?()
    }

    func updateRate(_ rate: Float) {
        speechRate = max(
            AVSpeechUtteranceMinimumSpeechRate,
            min(rate, AVSpeechUtteranceMaximumSpeechRate))
    }

    // MARK: - 定時停止

    func setSleepTimer(minutes: Int) {
        sleepMinutes = minutes
        if isPlaying && minutes > 0 {
            startSleepTimer()
        } else {
            cancelSleepTimer()
        }
    }

    private func startSleepTimer() {
        cancelSleepTimer()
        guard sleepMinutes > 0 else { return }
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(sleepMinutes * 60),
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stop()
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// 朗讀完一段 → 自動取下一頁
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isPlaying else { return }
            if let nextText = self.onPageFinished?(), !nextText.isEmpty {
                self.speak(text: nextText)
            } else {
                self.stop()
            }
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
        }
    }

    deinit {
        stop()
    }
}
