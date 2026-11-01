import SwiftUI

/// 選集: one 線路's episodes, the 線路 picked above them as Swiftfin picks a season. Opened
/// from the player and from the detail page's 全部.
struct VideoEpisodeSheet: View {
    let guide: VideoEpisodeGuide
    /// The episode playing or to resume; nil when none has been played.
    let current: Int?
    let title: (Int) -> String
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var routeID: Int

    init(guide: VideoEpisodeGuide, current: Int?, title: @escaping (Int) -> String,
         onSelect: @escaping (Int) -> Void) {
        self.guide = guide
        self.current = current
        self.title = title
        self.onSelect = onSelect
        _routeID = State(initialValue: current.flatMap { guide.route(containing: $0)?.id } ?? 0)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if guide.routes.count > 1 {
                        Section {
                            Picker(localized("線路"), selection: $routeID) {
                                ForEach(guide.routes) { route in
                                    Text(VideoEpisodeNaming.routeName(route)).tag(route.id)
                                }
                            }
                        }
                    }
                    Section {
                        ForEach(episodes, id: \.self) { chapterIndex in
                            row(chapterIndex)
                                .id(chapterIndex)
                        }
                    }
                }
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .navigationTitle(localized("選集"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
        }
    }

    private var episodes: [Int] {
        guide.routes.first { $0.id == routeID }?.episodes ?? []
    }

    private func row(_ chapterIndex: Int) -> some View {
        let isCurrent = chapterIndex == current
        return Button { onSelect(chapterIndex) } label: {
            HStack(spacing: DSSpacing.md) {
                Text(VideoEpisodeNaming.episodeName(chapterIndex, in: guide, title: title))
                    .font(DSFont.body)
                    .foregroundStyle(isCurrent ? DSColor.accent : DSColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// How an episode and a 線路 are named where the source gives no name.
enum VideoEpisodeNaming {
    static func routeName(_ route: VideoEpisodeGuide.Route) -> String {
        route.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(format: localized("線路 %d"), route.id + 1)
    }

    /// The source's title, or 「第 N 集」 when it has none.
    static func episodeName(_ chapterIndex: Int, in guide: VideoEpisodeGuide, title: (Int) -> String) -> String {
        let name = title(chapterIndex).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return String(format: localized("第 %d 集"), guide.episodeNumber(of: chapterIndex) ?? chapterIndex + 1)
    }

    /// Where 繼續播放 picks up: the episode, after its 線路 when there are several.
    static func resumeDetail(_ chapterIndex: Int, in guide: VideoEpisodeGuide, title: (Int) -> String) -> String {
        let episode = episodeName(chapterIndex, in: guide, title: title)
        guard guide.routes.count > 1, let route = guide.route(containing: chapterIndex) else { return episode }
        return "\(routeName(route)) · \(episode)"
    }
}

#Preview {
    let chapters = [
        OnlineChapterRef(index: 0, title: "線路一", url: "", isVolume: true),
        OnlineChapterRef(index: 1, title: "第1集", url: "https://example.com/1.m3u8"),
        OnlineChapterRef(index: 2, title: "第2集", url: "https://example.com/2.m3u8"),
        OnlineChapterRef(index: 3, title: "線路二", url: "", isVolume: true),
        OnlineChapterRef(index: 4, title: "", url: "https://example.com/b1.m3u8"),
    ]
    VideoEpisodeSheet(
        guide: VideoEpisodeGuide(chapters: chapters), current: 2,
        title: { chapters[$0].title }, onSelect: { _ in }
    )
}
