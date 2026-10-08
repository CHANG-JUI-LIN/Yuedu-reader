import SwiftUI

/// Which failure bucket the results list is filtered to (Legado failure categories).
private enum ResultFilter: Hashable { case all, ruleMissing, parseFailed, environment }

/// Rows of the result sheet, in order.
private enum CheckListItem: Hashable {
    case progress
    case failureFilter
    case resultsHeader
    /// Index into `BookSourceHealthChecker.items`.
    case result(Int)
    case summary
}

struct BookSourceCheckView: View {
    @ObservedObject var checker: BookSourceHealthChecker
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ResultFilter = .all

    private var failedCount: Int { checker.failedIndices.count }

    private func count(_ bucket: FailureCategory.Bucket) -> Int {
        checker.failedIndicesByBucket[bucket]?.count ?? 0
    }

    /// Rows for the current filter. The checker tallies failures as sources finish; this
    /// used to filter the whole run five times per render — per publication, over every
    /// item of a 50,000-source run.
    private var listItems: [CheckListItem] {
        var items: [CheckListItem] = [.progress]
        if failedCount > 0 {
            items.append(.failureFilter)
        }
        items.append(.resultsHeader)
        switch filter {
        case .all:
            items.append(contentsOf: checker.items.indices.lazy.map(CheckListItem.result))
        case .ruleMissing:
            items.append(contentsOf: rows(for: .ruleMissing))
        case .parseFailed:
            items.append(contentsOf: rows(for: .parseFailed))
        case .environment:
            items.append(contentsOf: rows(for: .environment))
        }
        if !checker.isRunning, !checker.items.isEmpty {
            items.append(.summary)
        }
        return items
    }

    /// Failed rows in run order (the checker records them in completion order).
    private func rows(for bucket: FailureCategory.Bucket) -> [CheckListItem] {
        (checker.failedIndicesByBucket[bucket] ?? []).sorted().map(CheckListItem.result)
    }

    var body: some View {
        NavigationStack {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableWideWidth) {
                Group {
                    if checker.items.isEmpty {
                        emptyView
                    } else {
                        resultList
                    }
                }
            }
            .navigationTitle(localized("來源配置驗證"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if checker.isRunning {
                        Button {
                            checker.cancel()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .accessibilityLabel(localized("停止"))
                    } else if !checker.items.isEmpty {
                        Button {
                            checker.prepare(sources: checker.items.map(\.source))
                            Task { await checker.runAll() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(localized("重新驗證"))
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: DSSpacing.xl) {
            Spacer()
            Image(systemName: "waveform.and.magnifyingglass")
                .font(DSFont.fixed(size: 56))
                .foregroundColor(DSColor.textSecondary.opacity(0.35))
            Text(localized("沒有選取的來源配置"))
                .font(DSFont.title3.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Result List

    /// Only the rows on screen are built — see `HostedCollectionList`. Each publication
    /// refreshes the visible rows; the row order changes only with the filter.
    private var resultList: some View {
        HostedCollectionList(
            items: listItems,
            // `cancel()` flips `isRunning` without a publication; the progress card and the
            // stage dots still have to repaint.
            contentVersion: checker.publicationVersion &* 2 + (checker.isRunning ? 1 : 0),
            showsSeparator: { item in
                if case .result = item { return true }
                return false
            },
            usesSystemMargins: { _ in true },
            drawsCellSurface: { item in
                switch item {
                case .progress, .failureFilter, .result: return true
                case .resultsHeader, .summary: return false
                }
            }
        ) { item in
            switch item {
            case .progress:
                progressCard
            case .failureFilter:
                failureFilterSection
            case .resultsHeader:
                Text(localized("驗證結果"))
                    .font(DSFont.headline)
                    .foregroundColor(DSColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            case .result(let index):
                if checker.items.indices.contains(index) {
                    BookSourceCheckResultRow(item: checker.items[index])
                }
            case .summary:
                summaryFooter
            }
        }
    }

    private var progressCard: some View {
        HStack(spacing: DSSpacing.sm) {
            if checker.isRunning {
                ProgressView().scaleEffect(0.9)
                Text(localized("驗證中…"))
                    .font(DSFont.bodyBold)
                    .foregroundStyle(DSColor.textPrimary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DSColor.success)
                Text(localized("驗證完成"))
                    .font(DSFont.bodyBold)
                    .foregroundStyle(DSColor.textPrimary)
            }
            Spacer()
            Text("\(checker.finishedCount)/\(checker.items.count)")
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)
                .monospacedDigit()
        }
        .padding(DSSpacing.md)
        // Follows 毛玻璃／分組卡片／透明度 like 書源管理's stats card; a hardcoded
        // `secondarySystemBackground` stayed opaque at every setting.
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    private var failureFilterSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("失敗類型細分"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
            // A `Grid` row, not an `HStack` of capsules: four labels of different
            // widths ("全部" vs "Environment Issues") squeezed into one line each,
            // so the capsules came out at four different widths and wrapped their
            // text into 1–3 lines, turning the narrow ones into circles. Grid gives
            // every tile the same width and the same height as the tallest one.
            SourceFilterButtonGroup {
                Grid(horizontalSpacing: DSSpacing.sm, verticalSpacing: 0) {
                    GridRow {
                        filterChip(.all, icon: "line.3.horizontal.circle",
                                   label: localized("全部"), count: failedCount)
                        filterChip(.ruleMissing, icon: "wrench.and.screwdriver",
                                   label: localized("規則缺失"), count: count(.ruleMissing))
                        filterChip(.parseFailed, icon: "text.badge.xmark",
                                   label: localized("解析失效"), count: count(.parseFailed))
                        filterChip(.environment, icon: "network.slash",
                                   label: localized("環境問題"), count: count(.environment))
                    }
                }
            }
        }
        .padding(.top, DSSpacing.xs)
    }

    private func filterChip(_ value: ResultFilter, icon: String, label: String, count: Int) -> some View {
        FailureFilterChip(
            icon: icon,
            label: label,
            count: count,
            selected: filter == value
        ) {
            filter = value
        }
    }

    // MARK: - Footer

    private var summaryFooter: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(
                String(
                    format: localized("共 %1$d 個來源配置，通過 %2$d 個"),
                    checker.items.count, checker.passedCount)
            )
            if let summary = checker.lastSummary {
                Text(summary)
            }
        }
        .dsSectionFooter()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DSSpacing.sm)
    }
}

// MARK: - Result Row

/// One source's five-stage result. Its own `View` struct, built only while on screen.
private struct BookSourceCheckResultRow: View {
    let item: BookSourceCheckItem

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                healthIcon
                Text(
                    item.source.bookSourceName.isEmpty
                        ? localized("未命名來源配置") : item.source.bookSourceName
                )
                .font(DSFont.bodyBold)
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)
                Spacer(minLength: DSSpacing.sm)
                if item.responseTime > 0 {
                    Text("\(item.responseTime)ms")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .monospacedDigit()
                }
            }

            if item.isFinished, !item.overallPass {
                HStack(spacing: DSSpacing.xs) {
                    Text(localized("失敗類型") + "：")
                    Text(item.failureCategory?.title ?? localized("網站失效"))
                }
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
            }

            stageProgressRow
        }
        .padding(.vertical, DSSpacing.sm)
    }

    @ViewBuilder
    private var healthIcon: some View {
        if !item.isFinished {
            if item.status == .testing {
                ProgressView().scaleEffect(0.7)
            } else {
                Circle()
                    .fill(DSColor.textDisabled.opacity(0.5))
                    .frame(width: 10, height: 10)
            }
        } else if item.overallPass {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DSColor.success)
                .font(DSFont.subheadline)
        } else if item.health == .contentError {
            Image(systemName: "doc.text.fill")
                .foregroundColor(DSColor.warning)
                .font(DSFont.subheadline)
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(DSColor.warning)
                .font(DSFont.subheadline)
        }
    }

    private var stageProgressRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(ValidationStage.allCases) { stage in
                if stage.rawValue > 0 {
                    Rectangle()
                        .fill(connectorColor(before: stage))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 5)
                        .padding(.horizontal, 2)
                }
                stageColumn(stage)
            }
        }
    }

    private func stageColumn(_ stage: ValidationStage) -> some View {
        let outcome = item.outcome(stage)
        return VStack(spacing: 3) {
            stageDot(outcome.status)
            Text(stage.title)
                .font(DSFont.caption.weight(.semibold))
                .foregroundColor(DSColor.textPrimary)
            Text(outcome.summary.isEmpty ? "—" : outcome.summary)
                .font(DSFont.caption2)
                .foregroundColor(DSColor.textSecondary)
                .lineLimit(1)
        }
        .frame(minWidth: 52)
    }

    @ViewBuilder
    private func stageDot(_ status: StageStatus) -> some View {
        switch status {
        case .pending:
            Circle().fill(DSColor.textDisabled.opacity(0.4)).frame(width: 10, height: 10)
        case .running:
            ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
        case .pass:
            Circle().fill(DSColor.success).frame(width: 10, height: 10)
        case .fail:
            Circle().fill(DSColor.destructive).frame(width: 10, height: 10)
        case .skipped:
            Circle().fill(DSColor.textDisabled.opacity(0.4)).frame(width: 10, height: 10)
        }
    }

    private func connectorColor(before stage: ValidationStage) -> Color {
        guard let previous = ValidationStage(rawValue: stage.rawValue - 1) else {
            return DSColor.textDisabled.opacity(0.3)
        }
        return item.outcome(previous).status == .pass
            ? DSColor.success.opacity(0.5)
            : DSColor.textDisabled.opacity(0.3)
    }
}

// MARK: - Failure Filter Chip

/// One failure-bucket tile: the same system glass button as 書源管理's pages
/// (`sourceFilterButtonStyle`), shaped as a rounded tile because it holds two lines.
/// The label weight stays fixed, so tapping never changes the text — only the button's
/// material. Sized to fill its grid cell in both axes so all four tiles line up no
/// matter how long the localized label is.
private struct FailureFilterChip: View {
    let icon: String
    let label: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
                    Image(systemName: icon)
                        .font(DSFont.caption)
                        .accessibilityHidden(true)
                    Text("\(count)")
                        .font(DSFont.title3.weight(.semibold))
                        .monospacedDigit()
                }
                Text(label)
                    .font(DSFont.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, DSSpacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sourceFilterButtonStyle(
            selected: selected, shape: .roundedRectangle(radius: DSRadius.lg))
        .accessibilityLabel(label)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("失敗類型細分") {
    VStack(alignment: .leading, spacing: DSSpacing.sm) {
        Text(localized("失敗類型細分"))
            .font(DSFont.headline)
        SourceFilterButtonGroup {
            Grid(horizontalSpacing: DSSpacing.sm, verticalSpacing: 0) {
                GridRow {
                    FailureFilterChip(icon: "line.3.horizontal.circle",
                                      label: localized("全部"), count: 19, selected: true) {}
                    FailureFilterChip(icon: "wrench.and.screwdriver",
                                      label: localized("規則缺失"), count: 1, selected: false) {}
                    FailureFilterChip(icon: "text.badge.xmark",
                                      label: localized("解析失效"), count: 13, selected: false) {}
                    FailureFilterChip(icon: "network.slash",
                                      label: localized("環境問題"), count: 5, selected: false) {}
                }
            }
        }
    }
    .padding()
}

#Preview("驗證結果列") {
    var failed = BookSourceCheckItem(
        source: BookSource(bookSourceUrl: "https://example.com", bookSourceName: "示例來源配置"))
    failed.stages = [
        StageOutcome(status: .pass, summary: "「我的」12 本"),
        StageOutcome(status: .skipped, summary: "—"),
        StageOutcome(status: .pass, summary: "搜索《示例》"),
        StageOutcome(status: .fail, summary: "目錄失效"),
        StageOutcome(status: .skipped, summary: "—"),
    ]
    failed.responseTime = 1_234
    failed.failureCategory = .tocEmpty
    let passed = BookSourceCheckItem(
        source: BookSource(bookSourceUrl: "https://example.org", bookSourceName: "通過的來源配置"))
    return VStack(alignment: .leading, spacing: DSSpacing.lg) {
        BookSourceCheckResultRow(item: failed)
        BookSourceCheckResultRow(item: passed)
    }
    .padding()
}
