import SwiftUI

/// 回饋中心 › 我的回饋: every report this inbox sent, filtered by status group, newest
/// first by default. The groups are the tabs of the page's own tab bar — the app's tab bar
/// shows on tab roots only, so this one has the bottom to itself — and the sort control is
/// its last tab.
struct FeedbackListView: View {
    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// A tab: one per status group, and the sort control, which opens the sort choices
    /// instead of becoming the selected page.
    private enum ListTab: Hashable {
        case group(FeedbackStatusGroup)
        case sort
    }

    @State private var threads: [FeedbackThread] = []
    @State private var loadState: LoadState = .loading
    @State private var group: FeedbackStatusGroup = .processing
    @State private var sortOrder: FeedbackSortOrder = .newestFirst
    @State private var showsSortOptions = false
    @State private var didPickInitialGroup = false
    @State private var markAllError: String?
    @State private var reloadToken = 0

    private func threads(in group: FeedbackStatusGroup) -> [FeedbackThread] {
        threads
            .filter { $0.status.group == group }
            .sorted {
                sortOrder == .newestFirst ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt
            }
    }

    private var hasUnread: Bool { threads.contains(where: \.isUnread) }

    private var tabSelection: Binding<ListTab> {
        Binding(
            get: { .group(group) },
            set: { tab in
                switch tab {
                case .group(let selected): group = selected
                case .sort: showsSortOptions = true
                }
            }
        )
    }

    var body: some View {
        tabs
            .navigationTitle(localized("我的回饋"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localized("全部已讀")) { markAllRead() }
                        .disabled(!hasUnread)
                }
            }
            .confirmationDialog(localized("排序"), isPresented: $showsSortOptions, titleVisibility: .visible) {
                ForEach(FeedbackSortOrder.allCases) { order in
                    Button(order.title) { sortOrder = order }
                }
            } message: {
                Text(String(format: localized("目前：%@"), sortOrder.title))
            }
            .alert(
                localized("無法標記為已讀"),
                isPresented: Binding(get: { markAllError != nil }, set: { if !$0 { markAllError = nil } })
            ) {
                Button(localized("好"), role: .cancel) {}
            } message: {
                Text(markAllError ?? "")
            }
            .task(id: reloadToken) { await observe() }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            ForEach(FeedbackStatusGroup.allCases) { group in
                page(for: group)
                    .tabItem { Label(group.title, systemImage: group.systemImage) }
                    .tag(ListTab.group(group))
            }
            // Never shown: selecting this tab opens the sort choices (`tabSelection`).
            Color.clear
                .tabItem { Label(localized("排序"), systemImage: "arrow.up.arrow.down") }
                .tag(ListTab.sort)
        }
    }

    @ViewBuilder
    private func page(for group: FeedbackStatusGroup) -> some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    UnavailableLabel(localized("無法載入回饋"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message).foregroundStyle(DSColor.textSecondary)
                } actions: {
                    Button(localized("重試")) {
                        loadState = .loading
                        reloadToken += 1
                    }
                }
            case .loaded:
                let visible = threads(in: group)
                if visible.isEmpty {
                    ContentUnavailableView {
                        UnavailableLabel(localized("此分組暫無意見回報"), systemImage: group.systemImage)
                    }
                } else {
                    List {
                        Section {
                            ForEach(visible) { thread in
                                NavigationLink {
                                    FeedbackThreadView(thread: thread)
                                } label: {
                                    FeedbackThreadRow(thread: thread)
                                }
                            }
                        }
                        .interfaceSectionSurface()
                    }
                    .accessibilityIdentifier("feedback_list")
                }
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
    }

    private func observe() async {
        do {
            for try await update in FeedbackService.shared.threadUpdates() {
                threads = update
                loadState = .loaded
                if !didPickInitialGroup {
                    didPickInitialGroup = true
                    // Open on the first group that has something, in the bar's order.
                    if let first = FeedbackStatusGroup.allCases.first(where: { candidate in
                        update.contains { $0.status.group == candidate }
                    }) {
                        group = first
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            loadState = .failed(FeedbackService.userMessage(for: error))
        }
    }

    private func markAllRead() {
        let snapshot = threads
        Task {
            do {
                try await FeedbackService.shared.markAllRead(snapshot)
            } catch {
                AppLogger.network("Feedback mark-all-read failed", error: error)
                markAllError = FeedbackService.userMessage(for: error)
            }
        }
    }
}

/// One report: its title, when it last moved, the latest message and its status.
struct FeedbackThreadRow: View {
    let thread: FeedbackThread

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                if thread.isUnread {
                    Circle()
                        .fill(DSColor.accent)
                        .frame(width: DSLayout.feedbackUnreadDot, height: DSLayout.feedbackUnreadDot)
                        .accessibilityHidden(true)
                }
                Text(thread.title.isEmpty ? thread.displayTitle : thread.title)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: DSSpacing.sm)
                Text(thread.updatedAt, format: .relative(presentation: .named))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textTertiary)
            }
            if !thread.lastMessagePreview.isEmpty {
                Text(thread.lastMessagePreview)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            FeedbackStatusBadge(status: thread.status)
        }
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(thread.isUnread ? localized("有新回覆") : "")
    }
}

/// The status as a tinted capsule. The text carries the meaning; the colour only echoes it.
struct FeedbackStatusBadge: View {
    let status: FeedbackStatus

    var body: some View {
        Text(status.badgeTitle)
            .font(DSFont.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.xs)
            .background(tint.opacity(DSLayout.feedbackBadgeFillOpacity), in: Capsule())
    }

    private var tint: Color {
        switch status {
        case .received, .queued: DSColor.warning
        case .processing: DSColor.accent
        case .needsInfo: DSColor.feedbackNeedsInfo
        case .done: DSColor.success
        }
    }
}

#Preview {
    NavigationStack {
        FeedbackListView()
    }
}
