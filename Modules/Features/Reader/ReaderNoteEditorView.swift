import SwiftUI

/// 段落筆記的編輯頁。
///
/// 導覽列走原生 chrome（inline 標題＋trailing 的刪除／完成），內容區依序是
/// 時間、被標註的原文引用、輸入區——開啟即聚焦，鍵盤直接彈出。
///
/// `isEditable == false` 是「Pro 過期但這段本來就有筆記」的情況：內容照樣讀得到，
/// 只是不能改，底下換成一條續訂入口。
struct ReaderNoteEditorView: View {
    /// 被標註的原文。
    let excerpt: String
    /// 這條筆記的時間（新筆記為當下）。
    let date: Date
    /// 已有筆記時才顯示刪除鈕。
    let showsDelete: Bool
    /// Pro 生效時才可編輯。
    let isEditable: Bool
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onUpgrade: () -> Void
    let onClose: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        excerpt: String,
        note: String,
        date: Date,
        showsDelete: Bool,
        isEditable: Bool,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onUpgrade: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.excerpt = excerpt
        self.date = date
        self.showsDelete = showsDelete
        self.isEditable = isEditable
        self.onSave = onSave
        self.onDelete = onDelete
        self.onUpgrade = onUpgrade
        self.onClose = onClose
        _text = State(initialValue: note)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var timeText: String {
        Self.timeFormatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                Text(timeText)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)

                excerptQuote

                if isEditable {
                    editor
                } else {
                    readOnlyNote
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.top, DSSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DSColor.background.ignoresSafeArea())
            .navigationTitle(localized("筆記"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .onAppear {
            guard isEditable else { return }
            isFocused = true
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditable {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if showsDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(localized("刪除筆記"))
                }

                Button {
                    onSave(text)
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel(localized("完成"))
            }
        } else {
            // 唯讀時沒有東西可存，所以是「關閉」而不是「完成」，放 leading。
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(localized("關閉"))
            }
        }
    }

    // MARK: - 唯讀（Pro 過期）

    private var readOnlyNote: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text(text)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button {
                onUpgrade()
            } label: {
                Label(localized("訂閱 Pro 繼續編輯筆記"), systemImage: "lock.fill")
                    .font(DSFont.subheadline)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 原文引用

    /// 灰線用 `overlay` 掛在文字上，不是並排放進 HStack：`Capsule` 沒有固有高度，
    /// 並排時會被撐到整個可用高度（輸入區有多高它就有多長）。掛成 overlay 之後
    /// 它的尺寸就等於這段引用文字的實際高度。
    private var excerptQuote: some View {
        Text(excerpt)
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DSSpacing.md + DSLayout.readerNoteQuoteBarWidth)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(DSColor.border)
                    .frame(width: DSLayout.readerNoteQuoteBarWidth)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(localized("標註的原文"))
            .accessibilityValue(excerpt)
    }

    // MARK: - 輸入區

    /// 用 `TextEditor` 而不是多行 `TextField`：輸入區要佔滿剩下的整個版面，
    /// 點空白處也要能回到鍵盤——`TextField` 的可點區只有文字本身那幾行高。
    private var editor: some View {
        TextEditor(text: $text)
            .font(DSFont.body)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            // TextEditor 內建有一圈文字容器內距，扣掉後左緣才和上面的引用文字對齊。
            .padding(.leading, -DSSpacing.xs)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(localized("新增筆記…"))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textSecondary)
                        .padding(.top, DSSpacing.sm)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityLabel(localized("筆記內容"))
    }
}

#Preview("新筆記") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ReaderNoteEditorView(
                excerpt: "那現在到底是什麼狀況？我的腦中忽然變得一片混亂。如果能再重看一次《滅活法》，我就能更確定了。",
                note: "",
                date: Date(),
                showsDelete: false,
                isEditable: true,
                onSave: { _ in },
                onDelete: {},
                onUpgrade: {},
                onClose: {}
            )
        }
}

#Preview("已有筆記") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ReaderNoteEditorView(
                excerpt: "那現在到底是什麼狀況？我的腦中忽然變得一片混亂。",
                note: "這裡的伏筆對應第三章的實驗記錄。",
                date: Date(),
                showsDelete: true,
                isEditable: true,
                onSave: { _ in },
                onDelete: {},
                onUpgrade: {},
                onClose: {}
            )
        }
}

#Preview("Pro 過期唯讀") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ReaderNoteEditorView(
                excerpt: "那現在到底是什麼狀況？我的腦中忽然變得一片混亂。",
                note: "這裡的伏筆對應第三章的實驗記錄。",
                date: Date(),
                showsDelete: false,
                isEditable: false,
                onSave: { _ in },
                onDelete: {},
                onUpgrade: {},
                onClose: {}
            )
        }
}
