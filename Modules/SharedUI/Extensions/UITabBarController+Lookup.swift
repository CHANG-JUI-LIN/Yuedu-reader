import UIKit

extension UITabBarController {
    /// The first tab bar controller in `controller`'s hierarchy — its children, then what it
    /// presents. Finds the app's root tab bar from the window's root where a page's own
    /// `tabBarController` comes back nil, as it does under iOS 17's SwiftUI `TabView`.
    static func first(in controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        for child in controller.children {
            if let found = first(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return first(in: presented)
        }
        return nil
    }
}
