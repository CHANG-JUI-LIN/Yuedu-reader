import CoreText
import UIKit

/// Downloads iOS's optional CJK system fonts on demand.
///
/// iOS ships only **PingFang** (SC/TC/HK/MO) preinstalled; 楷体 (Kaiti SC), 宋体 (Songti SC),
/// 圆体 (Yuanti SC) etc. are *downloadable* system fonts — `UIFont(name:)` returns nil until they
/// are fetched via `CTFontDescriptorMatchFontDescriptorsWithProgressHandler`. EPUBs that request
/// those families therefore fall back to PingFang on the first render. This installer kicks off the
/// (one-time, cached by the OS) download and posts `didInstallNotification` when it lands, so the
/// reader can re-paginate and pick up the real typeface.
final class CJKFontInstaller {
    static let shared = CJKFontInstaller()

    /// Posted (on the main queue) when a requested family finishes downloading. `object` is the family name.
    static let didInstallNotification = Notification.Name("CJKFontInstaller.didInstall")

    private let lock = NSLock()
    private var inFlight: Set<String> = []

    private init() {}

    /// True when the family already has at least one installed face.
    func isAvailable(_ family: String) -> Bool {
        !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    /// Requests `family` from the system if it isn't installed yet. No-op if already available or
    /// a download is already in flight. Posts `didInstallNotification` on success.
    func ensure(_ family: String) {
        if isAvailable(family) { return }

        lock.lock()
        let alreadyRequested = inFlight.contains(family)
        if !alreadyRequested { inFlight.insert(family) }
        lock.unlock()
        guard !alreadyRequested else { return }

        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family as CFString] as CFDictionary
        )

        // Run off the main thread; the progress handler may be invoked on an arbitrary queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            CTFontDescriptorMatchFontDescriptorsWithProgressHandler(
                [descriptor] as CFArray,
                nil
            ) { state, _ in
                switch state {
                case .didFinish:
                    self?.finish(family, success: true)
                    return false
                case .didFailWithError:
                    self?.finish(family, success: false)
                    return false
                default:
                    return true
                }
            }
        }
    }

    private func finish(_ family: String, success: Bool) {
        lock.lock()
        inFlight.remove(family)
        lock.unlock()
        guard success, isAvailable(family) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didInstallNotification, object: family)
        }
    }
}
