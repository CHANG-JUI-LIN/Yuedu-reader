import AVFoundation
import Combine
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

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 控制方法

    func speak(text: String, title: String = "") {
        self.currentText = text
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = speechRate
        utterance.voice =
            AVSpeechSynthesisVoice(language: "zh-TW")
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        synthesizer.speak(utterance)
        isPlaying = true

        if sleepMinutes > 0 {
            startSleepTimer()
        }
    }

    func pause() {
        guard isPlaying else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPlaying = false
    }

    func resume() {
        guard !isPlaying else { return }
        synthesizer.continueSpeaking()
        isPlaying = true
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        cancelSleepTimer()
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

// MARK: - TTSPlayable
extension TTSManager: TTSPlayable {
    func speak(text: String, title: String, rate: Float) {
        updateRate(rate)
        speak(text: text, title: title)
    }
}
