import UIKit

/// CADisplayLink 會強引用 target，導致 Retain Cycle。
/// 使用 WeakProxy 中介，讓 CADisplayLink → Proxy（強引用）→ target（弱引用），
/// 確保容器 View 被移除時能正常 deinit。
final class DisplayLinkProxy: NSObject {
    private weak var target: AnyObject?
    private let action: Selector

    init(target: AnyObject, selector: Selector) {
        self.target = target
        self.action = selector
        super.init()
    }

    @objc func proxyTick(_ link: CADisplayLink) {
        guard let target else {
            link.invalidate()
            return
        }
        // 透過 performSelector 轉發 tick
        _ = target.perform(action, with: link)
    }

    /// 建立一個透過 proxy 的 CADisplayLink
    static func displayLink(
        target: AnyObject,
        selector: Selector,
        preferredFPS: CAFrameRateRange? = nil
    ) -> CADisplayLink {
        let proxy = DisplayLinkProxy(target: target, selector: selector)
        let link = CADisplayLink(target: proxy, selector: #selector(proxyTick))
        if let fps = preferredFPS {
            link.preferredFrameRateRange = fps
        }
        // proxy 由 CADisplayLink 強引用，target 被 proxy 弱引用
        return link
    }
}
