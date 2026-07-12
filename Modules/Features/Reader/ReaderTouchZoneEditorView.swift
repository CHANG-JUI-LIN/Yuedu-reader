import SwiftUI

private extension TouchAction {
    var localizedTitle: String { localized(rawValue) }
}

struct ReaderTouchZoneEditorView: View {
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @StateObject private var model = ReaderTouchZoneEditorModel()

    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                grid
                resetButton
            }
        }
        .onChange(of: subscriptionStore.isProActive) { _, isActive in
            if !isActive { onCancel() }
        }
    }

    private var header: some View {
        HStack(spacing: DSSpacing.md) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(DSFont.toolbarIcon)
                    .padding(DSSpacing.lg)
            }
            .accessibilityLabel(localized("取消"))

            Text(localized("翻頁區塊編輯"))
                .font(DSFont.headline)
                .frame(maxWidth: .infinity)

            Button {
                guard model.save(isProActive: subscriptionStore.isProActive) else { return }
                onSave()
            } label: {
                Image(systemName: "checkmark")
                    .font(DSFont.toolbarIcon)
                    .padding(DSSpacing.lg)
            }
            .accessibilityLabel(localized("完成"))
        }
        .foregroundStyle(DSColor.textPrimary)
        .background(DSColor.surface)
    }

    private var grid: some View {
        GeometryReader { proxy in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(0..<9, id: \.self) { index in
                    zoneMenu(index: index)
                        .frame(height: proxy.size.height / 3)
                        .overlay { Rectangle().stroke(DSColor.separator) }
                }
            }
        }
    }

    private func zoneMenu(index: Int) -> some View {
        Menu {
            ForEach(TouchAction.editorCases, id: \.self) { action in
                Button {
                    model.set(action, at: index)
                } label: {
                    if model.draft.zones[index] == action {
                        Label(action.localizedTitle, systemImage: "checkmark")
                    } else {
                        Text(action.localizedTitle)
                    }
                }
            }
        } label: {
            Text(model.draft.zones[index].localizedTitle)
                .font(DSFont.bodyBold)
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(
            String(
                format: localized("第 %d 列，第 %d 欄：%@"),
                index / 3 + 1,
                index % 3 + 1,
                model.draft.zones[index].localizedTitle
            )
        )
    }

    private var resetButton: some View {
        Button {
            model.restoreDefault()
        } label: {
            Label(localized("恢復預設"), systemImage: "arrow.counterclockwise")
                .font(DSFont.body)
                .frame(maxWidth: .infinity)
                .padding(DSSpacing.lg)
        }
        .foregroundStyle(DSColor.accent)
        .background(DSColor.surface)
    }
}
