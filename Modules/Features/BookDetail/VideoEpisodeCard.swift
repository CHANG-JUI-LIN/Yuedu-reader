import SwiftUI

/// One episode in 選集, as VidHub's episode stills: a frame of the episode once it has been
/// taken (`VideoEpisodeStills`), its number in that frame until then and when it cannot be;
/// under it 第 N 集 — with the running time once the stream has said it — and the source's own
/// name for the episode as its title. A white ring marks the episode 繼續播放 resumes.
struct VideoEpisodeCard: View {
    let number: Int
    /// The source's name for the episode, when it says more than 第 N 集.
    let sourceName: String?
    /// What VoiceOver reads the card as.
    let name: String
    let isResume: Bool
    /// The still's cache key; nil when the episode has no address to take one from.
    let stillKey: String?
    let loadStill: @MainActor () async -> VideoEpisodeStill?
    let action: () -> Void

    /// The still and the key it was taken for: a card that keeps its place while its episode's
    /// address changes must not go on showing the old episode's frame.
    @State private var taken: (key: String, still: VideoEpisodeStill)?

    init(
        number: Int,
        sourceName: String?,
        name: String,
        isResume: Bool,
        stillKey: String?,
        loadStill: @escaping @MainActor () async -> VideoEpisodeStill?,
        action: @escaping () -> Void
    ) {
        self.number = number
        self.sourceName = sourceName
        self.name = name
        self.isResume = isResume
        self.stillKey = stillKey
        self.loadStill = loadStill
        self.action = action
        // A card scrolled back into view shows its still at once, not its number for a frame.
        _taken = State(initialValue: stillKey.flatMap { key in
            VideoEpisodeStills.shared.cachedStill(forKey: key).map { (key, $0) }
        })
    }

    private var still: VideoEpisodeStill? {
        guard let taken, taken.key == stillKey else { return nil }
        return taken.still
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                frame
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(caption)
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundStyle(DSColor.textSecondary)
                    if let sourceName {
                        Text(sourceName)
                            .font(DSFont.title3.weight(.bold))
                            .foregroundStyle(DSColor.textPrimary)
                    }
                }
                .lineLimit(1)
                .frame(width: DSLayout.videoEpisodeCardWidth, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue)
        .task(id: stillKey) {
            guard let stillKey, still == nil, let loaded = await loadStill() else { return }
            withAnimation(DSAnimation.standard) { taken = (stillKey, loaded) }
        }
    }

    private var frame: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        return ZStack {
            if let image = still?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Text(number.formatted())
                    .font(DSFont.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(DSColor.textPrimary)
            }
        }
        .frame(width: DSLayout.videoEpisodeCardWidth, height: DSLayout.videoEpisodeCardHeight)
        .background(DSColor.neutralControlFill)
        .clipShape(shape)
        .overlay {
            if isResume {
                RoundedRectangle(cornerRadius: DSRadius.md + DSLayout.videoEpisodeResumeRingOutset, style: .continuous)
                    .stroke(DSColor.textPrimary, lineWidth: DSLayout.videoEpisodeResumeStroke)
                    .padding(-DSLayout.videoEpisodeResumeRingOutset)
            }
        }
    }

    private var minutes: Int? {
        still?.duration.map(VideoEpisodeRunningTime.minutes)
    }

    private var caption: String {
        guard let minutes else { return String(format: localized("第 %d 集"), number) }
        return String(format: localized("第 %d 集 · %d 分鐘"), number, minutes)
    }

    private var accessibilityValue: String {
        [isResume ? localized("繼續播放") : nil, minutes.map { String(format: localized("%d 分鐘"), $0) }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// A run of 選集's episodes, as VidHub's 「1 · 30」 under its episode row.
struct VideoEpisodeRange: Identifiable, Equatable {
    /// The run's chapter indices, in the 線路's order.
    let episodes: [Int]
    let firstNumber: Int
    let lastNumber: Int

    var id: Int { episodes[0] }

    /// Episodes a run holds, as VidHub's.
    static let size = 30

    /// The 線路's episodes in runs of `size`, each named by its first and last episode numbers.
    static func ranges(of episodes: [Int], number: (Int) -> Int) -> [VideoEpisodeRange] {
        stride(from: 0, to: episodes.count, by: size).map { start in
            let run = Array(episodes[start..<min(start + size, episodes.count)])
            return VideoEpisodeRange(episodes: run, firstNumber: number(run[0]), lastNumber: number(run[run.count - 1]))
        }
    }
}

/// Under 選集's row: its runs of episodes, when there is more than one, each a capsule that
/// scrolls the row to the run's first episode, the one the row is in marked; and at the end
/// an arrow to the 線路's last episode.
struct VideoEpisodeRangeBar: View {
    let ranges: [VideoEpisodeRange]
    let selected: VideoEpisodeRange.ID?
    let onSelect: (VideoEpisodeRange) -> Void
    let onLast: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            if ranges.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: DSSpacing.md) {
                            ForEach(ranges) { range in
                                chip(range)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selected) { _, selected in
                        guard let selected else { return }
                        withAnimation(DSAnimation.standard) { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
            Button(action: onLast) {
                Image(systemName: "arrow.right.to.line")
                    .font(DSFont.title2)
                    .foregroundStyle(DSColor.textPrimary)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("跳到最後一集"))
        }
    }

    private func chip(_ range: VideoEpisodeRange) -> some View {
        let isSelected = range.id == selected
        return Button { onSelect(range) } label: {
            Text(String(format: localized("%1$d · %2$d"), range.firstNumber, range.lastNumber))
                .font(DSFont.headline.monospacedDigit())
                .foregroundStyle(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
                .padding(.horizontal, DSSpacing.lg)
                .frame(height: DSLayout.videoEpisodeRangeHeight)
                .background(
                    DSColor.textPrimary.opacity(isSelected ? DSLayout.videoEpisodeRangeSelectedFillOpacity
                                                           : DSLayout.videoEpisodeRangeFillOpacity),
                    in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                )
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(range.id)
        .accessibilityLabel(String(format: localized("第 %1$d 至 %2$d 集"), range.firstNumber, range.lastNumber))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An episode's running time as 選集 writes it: whole minutes, never 0 for an episode under one.
enum VideoEpisodeRunningTime {
    static func minutes(_ duration: TimeInterval) -> Int {
        max(1, Int((duration / 60).rounded()))
    }
}

#Preview {
    let ranges = VideoEpisodeRange.ranges(of: Array(0..<37)) { $0 + 1 }
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            VideoEpisodeCard(number: 1, sourceName: nil, name: "第 1 集", isResume: true, stillKey: nil,
                             loadStill: { nil }, action: {})
            VideoEpisodeCard(number: 2, sourceName: "重逢", name: "第 2 集 重逢", isResume: false, stillKey: nil,
                             loadStill: { nil }, action: {})
        }
        VideoEpisodeRangeBar(ranges: ranges, selected: ranges[0].id, onSelect: { _ in }, onLast: {})
    }
    .padding()
    .background(DSColor.background)
}
