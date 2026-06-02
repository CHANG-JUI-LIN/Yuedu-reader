import AVFoundation
import SwiftUI

// MARK: - Audiobook Player Interface

struct AudiobookView: View {

    let chapterTitle: String
    let audioUrl: URL

    @StateObject private var player = AudiobookPlayer.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var sliderValue: Double = 0
    @State private var isDraggingSlider: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(DSColor.textSecondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 16)

            VStack(spacing: 20) {

                // Chapter title
                Text(chapterTitle)
                    .font(.headline)
                    .foregroundColor(DSColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal)

                // Error prompt
                if let errMsg = player.error {
                    VStack(spacing: 8) {
                        Text(errMsg)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)

                        Button(localized("重試")) {
                            player.play(url: audioUrl, title: chapterTitle)
                        }
                        .foregroundColor(DSColor.accent)
                    }
                    .padding(.horizontal)
                }

                // Progress bar
                VStack(spacing: 4) {
                    Slider(
                        value: $sliderValue,
                        in: 0...max(player.duration, 1),
                        onEditingChanged: { editing in
                            isDraggingSlider = editing
                            if !editing {
                                player.seek(to: sliderValue)
                            }
                        }
                    )
                    .accentColor(DSColor.accent)
                    .disabled(player.isLoading)

                    HStack {
                        Text(formatTime(player.currentTime))
                            .font(.caption)
                            .foregroundColor(DSColor.textSecondary)
                        Spacer()
                        Text(formatTime(player.duration))
                            .font(.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
                .padding(.horizontal, 24)

                // Playback controls
                HStack {
                    Button {
                        player.skipBack(15)
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DSColor.textPrimary)
                    }
                    .disabled(player.isLoading)

                    Spacer()

                    // Play / Pause (48pt)
                    Button {
                        if player.isLoading { return }
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.resume()
                        }
                    } label: {
                        if player.isLoading {
                            ProgressView()
                                .frame(width: 48, height: 48)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(DSColor.accent)
                        }
                    }

                    Spacer()

                    Button {
                        player.skipForward(30)
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DSColor.textPrimary)
                    }
                    .disabled(player.isLoading)
                }
                .padding(.horizontal, 40)

                // Playback rate selector
                Picker(localized("速度"), selection: Binding(
                    get: { player.playbackRate },
                    set: { player.setRate($0) }
                )) {
                    Text("0.75x").tag(Float(0.75))
                    Text("1.0x").tag(Float(1.0))
                    Text("1.25x").tag(Float(1.25))
                    Text("1.5x").tag(Float(1.5))
                    Text("2.0x").tag(Float(2.0))
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            player.play(url: audioUrl, title: chapterTitle)
        }
        .onDisappear {
            player.stop()
        }
        .onReceive(player.$currentTime) { t in
            if !isDraggingSlider {
                sliderValue = t
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ t: TimeInterval) -> String {
        let seconds = max(0, Int(t))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
