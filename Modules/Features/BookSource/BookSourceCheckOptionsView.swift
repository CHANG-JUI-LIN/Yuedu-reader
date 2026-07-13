import SwiftUI

/// Asks the user, before a book-source health check runs, what to do with sources that fail or
/// are too slow. The check itself runs in the background, so these choices are applied
/// automatically when it finishes.
struct BookSourceCheckOptionsView: View {
    let sourceCount: Int
    @State private var policy: BookSourceCheckPolicy
    let onStart: (BookSourceCheckPolicy) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        sourceCount: Int,
        initialPolicy: BookSourceCheckPolicy,
        onStart: @escaping (BookSourceCheckPolicy) -> Void
    ) {
        self.sourceCount = sourceCount
        self._policy = State(initialValue: initialPolicy)
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(localized("壞書源處理"), selection: $policy.badAction) {
                        ForEach(BookSourceCheckPolicy.BadAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                } header: {
                    Text(localized("壞書源處理"))
                } footer: {
                    if policy.badAction == .delete {
                        Text(localized("刪除無法復原，請謹慎選擇"))
                            .foregroundColor(DSColor.destructive)
                    } else {
                        Text(localized("檢測失敗的書源的處理方式"))
                    }
                }

                Section {
                    Toggle(localized("停用過慢書源"), isOn: $policy.disableSlow)
                    if policy.disableSlow {
                        Picker(localized("過慢閾值"), selection: $policy.slowThresholdMs) {
                            ForEach(BookSourceCheckPolicy.slowOptionsMs, id: \.self) { ms in
                                Text("\(ms / 1000) \(localized("秒"))").tag(ms)
                            }
                        }
                    }
                } footer: {
                    Text(localized("回應時間超過閾值的書源會被停用"))
                }
            }
            .navigationTitle(localized("書源檢測選項"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onStart(policy)
                    dismiss()
                } label: {
                    Text("\(localized("開始檢測"))（\(sourceCount)）")
                        .font(DSFont.bodyBold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DSSpacing.md)
                        .background(DSColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.sm)
            }
        }
    }
}

#Preview {
    BookSourceCheckOptionsView(
        sourceCount: 42,
        initialPolicy: BookSourceCheckPolicy()
    ) { _ in }
}
