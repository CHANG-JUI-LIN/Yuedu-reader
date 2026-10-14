import Foundation

/// Phase 6b: a 來源配置 described by the same `ProviderManifest` as the built-in providers
/// (design §14.2, step 2), from the rules it has. Derived on demand, never stored per source:
/// a library can hold 50,000. Running a source still goes through `BookSourceSession`.
enum BookSourceManifest {
    /// A search URL searches on submit; explore URLs put rows on the home; any book-info rule
    /// answers a work's details; a table of contents with a content rule reads.
    nonisolated static func capabilities(of source: BookSource) -> Set<ProviderCapability> {
        var capabilities: Set<ProviderCapability> = []
        if hasRule(source.searchUrl) { capabilities.insert(.search(.onSubmit)) }
        if hasRule(source.exploreUrl) { capabilities.insert(.homeSections) }
        let info = source.ruleBookInfo
        if [info.name, info.author, info.coverUrl, info.intro, info.kind, info.tocUrl].contains(where: hasRule) {
            capabilities.insert(.metadata)
        }
        if hasRule(source.ruleToc.chapterList), hasRule(source.ruleContent.content) { capabilities.insert(.reading) }
        return capabilities
    }

    /// The host of the source's address, without the `#` comment Legado allows after it.
    nonisolated static func hosts(of source: BookSource) -> [String] {
        URL(string: source.cleanedBookSourceURL)?.providerHosts ?? []
    }

    /// `concurrentRate` as declared; nil when empty or `0`, which `SourceRateLimit` runs unlimited.
    nonisolated static func rateLimit(of source: BookSource) -> String? {
        let rate = source.concurrentRate.trimmingCharacters(in: .whitespacesAndNewlines)
        return rate.isEmpty || rate == "0" ? nil : rate
    }

    nonisolated static func derive(_ source: BookSource) -> ProviderManifest {
        ProviderManifest(instance: SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl),
                         displayName: source.bookSourceName, availability: .available,
                         capabilities: capabilities(of: source), hosts: hosts(of: source), rateLimit: rateLimit(of: source))
    }

    private nonisolated static func hasRule(_ rule: String) -> Bool {
        !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
