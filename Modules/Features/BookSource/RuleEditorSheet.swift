import Combine
import SwiftUI
import UIKit

// MARK: - Rule Editor Bottom Sheet

/// Bottom-sheet rule editor (MD3's `SourceEditFieldSheet` equivalent) with an
/// insert-chips row above the keyboard — the iOS stand-in for Legado/Sigma's
/// `KeyboardToolPop` toolbar. Tapping a chip inserts its text at the cursor.
struct RuleEditorSheet: View {
    let spec: BookSourceFieldSpec
    let initialValue: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @StateObject private var bridge = RuleTextViewBridge()

    /// The insert chips, mirroring Legado's default `keyboardAssists.json` set
    /// (`@css:`, `<js></js>`, `{{}}`, `##`, `&&`, `%%`, `||`, `$.`, `@text`,
    /// `textNodes`, `ownText`, `all`, `,{"webView": true}` …).
    private static let insertChips: [String] = [
        "@css:", "@js:", "@XPath:", "@webjs:", "@Json:", "<js></js>",
        "{{}}", "##", "&&", "%%", "||", "//", "$.",
        "@text", "@href", "@src", "@alt", "@html",
        "textNodes", "ownText", "all", #",{"webView": true}"#
    ]

    init(spec: BookSourceFieldSpec, initialValue: String, onSave: @escaping (String) -> Void) {
        self.spec = spec
        self.initialValue = initialValue
        self.onSave = onSave
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chipBar
                Divider()
                RuleTextView(text: $text, font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), bridge: bridge)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                if let help = spec.helpText {
                    Text(localized(help))
                        .font(DSFont.caption2)
                        .foregroundColor(DSColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .navigationTitle(localized(spec.label))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text(localized("取消"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(text)
                        dismiss()
                    } label: {
                        Text(localized("完成"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        text = ""
                    } label: {
                        Label(localized("清空"), systemImage: "trash")
                    }
                }
            }
            .onAppear {
                bridge.textView?.becomeFirstResponder()
            }
        }
    }

    /// One horizontally scrollable row of insert chips above the editor.
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.insertChips, id: \.self) { chip in
                    Button {
                        insert(chip)
                    } label: {
                        Text(chip)
                            .font(DSFont.fixed(size: 12, design: .monospaced))
                            .foregroundColor(DSColor.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DSColor.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(chip)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
        .accessibilityLabel(localized("規則插入"))
    }

    private func insert(_ chip: String) {
        if let textView = bridge.textView {
            textView.insertText(chip)
        } else {
            text += chip
        }
    }
}

// MARK: - UITextView Bridge

/// Shared reference to the underlying `UITextView` so chips can insert at the
/// live cursor position (SwiftUI `TextEditor` exposes no selection API).
/// MainActor-isolated because it hands out a `UITextView`. `ObservableObject`
/// predates concurrency and declares `objectWillChange` non-isolated, so the
/// conformance is `@preconcurrency`: SwiftUI only touches the publisher from the
/// main actor anyway, and the alternative (a `nonisolated` stored publisher)
/// isn't expressible — `ObservableObjectPublisher` is not `Sendable`.
@MainActor
final class RuleTextViewBridge: @preconcurrency ObservableObject {
    /// No `@Published` properties, so the default publisher is not synthesized —
    /// provide it explicitly.
    let objectWillChange = ObservableObjectPublisher()
    weak var textView: UITextView?
}
/// Monospaced `UITextView` that syncs `text` both ways and exposes the view to
/// `RuleTextViewBridge` for cursor-position inserts.
private struct RuleTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let bridge: RuleTextViewBridge

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = font
        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.text = text
        textView.delegate = context.coordinator
        bridge.textView = textView
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        bridge.textView = uiView
        // Only rewrite when the value changed outside the text view (e.g. 清空) —
        // replacing text on every keystroke would reset the cursor.
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RuleTextView

        init(_ parent: RuleTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
