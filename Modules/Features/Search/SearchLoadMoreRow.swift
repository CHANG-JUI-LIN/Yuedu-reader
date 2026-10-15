import SwiftUI

/// The sources' paging as the list needs it (search 9b): whether more pages exist, whether
/// the search is idle enough to ask for one, and how.
struct SearchPaging {
    /// The sources have more pages: the list ends with a spinner.
    var hasMore: Bool
    /// No search is running or paused, so showing the spinner asks for the next page.
    var canLoadMore: Bool
    var loadMore: () -> Void
}

/// The spinner after the last row while more pages exist, as Emby's search ends: no button,
/// reaching it loads the next page. A running search does not ask again; when it ends,
/// `canLoadMore` changes the task's id and a spinner still on screen asks then. iOS 17's table
/// does the same in `willDisplay`.
@available(iOS 18.0, *)
struct SearchLoadMoreRow: View {
    let paging: SearchPaging
    /// The rows above it: a page that brought rows while the spinner stayed on screen asks again.
    let shownCount: Int

    private struct Trigger: Equatable {
        let shownCount: Int
        let canLoadMore: Bool
    }

    var body: some View {
        if paging.hasMore {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
                .accessibilityLabel(localized("正在載入更多"))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .task(id: Trigger(shownCount: shownCount, canLoadMore: paging.canLoadMore)) {
                    if paging.canLoadMore { paging.loadMore() }
                }
        }
    }
}

#if DEBUG
@available(iOS 18.0, *)
#Preview("搜索：載入下一頁") {
    List {
        Text("三體")
        SearchLoadMoreRow(paging: SearchPaging(hasMore: true, canLoadMore: false, loadMore: {}), shownCount: 1)
    }
    .listStyle(.plain)
}
#endif
