import SwiftUI

/// The app's one navigation stack, wrapped around the tab bar: every page a tab pushes goes on
/// it and covers the tab bar as it slides in (maintainer, 2026-10-16). One heterogeneous path
/// for every page past the tab roots, so back pops one page (postmortem guardrail 11).
///
/// A reference that never changes, so a page can hold it without its body depending on the
/// path (guardrail 13). Only `ContentView` binds the path.
@MainActor @Observable
final class RootNavigation {
    var path = NavigationPath()
}

extension EnvironmentValues {
    /// The root stack. Nil outside `ContentView`: in previews and design fixtures.
    @Entry var rootNavigation: RootNavigation?
}
