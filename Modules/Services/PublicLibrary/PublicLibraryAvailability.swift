import Combine
import Foundation
import StoreKit

/// Mainland China uses source discovery only. Unknown storefronts are available;
/// a transient nil StoreKit answer preserves a previously known country, so a
/// cold launch in CHN cannot flash the libraries before StoreKit responds.
@MainActor
final class PublicLibraryAvailability: ObservableObject {
    static let shared = PublicLibraryAvailability()
    static let countryKey = "publicLibrary.lastStorefrontCountry"
    @Published private(set) var countryCode: String?
    var isAvailable: Bool { countryCode != "CHN" }
    private let defaults: UserDefaults
    private var currentTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        countryCode = defaults.string(forKey: Self.countryKey)
    }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await storefront in Storefront.updates {
                guard !Task.isCancelled else { return }
                self?.receive(countryCode: storefront.countryCode)
            }
        }
        currentTask = Task { [weak self] in
            let storefront = await Storefront.current
            guard !Task.isCancelled else { return }
            self?.receive(countryCode: storefront?.countryCode)
        }
    }

    func receive(countryCode: String?) {
        guard let countryCode else { return }
        self.countryCode = countryCode
        defaults.set(countryCode, forKey: Self.countryKey)
    }

    func observe(_ updates: AsyncStream<String>) async {
        for await code in updates { receive(countryCode: code) }
    }

    deinit {
        currentTask?.cancel()
        updatesTask?.cancel()
    }
}
