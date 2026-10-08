import SwiftUI

// MARK: - SourceImportJSONEditor

/// Edits one row of an import confirmation list before it is written — Legado's `CodeDialog`
/// reached from each row's 「開啟」.
///
/// The point is to fix a source *as it arrives*: a pack's entry with a stale domain or a
/// wrong header can be corrected here instead of being imported and then edited, or skipped
/// and pasted by hand.
struct SourceImportJSONEditor: View {
    let title: String
    let initialJSON: String
    /// Applies the edited text. Returns `false` when it does not parse, which keeps the
    /// editor open and shows the parse warning rather than dropping the user's work.
    let onSave: (String) -> Bool

    @State private var text: String
    @State private var showsParseError = false
    @Environment(\.dismiss) private var dismiss

    init(title: String, initialJSON: String, onSave: @escaping (String) -> Bool) {
        self.title = title
        self.initialJSON = initialJSON
        self.onSave = onSave
        _text = State(initialValue: initialJSON)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showsParseError {
                    HStack(alignment: .top, spacing: DSSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DSColor.warning)
                            .accessibilityHidden(true)
                        Text(localized("這段 JSON 無法解析，請修正後再儲存。"))
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSSpacing.md)
                    .background(DSColor.warning.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.top, DSSpacing.md)
                    .accessibilityElement(children: .combine)
                }

                TextEditor(text: $text)
                    .font(DSFont.fixed(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(DSSpacing.sm)
                    .background(DSColor.surfaceTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
                    .padding(DSSpacing.md)
                    .accessibilityLabel(localized("來源 JSON"))
            }
            .navigationTitle(title)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if onSave(text) {
                            dismiss()
                        } else {
                            showsParseError = true
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("完成"))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    SourceImportJSONEditor(
        title: "示例來源配置",
        initialJSON: """
        {
          "bookSourceName" : "示例來源配置",
          "bookSourceUrl" : "https://example.com"
        }
        """,
        onSave: { _ in true }
    )
}
