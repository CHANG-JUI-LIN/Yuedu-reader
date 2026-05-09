import AVFoundation
import Combine
import Foundation

// MARK: - 有聲書播放器（AVPlayer 封裝）

final class AudiobookPlayer: NSObject, ObservableObject {

    static let shared = AudiobookPlayer()

    // MARK: - 已發佈狀態

    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var currentTitle: String = ""
    @Published var playbackRate: Float = 1.0

    // MARK: - 私有成員

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var cancellables: Set<AnyCancellable> = []

    override private init() {
        super.init()
    }

    // MARK: - 播放

    func play(url: URL, title: String) {
        error = nil
        currentTitle = title
        isLoading = true

        // 啟用音頻會話（背景播放）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 停止舊的播放器
        stopInternal()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.rate = 0  // 等 readyToPlay 後再播放
        player = newPlayer

        // 監聽 status 以偵測 readyToPlay 和 error
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    self.updateDuration()
                    self.player?.rate = self.playbackRate
                    self.isPlaying = true
                case .failed:
                    self.isLoading = false
                    self.error = item.error?.localizedDescription ?? "播放失敗"
                    self.isPlaying = false
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // 定期更新播放進度（0.5 秒）
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self, self.isPlaying else { return }
            self.currentTime = time.seconds
            self.updateDuration()
        }

        // 播放完畢通知
        NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.isPlaying = false
            self?.currentTime = self?.duration ?? 0
        }
        .store(in: &cancellables)
    }

    // MARK: - 暫停 / 繼續

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.rate = playbackRate
        isPlaying = true
    }

    // MARK: - 停止

    func stop() {
        stopInternal()
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = false
        currentTitle = ""
    }

    private func stopInternal() {
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        cancellables.removeAll()
        player = nil
    }

    // MARK: - 快進 / 快退

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player?.seek(to: target)
    }

    func skipForward(_ seconds: Double = 30) {
        seek(to: currentTime + seconds)
    }

    func skipBack(_ seconds: Double = 15) {
        seek(to: currentTime - seconds)
    }

    // MARK: - 播放速率

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    // MARK: - 更新總時長

    private func updateDuration() {
        guard let item = player?.currentItem, item.status == .readyToPlay else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }
}


