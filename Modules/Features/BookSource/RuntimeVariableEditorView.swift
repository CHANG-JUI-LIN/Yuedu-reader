import SwiftUI

/// Legado-style variable editor sheet, shared by 設置源變量 (free-text variable a
/// source's JS reads via `source.getVariable()`) and 設置書籍變量 (the book's
/// runtime-variable map). The optional `comment` surfaces the source author's
/// `variableComment` guidance so users know what to fill in.
struct RuntimeVariableEditorView: View {
    let title: String
    let comment: String
    let initialValue: String
    /// Returns an error message to keep the sheet open, or nil to accept.
    let onSave: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var errorText: String?
    @State private var didLoadInitialValue = false

    var body: some View {
        NavigationStack {
            Form {
                if !comment.isEmpty {
                    Section(localized("變量說明")) {
                        Text(comment)
                            .font(DSFont.footnote)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .font(DSFont.subheadline)
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        text = ""
                    } label: {
                        Label(localized("清除"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("儲存")) {
                        if let error = onSave(text) {
                            errorText = error
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                guard !didLoadInitialValue else { return }
                didLoadInitialValue = true
                text = initialValue
            }
        }
    }
}

#Preview("源變量") {
    RuntimeVariableEditorView(
        title: "設置源變量",
        comment: "填入代理地址，例如 https://example.com\n第二行可填音質 1-3",
        initialValue: "{\"proxy\":\"https://example.com\"}",
        onSave: { _ in nil }
    )
}

#Preview("書籍變量") {
    RuntimeVariableEditorView(
        title: "設置書籍變量",
        comment: "",
        initialValue: "{}",
        onSave: { _ in "JSON 格式錯誤" }
    )
}
