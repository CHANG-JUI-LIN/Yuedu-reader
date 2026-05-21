import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var gs = GlobalSettings.shared
    @StateObject private var rssStore = RSSStore.shared

    private var rssUnreadCount: Int {
        rssStore.totalUnreadCount()
    }

    var body: some View {
        TabView {

            Tab(localized("書架"), systemImage: "books.vertical") {
                HomeView()
            }

            Tab(localized("瀏覽"), systemImage: "globe") {
                BrowserView()
            }

            Tab(localized("RSS 訂閱"), systemImage: "newspaper") {
                RSSListView()
            }
            .badge(rssUnreadCount > 0 ? Text("\(rssUnreadCount)") : nil)
            
            Tab(localized("設定"), systemImage: "gearshape") {
                SettingsView()
            }
            Tab(role: .search) {
                NavigationStack {
                    SearchView()
                }
            }
        }
    }
}
struct TTSFloatingPlayerOverlay: View {
    @StateObject private var player = TTSFloatingPlayerState.shared
    @State private var offset = CGSize(width: 0, height: 0)
    @State private var dragStartOffset: CGSize?
    @State private var lastDragEndedAt = Date.distantPast
    var defaultBottomClearance: CGFloat = 136

    var body: some View {
        GeometryReader { proxy in
            if player.isVisible {
                miniPlayerView
                    .frame(width: contentWidth)
                    .position(position(in: proxy.size))
                    .simultaneousGesture(dragGesture(in: proxy.size))
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: player.isVisible)
    }

    private var miniPlayerView: some View {
        HStack(spacing: 12) {
            Button {
                performTapAction {
                    player.openPanel()
                }
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                performTapAction {
                    player.togglePlayback()
                }
            } label: {
                Image(systemName: player.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2))
            }

            Button {
                performTapAction {
                    player.stop()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 34, height: 48)
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .contentShape(Capsule())
        .accessibilityLabel(player.title.isEmpty ? localized("語音朗讀") : player.title)
    }

    private var contentWidth: CGFloat {
        148
    }

    private var contentHeight: CGFloat {
        64
    }

    private func position(in size: CGSize) -> CGPoint {
        CGPoint(
            x: contentWidth / 2 + 26 + offset.width,
            y: defaultCenterY(in: size) + offset.height
        )
    }

    private func defaultCenterY(in size: CGSize) -> CGFloat {
        size.height - defaultBottomClearance - contentHeight / 2
    }

    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let width = contentWidth
        let leadingCenter = width / 2 + 26
        let minCenter = width / 2 + 14
        let maxCenter = size.width - width / 2 - 14
        let horizontalLimitLeft = minCenter - leadingCenter
        let horizontalLimitRight = maxCenter - leadingCenter
        let defaultCenterY = defaultCenterY(in: size)
        let topCenter = contentHeight / 2 + 14
        let bottomCenter = size.height - defaultBottomClearance - contentHeight / 2
        let topLimit = topCenter - defaultCenterY
        let bottomLimit = bottomCenter - defaultCenterY
        return CGSize(
            width: min(max(proposed.width, horizontalLimitLeft), horizontalLimitRight),
            height: min(max(proposed.height, topLimit), bottomLimit)
        )
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                let start = dragStartOffset ?? .zero
                offset = clampedOffset(
                    CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ),
                    in: size
                )
            }
            .onEnded { _ in
                offset = clampedOffset(offset, in: size)
                dragStartOffset = nil
                lastDragEndedAt = Date()
            }
    }

    private func performTapAction(_ action: () -> Void) {
        guard Date().timeIntervalSince(lastDragEndedAt) > 0.18 else { return }
        action()
    }
}

#Preview {
    ContentView()
        .environmentObject(BookStore())
}
