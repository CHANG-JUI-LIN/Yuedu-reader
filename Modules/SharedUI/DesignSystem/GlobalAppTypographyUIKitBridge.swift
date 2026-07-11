import UIKit

@MainActor
enum GlobalAppTypographyUIKitBridge {
    static func apply(postScriptName: String?) {
        let titleFont = GlobalAppTypography.uiFont(
            .headline,
            postScriptName: postScriptName,
            weight: .semibold
        )
        let largeTitleFont = GlobalAppTypography.uiFont(
            .largeTitle,
            postScriptName: postScriptName,
            weight: .bold
        )
        let tabFont = GlobalAppTypography.uiFont(
            .caption2,
            postScriptName: postScriptName
        )

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

    private static func updateAppearanceProxies(
        titleFont: UIFont,
        largeTitleFont: UIFont,
        tabFont: UIFont
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
        tabItem.setTitleTextAttributes([.font: tabFont], for: .normal)
        tabItem.setTitleTextAttributes([.font: tabFont], for: .selected)
    }

    private static func apply(
        to controller: UIViewController,
        titleFont: UIFont,
        largeTitleFont: UIFont,
        tabFont: UIFont,
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
        titleFont: UIFont,
        largeTitleFont: UIFont
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
        titleFont: UIFont,
        largeTitleFont: UIFont
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

    private static func update(_ tabBar: UITabBar, font: UIFont) {
        tabBar.items?.forEach { item in
            item.setTitleTextAttributes([.font: font], for: .normal)
            item.setTitleTextAttributes([.font: font], for: .selected)
        }
        tabBar.standardAppearance = tabAppearance(tabBar.standardAppearance, font: font)
        tabBar.scrollEdgeAppearance = tabBar.scrollEdgeAppearance.map {
            tabAppearance($0, font: font)
        }
    }

    private static func tabAppearance(
        _ source: UITabBarAppearance,
        font: UIFont
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

    private static func merging(
        font: UIFont,
        into attributes: [NSAttributedString.Key: Any]?
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes ?? [:]
        result[.font] = font
        return result
    }
}
