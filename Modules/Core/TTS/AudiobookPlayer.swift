import AVFoundation
import Combine
import Foundation

// MARK: - Audiobook Player (AVPlayer wrapper)

final class AudiobookPlayer: NSObject, ObservableObject {

    static let shared = AudiobookPlayer()

    // MARK: - Published State

    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var currentTitle: String = ""
    @Published var playbackRate: Float = 1.0

    // MARK: - Private Members

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var cancellables: Set<AnyCancellable> = []

    override private init() {
        super.init()
    }

    // MARK: - Playback

    func play(url: URL, title: String) {
        error = nil
        currentTitle = title
        isLoading = true

        // Activate audio session for background playback
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        // Stop existing player
        stopInternal()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.rate = 0  // Wait for readyToPlay before playing
        player = newPlayer

        // Observe status to detect readyToPlay and error
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
                    self.error = item.error?.localizedDescription ?? "Playback failed"
                    self.isPlaying = false
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Periodic playback progress update (0.5s interval)
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self, self.isPlaying else { return }
            self.currentTime = time.seconds
            self.updateDuration()
        }

        // Playback finished notification
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

    // MARK: - Pause / Resume

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.rate = playbackRate
        isPlaying = true
    }

    // MARK: - Stop

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

    // MARK: - Seek

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

    // MARK: - Playback Rate

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    // MARK: - Duration Update

    private func updateDuration() {
        guard let item = player?.currentItem, item.status == .readyToPlay else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }
}

