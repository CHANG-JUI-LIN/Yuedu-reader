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

/// 書籍資訊 (book info / cover editing) presents the photo and file pickers for
/// 選擇圖片. As a sheet it is the same shape iOS 17 drops: a presented sheet asked
/// to resolve a presenter for a picker. Push it from the bookshelf on iOS 17 so
/// its pickers are first-level presentations, exactly as book-source management
/// does. iOS 18 keeps the sheet. Delete when the deployment target reaches iOS 18.
enum BookInfoEditPresentationPolicy {
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

/// Reader settings is itself presented as a sheet. On iOS 17, asking that
/// sheet to present a document picker can be dropped even when the import
/// control is a direct button. Dismiss reader settings first, then let the
/// reader's first-level presenter open the picker from the sheet's real
/// `onDismiss` callback. Delete this policy when the deployment target reaches
/// iOS 18.
///
/// Covers every document picker reader settings owns — font import, and the
/// 閱讀設定 / 正則高亮 style importers, whose 匯入 controls sit on pages pushed
/// *inside* that sheet (and, for 正則高亮, inside a `Menu` as well).
enum ReaderSettingsPresentationPolicy {
    static func requiresFirstLevelImporter(
        osMajorVersion: Int
    ) -> Bool {
        osMajorVersion < 18
    }

    static var requiresFirstLevelImporter: Bool {
        requiresFirstLevelImporter(
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
