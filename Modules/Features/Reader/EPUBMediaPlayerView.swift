import AVKit
import SwiftUI

struct EPUBMediaPlayerView: View {
    let media: EPUBMediaAttachment

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if media.kind == .video {
                videoBody
            } else {
                audioBody
            }
        }
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
    }

    private var videoBody: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                mediaStatus
            }
            closeButton
                .padding(16)
        }
    }

    private var audioBody: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
                Text(displayTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(media.sourceHref)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button {
                    togglePlayback()
                } label: {
                    Label(isPlaying ? localized("暫停") : localized("播放"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(player == nil)
            }
            .padding(24)
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("完成")) { dismiss() }
                }
            }
        }
    }

    private var mediaStatus: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .tint(.white)
                Text(localized("載入中..."))
                    .foregroundStyle(.white)
            }
        }
        .padding()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
    }

    private var displayTitle: String {
        let title = media.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return media.kind == .video ? "EPUB Video" : "EPUB Audio"
    }

    private func load() {
        guard player == nil else { return }
        guard let url = URL(string: media.sourceHref) else {
            errorMessage = localized("無效的媒體網址")
            return
        }
        let nextPlayer = AVPlayer(url: url)
        player = nextPlayer
        if media.kind == .video {
            nextPlayer.play()
            isPlaying = true
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}
