import SwiftUI

enum ReaderDownloadStartOption: String, CaseIterable, Identifiable {
    case currentChapter
    case firstChapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentChapter:
            return localized("從當前章開始")
        case .firstChapter:
            return localized("從第一章開始")
        }
    }
}

struct ReaderDownloadOptionsView: View {
    let bookId: UUID
    let bookTitle: String
    let currentChapterIndex: Int
    let totalChapters: Int
    let onStart: (Int, Int) -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var store: BookStore

    @State private var startOption: ReaderDownloadStartOption = .currentChapter
    @State private var chapterCount: Double
    @State private var chapterCountText: String

    init(
        bookId: UUID,
        bookTitle: String,
        currentChapterIndex: Int,
        totalChapters: Int,
        onStart: @escaping (Int, Int) -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.currentChapterIndex = max(0, currentChapterIndex)
        self.totalChapters = max(0, totalChapters)
        self.onStart = onStart
        self.onPause = onPause
        self.onResume = onResume
        self.onRemove = onRemove
        self.onClose = onClose

        let safeTotal = max(1, totalChapters)
        let safeCurrent = min(max(0, currentChapterIndex), safeTotal - 1)
        let defaultCount = min(50, max(1, safeTotal - safeCurrent))
        _chapterCount = State(initialValue: Double(defaultCount))
        _chapterCountText = State(initialValue: "\(defaultCount)")
    }

    private var book: ReadingBook? { store.books.first(where: { $0.id == bookId }) }
    private var downloadState: BookOfflineDownloadState { book?.offlineDownloadState ?? .none }

    private enum Mode { case range, progress, completed }
    private var mode: Mode {
        switch downloadState {
        case .downloading, .paused:
            return .progress
        case .failed:
            return book?.offlineDownloadTask != nil ? .progress : .range
        case .available:
            return .completed
        case .none:
            return .range
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .range:
                    rangeSections
                case .progress:
                    progressSections
                case .completed:
                    completedSections
                }
            }
            .navigationTitle(localized("下載章節"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                if mode == .range {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onStart(selectedStartIndex, Int(chapterCount.rounded()))
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .disabled(totalChapters <= 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private var rangeSections: some View {
        Section {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(bookTitle)
                    .font(DSFont.headline)
                    .lineLimit(2)
                Text(summaryText)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
            }
            .padding(.vertical, DSSpacing.xs)
        }

        Section(header: Text(localized("下載範圍"))) {
            Picker(localized("開始位置"), selection: $startOption) {
                ForEach(ReaderDownloadStartOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: startOption) { _, _ in
                clampChapterCountToCurrentMaximum()
            }

            HStack {
                Text(localized("開始章節"))
                Spacer()
                Text(String(format: localized("第 %d 章"), selectedStartIndex + 1))
                    .foregroundColor(DSColor.textSecondary)
            }
        }

        Section(header: Text(localized("章數"))) {
            if maxSelectableCount > 1 {
                Slider(
                    value: Binding(
                        get: { chapterCount },
                        set: { updateChapterCount(Int($0.rounded())) }
                    ),
                    in: 1...Double(maxSelectableCount),
                    step: 1
                )
            }

            HStack {
                Text(localized("手動輸入"))
                Spacer()
                TextField(localized("章數"), text: $chapterCountText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                    .onChange(of: chapterCountText) { _, newValue in
                        updateChapterCountText(newValue)
                    }
            }

            Text(String(format: localized("最多可下載 %d 章"), maxSelectableCount))
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
        }

        if totalChapters <= 0 {
            Section {
                Label(localized("沒有可下載章節"), systemImage: "exclamationmark.triangle")
                    .foregroundColor(DSColor.textSecondary)
            }
        }
    }

    @ViewBuilder private var progressSections: some View {
        Section {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text(bookTitle)
                    .font(DSFont.headline)
                    .lineLimit(2)
                HStack {
                    Text(statusTitle)
                        .font(DSFont.subheadline)
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                    Text("\(completedCount)/\(totalCount)")
                        .font(DSFont.caption.monospacedDigit())
                        .foregroundColor(DSColor.textSecondary)
                }
                ProgressView(value: progressValue)
                    .tint(downloadState == .downloading ? .blue : DSColor.textSecondary)
            }
            .padding(.vertical, DSSpacing.xs)
        }

        Section {
            Button {
                if downloadState == .downloading {
                    onPause()
                } else {
                    onResume()
                }
            } label: {
                Label(
                    downloadState == .downloading ? localized("暫停下載") : localized("繼續下載"),
                    systemImage: downloadState == .downloading ? "pause.fill" : "play.fill"
                )
            }
            if downloadState != .downloading {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label(localized("移除"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private var completedSections: some View {
        Section {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text(bookTitle)
                    .font(DSFont.headline)
                    .lineLimit(2)
                HStack {
                    Label(localized("下載完成"), systemImage: "checkmark.circle.fill")
                        .font(DSFont.subheadline)
                        .foregroundColor(.green)
                    Spacer()
                    Text("\(completedCount)/\(totalCount)")
                        .font(DSFont.caption.monospacedDigit())
                        .foregroundColor(DSColor.textSecondary)
                }
            }
            .padding(.vertical, DSSpacing.xs)
        }

        Section {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label(localized("移除"), systemImage: "trash")
            }
        }
    }

    private var clampedTask: BookOfflineDownloadTask? {
        book?.offlineDownloadTask?.clamped(to: max(totalChapters, 0))
    }

    private var completedCount: Int {
        clampedTask?.clampedCompletedChapterCount ?? book?.downloadedChapterCount ?? 0
    }

    private var totalCount: Int {
        clampedTask?.totalChapterCount ?? max(totalChapters, 1)
    }

    private var progressValue: Double {
        let total = max(totalCount, 1)
        return min(max(Double(completedCount) / Double(total), 0), 1)
    }

    private var statusTitle: String {
        switch downloadState {
        case .downloading:
            return localized("下載中")
        case .paused:
            return localized("已暫停")
        case .failed:
            return localized("下載失敗")
        case .available:
            return localized("下載完成")
        case .none:
            return localized("未下載")
        }
    }

    private var selectedStartIndex: Int {
        guard totalChapters > 0 else { return 0 }
        switch startOption {
        case .currentChapter:
            return min(max(currentChapterIndex, 0), totalChapters - 1)
        case .firstChapter:
            return 0
        }
    }

    private var maxSelectableCount: Int {
        max(1, totalChapters - selectedStartIndex)
    }

    private var selectedEndIndex: Int {
        min(totalChapters - 1, selectedStartIndex + Int(chapterCount.rounded()) - 1)
    }

    private var summaryText: String {
        guard totalChapters > 0 else { return localized("沒有可下載章節") }
        return String(
            format: localized("第 %d 到 %d 章，共 %d 章"),
            selectedStartIndex + 1,
            selectedEndIndex + 1,
            Int(chapterCount.rounded())
        )
    }

    private func updateChapterCount(_ value: Int) {
        let clamped = min(max(value, 1), maxSelectableCount)
        chapterCount = Double(clamped)
        chapterCountText = "\(clamped)"
    }

    private func updateChapterCountText(_ text: String) {
        let filtered = text.filter(\.isNumber)
        if filtered != text {
            chapterCountText = filtered
            return
        }
        guard let value = Int(filtered) else { return }
        let clamped = min(max(value, 1), maxSelectableCount)
        chapterCount = Double(clamped)
        if value != clamped {
            chapterCountText = "\(clamped)"
        }
    }

    private func clampChapterCountToCurrentMaximum() {
        updateChapterCount(Int(chapterCount.rounded()))
    }
}
