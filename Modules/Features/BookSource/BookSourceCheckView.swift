import SwiftUI

struct BookSourceCheckView: View {
    @ObservedObject var checker: BookSourceHealthChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableWideWidth) {
                VStack(spacing: 0) {
                    if checker.items.isEmpty {
                        emptyView
                    } else {
                        resultList
                    }
                    if !checker.items.isEmpty {
                        Divider()
                        bottomBar
                    }
                }
            }
            .navigationTitle(localized("書源檢測"))
            .toolbarTitleDisplayMode(.inline)
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
                        .accessibilityLabel(localized("停止測試"))
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: DSSpacing.xl) {
            Spacer()
            Image(systemName: "stethoscope")
                .font(.system(size: 56))
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
                ForEach(checker.items.indices, id: \.self) { index in
                    resultRow(item: checker.items[index])
                }
            } footer: {
                summaryFooter
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var summaryFooter: some View {
        if checker.isRunning {
            HStack(spacing: DSSpacing.sm) {
                ProgressView().scaleEffect(0.8)
                Text(localized("正在檢測…"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
            }
            .padding(.top, DSSpacing.sm)
        } else if !checker.items.isEmpty {
            let passed = checker.items.filter { $0.overallPass }.count
            let total = checker.items.count
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.xs) {
                    Image(
                        systemName: passed == total ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundColor(passed == total ? DSColor.success : DSColor.warning)
                    .font(DSFont.caption)
                    Text(
                        "\(localized("共")) \(total) \(localized("個書源，"))\(localized("通過")) \(passed) \(localized("個"))"
                    )
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                }
                if let summary = checker.lastSummary {
                    Text(summary)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }
            .padding(.top, DSSpacing.sm)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func resultRow(item: BookSourceCheckItem) -> some View {
        HStack(spacing: DSSpacing.sm) {
            statusIcon(item.status)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    item.source.bookSourceName.isEmpty
                        ? localized("未命名書源") : item.source.bookSourceName
                )
                .font(DSFont.bodyBold)
                .foregroundColor(DSColor.textPrimary)
                .lineLimit(1)

                if !item.source.bookSourceUrl.isEmpty {
                    Text(item.source.bookSourceUrl)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                }

                if case .pass = item.status {
                    if let detail = item.detail {
                        Text(detail)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(2)
                    }
                    if item.responseTime > 0 {
                        Text("\(item.responseTime)ms")
                            .font(DSFont.caption2)
                            .foregroundColor(DSColor.textSecondary.opacity(0.6))
                    }
                } else if case .fail = item.status {
                    if let detail = item.detail {
                        Text(detail)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.destructive)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: DSSpacing.sm)

            if case .pass = item.status {
                HStack(spacing: 4) {
                    if checker.isSlow(item) {
                        statusBadge(text: localized("慢"), color: DSColor.warning)
                    }
                    statusBadge(text: localized("通過"), color: DSColor.success)
                }
            } else if case .fail = item.status {
                statusBadge(text: localized("失敗"), color: DSColor.destructive)
            }
        }
        .padding(.vertical, DSSpacing.sm)
    }

    @ViewBuilder
    private func statusIcon(_ status: CheckStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .fill(DSColor.textDisabled)
                .frame(width: 10, height: 10)
        case .testing:
            ProgressView()
                .scaleEffect(0.7)
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DSColor.success)
                .font(DSFont.subheadline)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(DSColor.destructive)
                .font(DSFont.subheadline)
        }
    }

    @ViewBuilder
    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(DSFont.caption2.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            if checker.isRunning {
                Button {
                    checker.cancel()
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        Image(systemName: "stop.fill")
                        Text(localized("停止測試"))
                    }
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.vertical, DSSpacing.sm)
                    .background(DSColor.destructive)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    checker.prepare(
                        sources: checker.items.map(\.source))
                    Task { await checker.runAll() }
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        Image(systemName: "arrow.clockwise")
                        Text(localized("重新檢測"))
                    }
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.vertical, DSSpacing.sm)
                    .background(DSColor.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, DSSpacing.sm)
        .background(Color(UIColor.systemBackground))
    }
}
