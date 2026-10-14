import Foundation

// Unified library Phase 6a: every source describes itself the same way (design §14.2, step 1;
// the "Capability Protocol" and "module manifest" of the idea document). Computed from what each
// provider already reports, never stored beside it, so each fact keeps one owner.

/// What a source can do.
enum ProviderCapability: Hashable, Sendable {
    /// Browsed by location (`CollectionBrowsing`).
    case browse
    /// Puts rows on the Explore home (`HomeSectionProviding`). How each section loads stays the
    /// section's own (`SectionLoadPolicy`, per section since 5b).
    case homeSections
    /// Searched, and when; never `.none`.
    case search(CollectionSearchSupport)
    /// Answers a work's details (a 來源配置's book-info rule; 6b).
    case metadata
    /// Its items can be read in the app (a 來源配置's table of contents and content rules; 6b).
    case reading
}

struct ProviderManifest: Hashable, Sendable {
    let instance: SourceInstanceKey
    let displayName: String
    let availability: ProviderAvailability
    let capabilities: Set<ProviderCapability>
    /// The hosts its requests go to, in the order it uses them; empty for on-device data.
    let hosts: [String]
    /// Its declared request rate in Legado's `concurrentRate` syntax (`SourceRateLimit`); nil
    /// when it declares none.
    let rateLimit: String?
}

extension SourceProvider {
    /// What it declares beyond the protocols it conforms to.
    var additionalCapabilities: Set<ProviderCapability> { [] }
    var rateLimit: String? { nil }

    func manifest() async -> ProviderManifest {
        var capabilities = additionalCapabilities
        if let browsing = self as? any CollectionBrowsing {
            capabilities.insert(.browse)
            let search = await browsing.capabilities().search
            if search != .none { capabilities.insert(.search(search)) }
        }
        if self is any HomeSectionProviding { capabilities.insert(.homeSections) }
        return ProviderManifest(instance: instance, displayName: displayName, availability: availability,
                                capabilities: capabilities, hosts: hosts, rateLimit: rateLimit)
    }
}

extension URL {
    /// The host a provider rooted here sends its requests to, as a one-element list.
    var providerHosts: [String] { host.map { [$0] } ?? [] }
}
