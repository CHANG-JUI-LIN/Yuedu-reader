import SwiftUI

/// Which failure bucket the results list is filtered to.
private enum ResultFilter: Hashable { case all, emptyRule, other }

struct BookSourceCheckView: View {
    @ObservedObject var checker: BookSourceHealthChecker
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ResultFilter = .all

    private var failedItems: [BookSourceCheckItem] {
        checker.items.filter { $0.isFinished && !$0.overallPass }
    }
    private var emptyRuleCount: Int { failedItems.filter { $0.failureCategory == .emptyRule }.count }
    private var otherFailCount: Int { failedItems.filter { $0.failureCategory != .emptyRule }.count }

    private var visibleItems: [BookSourceCheckItem] {
        switch filter {
        case .all:
            return checker.items
        case .emptyRule:
            return failedItems.filter { $0.failureCategory == .emptyRule }
        case .other:
            return failedItems.filter { $0.failureCategory != .emptyRule }
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    private var failureFilterSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("失敗類型細分"))
                .font(DSFont.headline)
            HStack(spacing: DSSpacing.sm) {
                filterChip(.all, icon: "line.3.horizontal.circle",
                           label: localized("全部"), count: failedItems.count)
                filterChip(.emptyRule, icon: "wrench.and.screwdriver",
                           label: localized("規則空"), count: emptyRuleCount)
                filterChip(.other, icon: "wrench.and.screwdriver",
                           label: localized("其他"), count: otherFailCount)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, DSSpacing.xs)
    }

    private func filterChip(_ value: ResultFilter, icon: String, label: String, count: Int) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(DSFont.caption)
                Text("\(label) \(count)")
                    .font(DSFont.subheadline.weight(selected ? .semibold : .regular))
            }
            .foregroundColor(selected ? .white : DSColor.textSecondary)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .background(selected ? DSColor.accent : Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
                    Text(item.failureCategory == .emptyRule ? localized("規則空") : localized("其他"))
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
                if stage != .connectivity {
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
