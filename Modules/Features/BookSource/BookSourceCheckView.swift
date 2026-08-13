import SwiftUI

/// Which failure bucket the results list is filtered to (Legado failure categories).
private enum ResultFilter: Hashable { case all, ruleMissing, parseFailed, environment }

struct BookSourceCheckView: View {
    @ObservedObject var checker: BookSourceHealthChecker
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ResultFilter = .all

    private var failedItems: [BookSourceCheckItem] {
        checker.items.filter { $0.isFinished && !$0.overallPass }
    }
    private var ruleMissingCount: Int {
        failedItems.filter { $0.failureCategory?.bucket == .ruleMissing }.count
    }
    private var parseFailedCount: Int {
        failedItems.filter { $0.failureCategory?.bucket == .parseFailed }.count
    }
    private var environmentCount: Int {
        failedItems.filter { $0.failureCategory?.bucket == .environment }.count
    }

    private var visibleItems: [BookSourceCheckItem] {
        switch filter {
        case .all:
            return checker.items
        case .ruleMissing:
            return failedItems.filter { $0.failureCategory?.bucket == .ruleMissing }
        case .parseFailed:
            return failedItems.filter { $0.failureCategory?.bucket == .parseFailed }
        case .environment:
            return failedItems.filter { $0.failureCategory?.bucket == .environment }
        }
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
            .navigationTitle(localized("書源驗證"))
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
            Text(localized("沒有選取的書源"))
                .font(DSFont.title3.weight(.semibold))
            Spacer()
        }
        .padding()
    }

    // MARK: - Result List

    private var resultList: some View {
        List {
            Section {
                progressCard
                    .listRowSeparator(.hidden)
                if !failedItems.isEmpty {
                    failureFilterSection
                        .listRowSeparator(.hidden)
                }
            }
            .interfaceSectionSurface()

            Section {
                ForEach(visibleItems) { item in
                    resultRow(item: item)
                }
            } header: {
                Text(localized("驗證結果"))
                    .font(DSFont.headline)
                    .foregroundColor(DSColor.textPrimary)
                    .textCase(nil)
            } footer: {
                summaryFooter
            }
            .interfaceSectionSurface()
        }
        .listStyle(.plain)
    }

    private var progressCard: some View {
        HStack(spacing: DSSpacing.sm) {
            if checker.isRunning {
                ProgressView().scaleEffect(0.9)
                Text(localized("驗證中…"))
                    .font(DSFont.bodyBold)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DSColor.success)
                Text(localized("驗證完成"))
                    .font(DSFont.bodyBold)
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
            // A `Grid` row, not an `HStack` of capsules: four labels of different
            // widths ("全部" vs "Environment Issues") squeezed into one line each,
            // so the capsules came out at four different widths and wrapped their
            // text into 1–3 lines, turning the narrow ones into circles. Grid gives
            // every tile the same width and the same height as the tallest one.
            Grid(horizontalSpacing: DSSpacing.sm, verticalSpacing: 0) {
                GridRow {
                    filterChip(.all, icon: "line.3.horizontal.circle",
                               label: localized("全部"), count: failedItems.count)
                    filterChip(.ruleMissing, icon: "wrench.and.screwdriver",
                               label: localized("規則缺失"), count: ruleMissingCount)
                    filterChip(.parseFailed, icon: "text.badge.xmark",
                               label: localized("解析失效"), count: parseFailedCount)
                    filterChip(.environment, icon: "network.slash",
                               label: localized("環境問題"), count: environmentCount)
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

    // MARK: - Row

    @ViewBuilder
    private func healthIcon(_ item: BookSourceCheckItem) -> some View {
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

    @ViewBuilder
    private func resultRow(item: BookSourceCheckItem) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                healthIcon(item)
                Text(
                    item.source.bookSourceName.isEmpty
                        ? localized("未命名書源") : item.source.bookSourceName
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

            stageProgressRow(item: item)
        }
        .padding(.vertical, DSSpacing.sm)
    }

    private func stageProgressRow(item: BookSourceCheckItem) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(ValidationStage.allCases) { stage in
                if stage.rawValue > 0 {
                    Rectangle()
                        .fill(connectorColor(item: item, before: stage))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 5)
                        .padding(.horizontal, 2)
                }
                stageColumn(item: item, stage: stage)
            }
        }
    }

    private func stageColumn(item: BookSourceCheckItem, stage: ValidationStage) -> some View {
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

    private func connectorColor(item: BookSourceCheckItem, before stage: ValidationStage) -> Color {
        guard let previous = ValidationStage(rawValue: stage.rawValue - 1) else {
            return DSColor.textDisabled.opacity(0.3)
        }
        return item.outcome(previous).status == .pass
            ? DSColor.success.opacity(0.5)
            : DSColor.textDisabled.opacity(0.3)
    }

    // MARK: - Footer

    @ViewBuilder
    private var summaryFooter: some View {
        if !checker.isRunning, !checker.items.isEmpty {
            let passed = checker.items.filter { $0.overallPass }.count
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(
                    "\(localized("共")) \(checker.items.count) \(localized("個書源，"))\(localized("通過")) \(passed) \(localized("個"))"
                )
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
                if let summary = checker.lastSummary {
                    Text(summary)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }
            .padding(.top, DSSpacing.sm)
        }
    }
}

// MARK: - Failure Filter Chip

/// One failure-bucket tile. Selected state keeps its accent fill but the label
/// weight stays fixed, so tapping never changes the text's appearance — only the
/// fill color. Sized to fill its grid cell in both axes so all four tiles line up
/// no matter how long the localized label is.
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
            .foregroundColor(selected ? .white : DSColor.textSecondary)
            .padding(.horizontal, DSSpacing.xs)
            .padding(.vertical, DSSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Chips stay opaque — same neutral fill as `DSChip` and 書源管理's filter chips.
            .background(selected ? DSColor.accent : DSColor.neutralControlFill)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("失敗類型細分") {
    VStack(alignment: .leading, spacing: DSSpacing.sm) {
        Text(localized("失敗類型細分"))
            .font(DSFont.headline)
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
    .padding()
}
