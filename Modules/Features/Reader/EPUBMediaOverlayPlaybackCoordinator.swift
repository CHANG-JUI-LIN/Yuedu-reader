import AVFoundation
import Combine
import Foundation

enum EPUBMediaOverlayPlaybackState: Equatable {
    case stopped
    case playing
    case paused
}

@MainActor
final class EPUBMediaOverlayPlaybackCoordinator: ObservableObject {
    @Published private(set) var playbackState: EPUBMediaOverlayPlaybackState = .stopped
    @Published private(set) var currentFragment: EPUBMediaOverlayFragment?
    @Published private(set) var currentChapterIndex: Int?
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var activeOverlay: EPUBMediaOverlay?
    private var activeAudioHref: String?

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    func play(
        overlay: EPUBMediaOverlay,
        chapterIndex: Int,
        resourceURL: (String) -> URL?
    ) {
        stop()
        guard let first = overlay.fragments.first,
              let url = resourceURL(first.audioHref)
        else {
            errorMessage = localized("無法載入媒體旁白")
            return
        }

        activeOverlay = overlay
        activeAudioHref = first.audioHref
        currentChapterIndex = chapterIndex
        currentFragment = first
        errorMessage = nil

        let nextPlayer = AVPlayer(url: url)
        player = nextPlayer
        installTimeObserver()
        if let start = first.clipBegin {
            nextPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        nextPlayer.play()
        playbackState = .playing
    }

    func pause() {
        player?.pause()
        playbackState = .paused
    }

    func resume() {
        player?.play()
        playbackState = .playing
    }

    func togglePlayback(
        overlay: EPUBMediaOverlay,
        chapterIndex: Int,
        resourceURL: (String) -> URL?
    ) {
        switch playbackState {
        case .stopped:
            play(overlay: overlay, chapterIndex: chapterIndex, resourceURL: resourceURL)
        case .playing:
            pause()
        case .paused:
            resume()
        }
    }

    func stop() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player?.pause()
        player = nil
        playbackState = .stopped
        currentFragment = nil
        currentChapterIndex = nil
        activeOverlay = nil
        activeAudioHref = nil
    }

    private func installTimeObserver() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.updateCurrentFragment(at: time.seconds)
            }
        }
    }

    private func updateCurrentFragment(at seconds: TimeInterval) {
        guard let overlay = activeOverlay,
              let activeAudioHref
        else { return }
        let fragments = overlay.fragments.filter { $0.audioHref == activeAudioHref }
        guard !fragments.isEmpty else { return }

        let matching = fragments.last { fragment in
            let begin = fragment.clipBegin ?? 0
            let end = fragment.clipEnd ?? .greatestFiniteMagnitude
            return seconds >= begin && seconds < end
        }
        if let matching {
            currentFragment = matching
        }

        if let lastEnd = fragments.compactMap(\.clipEnd).max(),
           seconds >= lastEnd {
            stop()
        }
    }
}
