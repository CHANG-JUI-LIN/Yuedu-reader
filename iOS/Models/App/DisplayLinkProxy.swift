import UIKit

/// CADisplayLink strongly references its target, causing a retain cycle.
/// DisplayLinkProxy acts as an intermediary, so CADisplayLink has a strong
/// reference to the proxy, and the proxy holds a weak reference to the real
/// target, ensuring the container view can deinit properly.
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
        _ = target.perform(action, with: link)
    }

    /// Creates a CADisplayLink that routes through a proxy to avoid retain cycles.
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
        return link
    }
}
