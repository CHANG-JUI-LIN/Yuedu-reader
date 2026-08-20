import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island presentation for offline book downloads.
///
/// Laid out like the system's own download activity: cover, one line naming what is being
/// downloaded, one line of progress, and a single round control on the trailing edge.
///
/// Strings are written in place rather than localized, and colors are system semantic values:
/// the widget extension syncs only `Widget/`, so it can reach neither `Resources/*.lproj` and
/// `localized()` nor `DSColor` in `Modules/SharedUI`. The existing `YueduWidget` already does
/// this (`"閱讀進度"`); following it beats inventing a second convention.
struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadRow(state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                // Keep the cohesive row in the full-width center region, but remove that
                // region's default top margin. This is WidgetKit's supported way to pull the
                // content up toward the TrueDepth camera without offsets or negative padding.
                DynamicIslandExpandedRegion(.center) {
                    DownloadRow(state: context.state, leadingInset: 4)
                }
                .contentMargins(.top, 0)
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "arrow.down")
                    .accessibilityHidden(true)
            } compactTrailing: {
                Text(chapterCount(context.state))
                    .font(.caption2.monospacedDigit())
                    .accessibilityHidden(true)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "arrow.down")
                    .accessibilityHidden(true)
            }
            .keylineTint(.accentColor)
        }
    }
}

// MARK: - Text

/// `正在下載《書名》…`, or the queue size once more than one book is running. Free functions
/// rather than methods so the Lock Screen view and the Dynamic Island phrase things the same
/// way — they are two presentations of one activity, not two features.
private func titleLine(_ state: DownloadActivityAttributes.ContentState) -> String {
    guard let featured = state.books.first else { return "下載已完成" }
    if state.isPaused { return "已暫停《\(featured.title)》" }
    return "正在下載《\(featured.title)》"
}

/// The progress line: this book, then the queue behind it. Mirrors "852.9 MB of 1.07 GB".
private func progressLine(_ state: DownloadActivityAttributes.ContentState) -> String {
    guard let featured = state.books.first else { return "" }
    let own = "第 \(featured.completedChapters) 章，共 \(featured.totalChapters) 章"
    guard state.books.count > 1 else { return own }
    // The queue behind this book. It used to live on its own line under the progress bar;
    // there is no room for that line in a single row, and the count matters more than its
    // placement did.
    return "\(own)・另有 \(state.books.count - 1) 本"
}

private func chapterCount(_ state: DownloadActivityAttributes.ContentState) -> String {
    "\(state.completedChapters)/\(state.totalChapters)"
}

/// One spoken sentence for the whole activity. Every visual element is hidden from VoiceOver
/// so it never reads a symbol name or a bare fraction; only the button keeps its own label,
/// because it is the only thing here that can be activated.
private func spokenSummary(_ state: DownloadActivityAttributes.ContentState) -> String {
    guard let featured = state.books.first else { return "下載已完成" }
    let status = state.isPaused ? "下載已暫停" : "正在下載"
    let queue = state.books.count > 1 ? "，另有 \(state.books.count - 1) 本等待中" : ""
    return "\(status)：\(featured.title)，已完成 \(featured.completedChapters) 章，共 \(featured.totalChapters) 章\(queue)"
}

// MARK: - Pieces

/// The book cover, read from the shared container the app publishes it into.
///
/// Falls back to a glyph rather than an empty box: a book with no saved cover is ordinary, and
/// a hole where the artwork belongs reads as a bug.
private struct CoverView: View {
    let filename: String?
    /// Sized to the text block beside it, so the row reads as one unit rather than a small
    /// picture floating next to two lines.
    var height: CGFloat

    /// Book covers are close enough to 2:3 that anything squarer looks cropped.
    private var width: CGFloat { height * 2 / 3 }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.25)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: height * 0.36))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }

    private var loadedImage: UIImage? {
        guard let filename,
              let url = DownloadActivityAttributes.coverURL(filename: filename),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }
}

/// The round trailing control. Pause and resume rather than cancel: a stray tap on a lock
/// screen must not be able to throw away a download that is most of the way done.
private struct PauseButton: View {
    let book: DownloadActivityAttributes.ContentState.Book

    var body: some View {
        Button(intent: ToggleDownloadPauseIntent(bookId: book.id)) {
            Image(systemName: book.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .bold))
                // Comfortably tappable without dominating the row — it is one control beside
                // a cover and two lines of text, not the subject of the activity.
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.22), in: Circle())
                .accessibilityHidden(true)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .buttonStyle(.plain)
        .tint(.accentColor)
        .accessibilityLabel(book.isPaused ? "繼續下載" : "暫停下載")
    }
}

/// The text and progress shared by the Lock Screen and expanded Dynamic Island rows.
private struct DownloadDetails: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(titleLine(state))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(progressLine(state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: state.fraction)
                .progressViewStyle(.linear)
                .tint(state.isPaused ? .secondary : .accentColor)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary(state))
    }
}

/// Cover, title, progress, control — one row, used by both the Lock Screen banner and the
/// expanded Dynamic Island. The island gives this row full width through region priority.
private struct DownloadRow: View {
    let state: DownloadActivityAttributes.ContentState
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            CoverView(filename: state.books.first?.coverFilename, height: 46)
                .padding(.leading, leadingInset)

            // Under the text it describes, not spanning the whole surface: the bar is this
            // book's progress, so it should be the width of this book's block.
            DownloadDetails(state: state)

            if let featured = state.books.first {
                PauseButton(book: featured)
            }
        }
    }
}

#if DEBUG
private let previewState = DownloadActivityAttributes.ContentState(
    books: [
        .init(
            id: UUID().uuidString,
            title: "巫師：從合成寶石開始",
            completedChapters: 4,
            totalChapters: 50,
            isPaused: false,
            coverFilename: nil
        )
    ]
)

#Preview(
    "Download — expanded Dynamic Island",
    as: .dynamicIsland(.expanded),
    using: DownloadActivityAttributes()
) {
    DownloadLiveActivityWidget()
} contentStates: {
    previewState
}

#Preview("Download row — running") {
    DownloadRow(
        state: previewState
    )
    .padding()
}

#Preview("Download row — paused") {
    DownloadRow(
        state: .init(
            books: [
                .init(
                    id: UUID().uuidString,
                    title: "巫師：從合成寶石開始",
                    completedChapters: 4,
                    totalChapters: 50,
                    isPaused: true,
                    coverFilename: nil
                )
            ]
        )
    )
    .padding()
}
#endif
