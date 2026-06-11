import SwiftUI

struct EPUBMediaOverlayPlayerView: View {
    let title: String
    let overlay: EPUBMediaOverlay
    let chapterIndex: Int
    @ObservedObject var coordinator: EPUBMediaOverlayPlaybackCoordinator
    let resourceURL: (String) -> URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "waveform.and.person.filled")
                    .font(.system(size: 58))
                    .foregroundStyle(.tint)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("\(overlay.fragments.count) \(localized("段落"))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let fragment = coordinator.currentFragment {
                    Text(fragment.textFragmentID ?? fragment.id)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let error = coordinator.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button {
                        coordinator.stop()
                    } label: {
                        Label(localized("停止"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.playbackState == .stopped)

                    Button {
                        coordinator.togglePlayback(
                            overlay: overlay,
                            chapterIndex: chapterIndex,
                            resourceURL: resourceURL
                        )
                    } label: {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .navigationTitle(localized("媒體旁白"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
    }

    private var primaryActionTitle: String {
        switch coordinator.playbackState {
        case .playing:
            return localized("暫停")
        case .paused:
            return localized("繼續")
        case .stopped:
            return localized("播放")
        }
    }

    private var primaryActionIcon: String {
        switch coordinator.playbackState {
        case .playing:
            return "pause.fill"
        case .paused, .stopped:
            return "play.fill"
        }
    }
}
