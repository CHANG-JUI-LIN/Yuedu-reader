import SwiftUI

/// A detail-origin reader is a destination in the existing SwiftUI stack.
/// Only a modal reader needs a stack of its own.
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

/// A reader that is a page of someone else's stack never holds one of its own: its
/// toolbar is that stack's bar. That is a detail-origin reader
/// (`readerUsesParentNavigationStack`) and 書架's card push (a `readerNavigator`),
/// whose UIKit host sits on the root stack (`RootNavigation`).
///
/// The card reader must not wrap itself either. A UIKit-pushed page whose content
/// is a `NavigationStack` around UIKit page controllers is taken off a SwiftUI stack
/// that registers any `navigationDestination(for:)` — the root stack does — the
/// moment its push settles: the reader opened and fell straight back to 書架
/// (2026-10-17, `RootTabNavigationContractTests`).
struct ReaderNavigationContainer<Content: View>: View {
    @Environment(\.readerUsesParentNavigationStack) private var usesParentStack
    @Environment(\.readerNavigator) private var readerNavigator
    @ViewBuilder var content: Content

    var body: some View {
        if usesParentStack || readerNavigator != nil {
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
