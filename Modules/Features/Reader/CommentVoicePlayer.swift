import AVFoundation
import Combine
import Observation
import SwiftUI

/// Plays a comment's spoken clip. One clip at a time, app-wide: starting another stops the
/// first, and tapping the playing one stops it. The comment list stops it when it closes.
@MainActor
@Observable
final class CommentVoicePlayer {
    static let shared = CommentVoicePlayer()

    /// The clip playing now.
    private(set) var playingURL: URL?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusWatch: AnyCancellable?

    private init() {}

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
        } else {
            play(url)
        }
    }

    func stop() {
        player?.pause()
        player = nil
        playingURL = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        statusWatch = nil
    }

    private func play(_ url: URL) {
        stop()
        // 聽書 and 有聲書 set the session up for themselves (spoken audio, long-form); one
        // already playing back is left as it is, so starting a clip cannot change their mode.
        if AVAudioSession.sharedInstance().category != .playback {
            AudioSessionActivator.activate(category: .playback)
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playingURL = url
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard self?.playingURL == url else { return }
                    self?.stop()
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated { [weak self] in
                    AppLogger.error("comment voice stopped: \(url.absoluteString)", error: error)
                    guard self?.playingURL == url else { return }
                    self?.stop()
                }
            },
        ]
        // A clip that cannot be opened at all fails here, before it plays.
        statusWatch = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                MainActor.assumeIsolated {
                    AppLogger.error("comment voice unplayable: \(url.absoluteString)", error: item.error)
                    guard self?.playingURL == url else { return }
                    self?.stop()
                }
            }
        player.play()
    }
}

/// A comment's spoken clip: play and stop, in the card.
struct CommentVoiceButton: View {
    let url: URL
    var tint: Color = DSColor.accent
    var fill: Color = DSColor.accentLight
    @State private var player = CommentVoicePlayer.shared

    private var isPlaying: Bool { player.playingURL == url }

    var body: some View {
        Button {
            player.toggle(url)
        } label: {
            Label(localized(isPlaying ? "停止語音" : "播放語音"), systemImage: isPlaying ? "stop.fill" : "waveform")
                .font(DSFont.footnote.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)
                .background(fill, in: Capsule())
        }
        // A button in a List row: only its own taps play it.
        .buttonStyle(.borderless)
        .accessibilityIdentifier("comment.voice")
    }
}

/// A comment's pictures as thumbnails, the last saying how many more there are.
struct CommentImageStrip: View {
    let urls: [URL]
    var cornerRadius: CGFloat = DSRadius.sm

    var body: some View {
        let shown = Array(urls.prefix(DSLayout.commentImagesShown))
        HStack(spacing: DSSpacing.xs) {
            ForEach(shown.indices, id: \.self) { index in
                CommentAvatarImage(url: shown[index], placeholder: "photo")
                    .frame(width: DSLayout.commentImageSize, height: DSLayout.commentImageSize)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        if index == shown.count - 1, urls.count > shown.count {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(DSColor.commentImageMoreScrim)
                            Text(verbatim: "+\(urls.count - shown.count)")
                                .font(DSFont.headline)
                                .foregroundStyle(DSColor.commentImageMoreText)
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// A comment card is one element to VoiceOver, so its voice button is reached as an action.
    @ViewBuilder
    func commentVoiceAction(_ review: WorkReview, shown: Bool = true) -> some View {
        if shown, let voice = review.voice {
            accessibilityAction(named: Text(localized(CommentVoicePlayer.shared.playingURL == voice ? "停止語音" : "播放語音"))) {
                CommentVoicePlayer.shared.toggle(voice)
            }
        } else {
            self
        }
    }
}
