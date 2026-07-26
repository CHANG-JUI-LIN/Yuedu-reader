import Foundation

/// Chooses the compatibility presentation path for modal actions launched from
/// a SwiftUI `Menu`.
///
/// On iOS 17, the menu's UIKit presentation can still be dismissing when its
/// action mutates a sheet or document-picker binding. That second presentation
/// request can be dropped. iOS 18 changed menu-dismissal behavior, so later
/// systems keep the native menu path. Delete this policy when the deployment
/// target reaches iOS 18.
enum MenuModalPresentationPolicy {
    static func requiresDismissalSequencedChooser(
        osMajorVersion: Int
    ) -> Bool {
        osMajorVersion < 18
    }

    static var requiresDismissalSequencedChooser: Bool {
        requiresDismissalSequencedChooser(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
}

/// Book-source management owns several import and editor presentations. When
/// the management screen is itself a sheet, those destinations become nested
/// sheets; iOS 17 can drop even a direct-button presentation request. Push the
/// management screen on iOS 17 so its destinations have a stable presenter.
/// Delete this policy when the deployment target reaches iOS 18.
enum BookSourceManagementPresentationPolicy {
    static func prefersNavigationDestination(
        osMajorVersion: Int
    ) -> Bool {
        osMajorVersion < 18
    }

    static var prefersNavigationDestination: Bool {
        prefersNavigationDestination(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
}

/// Retains a menu choice until the compatibility chooser's real `onDismiss`
/// callback fires. This deliberately models a presentation boundary instead of
/// guessing UIKit's dismissal duration with `asyncAfter` or `Task.sleep`.
struct DismissalSequencedPresentation<Route> {
    private(set) var pendingRoute: Route?

    mutating func select(_ route: Route) {
        pendingRoute = route
    }

    mutating func consumeAfterDismissal() -> Route? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    mutating func cancel() {
        pendingRoute = nil
    }
}
