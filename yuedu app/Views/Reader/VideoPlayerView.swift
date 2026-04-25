import SwiftUI
import AVKit

/// Full-screen video player for book sources with bookSourceType == 3.
/// Accepts a URL string (resolved from the chapter content rule).
struct VideoPlayerView: View {
    let videoUrlString: String
    let title: String

    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer? = nil
    @State private var isLoading: Bool = true
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onDisappear { player.pause() }
            } else if isLoading {
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text(localized("載入中...")).foregroundColor(.white)
                }
            } else if let errorMessage = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.yellow)
                    Text(errorMessage).foregroundColor(.white).multilineTextAlignment(.center)
                    Button(localized("重試")) { loadVideo() }
                        .foregroundColor(DSColor.accent)
                }
                .padding()
            }

            // Top bar
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadVideo() }
    }

    private func loadVideo() {
        isLoading = true
        errorMessage = nil
        player = nil
        guard let url = URL(string: videoUrlString) else {
            isLoading = false
            errorMessage = localized("無效的影片網址")
            return
        }
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        isLoading = false
        avPlayer.play()
    }
}
