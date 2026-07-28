import UIKit

@MainActor
enum GlobalAppTypographyUIKitBridge {
    /// Pushes the user's global font choice into the UIKit chrome (navigation
    /// bars, tab bars) that SwiftUI's `.font` cannot reach.
    ///
    /// A `nil` font means "no custom font selected" — the default — and
    /// *removes* the override instead of re-stating the system font. Writing
    /// any explicit font into `titleTextAttributes` replaces UIKit's own
    /// Dynamic-Type-clamped title font with an unclamped scaled one, while the
    /// bar keeps laying out at its normal height; at large text sizes the tab
    /// title then grows over the tab icon.
    static func apply(postScriptName: String?) {
        let titleFont = chromeFont(.headline, postScriptName: postScriptName, weight: .semibold)
        let largeTitleFont = chromeFont(.largeTitle, postScriptName: postScriptName, weight: .bold)
        let tabFont = chromeFont(.caption2, postScriptName: postScriptName)

        updateAppearanceProxies(
            titleFont: titleFont,
            largeTitleFont: largeTitleFont,
            tabFont: tabFont
        )

        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
        var visited = Set<ObjectIdentifier>()
        for root in roots {
            apply(
                to: root,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont,
                tabFont: tabFont,
                visited: &visited
            )
        }
    }

    /// Bar chrome lays out at a fixed height, so a custom font has to stop
    /// growing where the system's own bar title does rather than scaling
    /// without bound.
    private static func chromeFont(
        _ style: GlobalAppTypography.Style,
        postScriptName: String?,
        weight: UIFont.Weight? = nil
    ) -> UIFont? {
        guard let postScriptName else { return nil }
        return GlobalAppTypography.uiFont(
            style,
            postScriptName: postScriptName,
            weight: weight,
            maximumPointSize: GlobalAppTypography.chromeMaximumPointSize(style)
        )
    }

    private static func updateAppearanceProxies(
        titleFont: UIFont?,
        largeTitleFont: UIFont?,
        tabFont: UIFont?
    ) {
        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = merging(
            font: titleFont,
            into: navigationBar.titleTextAttributes
        )
        navigationBar.largeTitleTextAttributes = merging(
            font: largeTitleFont,
            into: navigationBar.largeTitleTextAttributes
        )

        let tabItem = UITabBarItem.appearance()
        if let tabFont {
            tabItem.setTitleTextAttributes([.font: tabFont], for: .normal)
            tabItem.setTitleTextAttributes([.font: tabFont], for: .selected)
        } else {
            tabItem.setTitleTextAttributes(nil, for: .normal)
            tabItem.setTitleTextAttributes(nil, for: .selected)
        }
    }

    private static func apply(
        to controller: UIViewController,
        titleFont: UIFont?,
        largeTitleFont: UIFont?,
        tabFont: UIFont?,
        visited: inout Set<ObjectIdentifier>
    ) {
        let identifier = ObjectIdentifier(controller)
        guard visited.insert(identifier).inserted else { return }

        if let navigationController = controller as? UINavigationController {
            update(
                navigationController.navigationBar,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont
            )
        }
        if let tabController = controller as? UITabBarController {
            update(tabController.tabBar, font: tabFont)
        }

        for child in controller.children {
            apply(
                to: child,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont,
                tabFont: tabFont,
                visited: &visited
            )
        }
        if let presented = controller.presentedViewController {
            apply(
                to: presented,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont,
                tabFont: tabFont,
                visited: &visited
            )
        }
    }

    private static func update(
        _ navigationBar: UINavigationBar,
        titleFont: UIFont?,
        largeTitleFont: UIFont?
    ) {
        navigationBar.titleTextAttributes = merging(
            font: titleFont,
            into: navigationBar.titleTextAttributes
        )
        navigationBar.largeTitleTextAttributes = merging(
            font: largeTitleFont,
            into: navigationBar.largeTitleTextAttributes
        )
        navigationBar.standardAppearance = navigationAppearance(
            navigationBar.standardAppearance,
            titleFont: titleFont,
            largeTitleFont: largeTitleFont
        )
        navigationBar.compactAppearance = navigationBar.compactAppearance.map {
            navigationAppearance(
                $0,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont
            )
        }
        navigationBar.scrollEdgeAppearance = navigationBar.scrollEdgeAppearance.map {
            navigationAppearance(
                $0,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont
            )
        }
        navigationBar.compactScrollEdgeAppearance = navigationBar.compactScrollEdgeAppearance.map {
            navigationAppearance(
                $0,
                titleFont: titleFont,
                largeTitleFont: largeTitleFont
            )
        }
    }

    private static func navigationAppearance(
        _ source: UINavigationBarAppearance,
        titleFont: UIFont?,
        largeTitleFont: UIFont?
    ) -> UINavigationBarAppearance {
        let copy = source.copy()
        copy.titleTextAttributes = merging(
            font: titleFont,
            into: copy.titleTextAttributes
        )
        copy.largeTitleTextAttributes = merging(
            font: largeTitleFont,
            into: copy.largeTitleTextAttributes
        )
        return copy
    }

    private static func update(_ tabBar: UITabBar, font: UIFont?) {
        tabBar.items?.forEach { item in
            item.setTitleTextAttributes(
                merging(font: font, into: item.titleTextAttributes(for: .normal)),
                for: .normal
            )
            item.setTitleTextAttributes(
                merging(font: font, into: item.titleTextAttributes(for: .selected)),
                for: .selected
            )
        }
        let newStandard = tabAppearance(tabBar.standardAppearance, font: font)
        tabBar.standardAppearance = newStandard
        // Keep scrollEdgeAppearance in sync; when nil, the system provides a
        // default transparent appearance that differs from the modified
        // standard, causing white/transparent flicker on scroll.
        let scrollSource = tabBar.scrollEdgeAppearance ?? newStandard
        tabBar.scrollEdgeAppearance = tabAppearance(scrollSource, font: font)
    }

    private static func tabAppearance(
        _ source: UITabBarAppearance,
        font: UIFont?
    ) -> UITabBarAppearance {
        let copy = source.copy()
        let itemAppearances = [
            copy.stackedLayoutAppearance,
            copy.inlineLayoutAppearance,
            copy.compactInlineLayoutAppearance,
        ]
        for itemAppearance in itemAppearances {
            itemAppearance.normal.titleTextAttributes = merging(
                font: font,
                into: itemAppearance.normal.titleTextAttributes
            )
            itemAppearance.selected.titleTextAttributes = merging(
                font: font,
                into: itemAppearance.selected.titleTextAttributes
            )
        }
        return copy
    }

    /// Merges `font` into `attributes`, or strips the font key when `font` is
    /// `nil` so UIKit falls back to its own clamped bar title font.
    private static func merging(
        font: UIFont?,
        into attributes: [NSAttributedString.Key: Any]?
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes ?? [:]
        if let font {
            result[.font] = font
        } else {
            result.removeValue(forKey: .font)
        }
        return result
    }
}
