import SwiftUI

struct AdaptiveContentContainer<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder var content: Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCenteredWidth: Bool {
        horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        content
            .frame(maxWidth: usesCenteredWidth ? maxWidth : .infinity, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct AdaptiveSheetContainer<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder var content: Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCenteredWidth: Bool {
        horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        content
            .frame(maxWidth: usesCenteredWidth ? maxWidth : .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
