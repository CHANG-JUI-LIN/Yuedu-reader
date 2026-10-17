import SwiftUI

/// A detail-origin reader is a destination in the existing SwiftUI stack.
/// Shelf card transitions and modal readers still need their own inner stack.
private struct ReaderUsesParentNavigationStackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var readerUsesParentNavigationStack: Bool {
        get { self[ReaderUsesParentNavigationStackKey.self] }
        set { self[ReaderUsesParentNavigationStackKey.self] = newValue }
    }
}

struct DetailReaderRoute: Hashable, Identifiable {
    let id: UUID
}

struct ReaderNavigationContainer<Content: View>: View {
    @Environment(\.readerUsesParentNavigationStack) private var usesParentStack
    @ViewBuilder var content: Content

    var body: some View {
        if usesParentStack {
            content
        } else {
            NavigationStack { content }
        }
    }
}

#Preview {
    NavigationStack {
        ReaderNavigationContainer { Text(localized("閱讀")) }
            .environment(\.readerUsesParentNavigationStack, true)
    }
}
