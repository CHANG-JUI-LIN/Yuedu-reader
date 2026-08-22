import SwiftUI

/// 段落筆記的編輯頁。
///
/// 版面刻意不用導覽列：標題「筆記」與時間並排在左，右邊一顆實心圓形完成鈕，
/// 下面是被標註的原文引用，再下面就是輸入區——開啟即聚焦，鍵盤直接彈出。
/// 這是使用者指定的設計，不是預設的 sheet chrome，所以每個控制項都自己帶
/// accessibilityLabel。
struct ReaderNoteEditorView: View {
    /// 被標註的原文。
    let excerpt: String
    /// 這條筆記的時間（新筆記為當下）。
    let date: Date
    /// 已有筆記時才顯示刪除鈕。
    let showsDelete: Bool
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        excerpt: String,
        note: String,
        date: Date,
        showsDelete: Bool,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.excerpt = excerpt
        self.date = date
        self.showsDelete = showsDelete
        self.onSave = onSave
        self.onDelete = onDelete
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
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            header
            excerptQuote
            editor
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DSColor.background.ignoresSafeArea())
        .onAppear { isFocused = true }
    }

    // MARK: - 標題列

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Text(localized("筆記"))
                .font(DSFont.title3.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)

            Text(timeText)
                .font(DSFont.title3)
                .foregroundStyle(DSColor.textSecondary)

            Spacer(minLength: DSSpacing.sm)

            if showsDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(DSFont.toolbarIconLarge)
                        .frame(
                            width: DSLayout.minimumTapTarget,
                            height: DSLayout.minimumTapTarget
                        )
                }
                .accessibilityLabel(localized("刪除筆記"))
            }

            Button {
                onSave(text)
            } label: {
                Image(systemName: "checkmark")
                    .font(DSFont.toolbarIconLarge)
                    .foregroundStyle(DSColor.neutralControlEmphasizedForeground)
                    .frame(
                        width: DSLayout.readerNoteEditorDoneSize,
                        height: DSLayout.readerNoteEditorDoneSize
                    )
                    .background(DSColor.neutralControlEmphasizedFill, in: Circle())
            }
            .accessibilityLabel(localized("完成"))
        }
    }

    // MARK: - 原文引用

    private var excerptQuote: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Capsule()
                .fill(DSColor.border)
                .frame(width: DSLayout.readerNoteQuoteBarWidth)
                .accessibilityHidden(true)

            Text(excerpt)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                onSave: { _ in },
                onDelete: {}
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
                onSave: { _ in },
                onDelete: {}
            )
        }
}
