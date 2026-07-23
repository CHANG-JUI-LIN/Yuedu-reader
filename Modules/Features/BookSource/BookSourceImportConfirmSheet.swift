import SwiftUI

// MARK: - BookSourceImportConfirmSheet

// Confirmation + result sheet for book-source imports arriving via system deep
// link (`yuedu://import/…` / `legado://import/…`). Bound to
// `BookSourceDeepLinkHandler`; the App entry point presents this sheet when
// the handler is in any non-`.idle` phase.
//
// Presentational only — all state mutations go through the handler's
// `confirm()` / `cancel()` / `finish()` callbacks.
struct BookSourceImportConfirmSheet: View {
    @ObservedObject var handler: BookSourceDeepLinkHandler

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(localized("匯入書源"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(localized("取消")) { handler.cancel() }
                            .disabled(isBusy)
                    }
                }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool {
        if case .importing = handler.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch handler.phase {
        case .idle:
            EmptyView()
        case .confirming(let sourceURL):
            confirmingView(sourceURL: sourceURL)
        case .importing:
            importingView
        case .succeeded(let count):
            resultView(
                systemImage: "checkmark.circle.fill",
                tint: DSColor.success,
                message: String(format: localized("成功匯入 %d 個書源"), count),
                actionTitle: localized("完成")
            ) { handler.finish() }
        case .failed(let message):
            resultView(
                systemImage: "exclamationmark.circle.fill",
                tint: DSColor.destructive,
                message: message,
                actionTitle: localized("完成")
            ) { handler.finish() }
        }
    }

    private func confirmingView(sourceURL: URL) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(localized("確認從外部來源匯入書源？"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized("來源："))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                Text(sourceURL.absoluteString)
                    .font(DSFont.subheadline.monospaced())
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.sm)
            .background(DSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            Button {
                handler.confirm()
            } label: {
                Label(localized("確認匯入"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var importingView: some View {
        VStack(spacing: DSSpacing.md) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(localized("匯入中，請稍候…"))
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(
        systemImage: String,
        tint: Color,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: DSSpacing.md) {
            Spacer()
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(tint)
                Text(message)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSSpacing.md)
            }
            Spacer()
            Button(action: action) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.md)
        .frame(maxHeight: .infinity)
    }
}