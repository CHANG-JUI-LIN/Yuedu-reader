import SwiftUI
import Translation

extension View {
    @ViewBuilder
    func readerSelectionTranslation(isPresented: Binding<Bool>, text: String) -> some View {
        if #available(iOS 17.4, *) {
            translationPresentation(isPresented: isPresented, text: text)
        } else {
            self
        }
    }
}

#Preview {
    Text("閱讀內容").readerSelectionTranslation(isPresented: .constant(false), text: "閱讀內容")
}
