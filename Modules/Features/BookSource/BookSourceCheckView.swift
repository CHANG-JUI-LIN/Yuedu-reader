import SwiftUI

struct BookSourceCheckView: View {
    @StateObject private var checker = BookSourceHealthChecker()
    let sources: [BookSource]
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
                    if !checker.isRunning {
                        Button {
                            startCheck()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(localized("重新檢測"))
                        .disabled(checker.isRunning)
                    } else {
                        Button {
                            checker.cancel()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .accessibilityLabel(localized("停止測試"))
                    }
                }
            }
            .onAppear {
                checker.prepare(sources: sources)
                startCheck()
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: DSSpacing.xl) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 56))
                .foregroundColor(DSColor.textSecondary.opacity(0.35))
            Text(localized("沒有選取的書源"))
                .font(DSFont.title3.weight(.semibold))
            Spacer()
        }
        .padding()
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(checker.items.indices, id: \.self) { index in
                    resultRow(item: checker.items[index])
                }
            } footer: {
                if checker.isRunning {
                    HStack(spacing: DSSpacing.sm) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(localized("正在檢測…"))
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    .padding(.top, DSSpacing.sm)
                } else {
                    let passed = checker.items.filter { $0.overallPass }.count
                    let total = checker.items.count
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: passed == total ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(passed == total ? DSColor.success : DSColor.warning)
                            .font(DSFont.caption)
                        Text("\(localized("共")) \(total) \(localized("個書源，"))\(localized("通過")) \(passed) \(localized("個"))")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    .padding(.top, DSSpacing.sm)
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func resultRow(item: BookSourceCheckItem) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                statusIcon(for: item)
                    .font(DSFont.subheadline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.source.bookSourceName.isEmpty ? localized("未命名書源") : item.source.bookSourceName)
                        .font(DSFont.bodyBold)
                        .foregroundColor(DSColor.textPrimary)
                        .lineLimit(1)
                    if !item.source.bookSourceUrl.isEmpty {
                        Text(item.source.bookSourceUrl)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !item.connectivity.isTesting && !item.search.isTesting {
                    statusBadge(pass: item.overallPass)
                }
            }

            if item.connectivity.isTesting || item.search.isTesting {
                HStack(spacing: DSSpacing.sm) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(localized("正在檢測…"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    checkDetail(
                        label: localized("連線"),
                        result: item.connectivity
                    )
                    if !item.source.searchUrl.isEmpty {
                        checkDetail(
                            label: localized("搜索"),
                            result: item.search
                        )
                    }
                }
            }
        }
        .padding(.vertical, DSSpacing.sm)
    }

    @ViewBuilder
    private func statusIcon(for item: BookSourceCheckItem) -> some View {
        if item.connectivity.isTesting || item.search.isTesting {
            Circle()
                .fill(DSColor.textSecondary.opacity(0.3))
                .frame(width: 10, height: 10)
        } else if item.overallPass {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DSColor.success)
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(DSColor.destructive)
        }
    }

    @ViewBuilder
    private func statusBadge(pass: Bool) -> some View {
        Text(pass ? localized("通過") : localized("失敗"))
            .font(DSFont.caption2.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 3)
            .background(pass ? DSColor.success : DSColor.destructive)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func checkDetail(label: String, result: BookSourceCheckResult) -> some View {
        HStack(spacing: DSSpacing.xs) {
            switch result {
            case .notTested:
                Text("\(label): —")
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textDisabled)
            case .testing:
                EmptyView()
            case .success(let timeMs):
                HStack(spacing: 2) {
                    Text("\(label):")
                    Image(systemName: "checkmark")
                        .foregroundColor(DSColor.success)
                    Text("\(timeMs)ms")
                }
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
            case .failure(let message):
                HStack(spacing: 2) {
                    Text("\(label):")
                    Image(systemName: "xmark")
                        .foregroundColor(DSColor.destructive)
                    Text(message)
                        .lineLimit(1)
                }
                .font(DSFont.caption)
                .foregroundColor(DSColor.destructive)
            }
        }
    }

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
                    startCheck()
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

    private func startCheck() {
        checker.prepare(sources: sources)
        Task {
            await checker.runAll()
        }
    }
}
