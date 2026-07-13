import SwiftUI

struct ReaderFootnoteItem: Identifiable {
    let id = UUID()
    let text: String
}

struct ReaderFootnotePopupView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DSSpacing.lg)
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("註釋"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成"), action: onClose)
                }
            }
        }
    }
}

#Preview {
    ReaderFootnotePopupView(
        text: "◎近年來，韓國將長詞句縮短、化作簡稱的各式流行語風行一時，原先起自網絡族群，現在大眾的日常用語、會話中也日漸普及。"
    ) {}
}
