import Foundation

/// A home section that draws from a module no longer installed (M6, the 模組 page's 首頁欄目引用):
/// it shows nothing, in whichever 首頁配置 holds it, until the module comes back or it is removed.
struct HomeModuleReference: Identifiable, Hashable, Sendable {
    let section: HomeSection
    let moduleID: String
    let configuration: HomeConfigurationListing

    var id: UUID { section.id }
}

extension HomeConfigurations {
    /// Every 首頁配置's sections bound to a module outside `installed`, configuration by configuration.
    func moduleReferences(installed: Set<String>) -> [HomeModuleReference] {
        listings.flatMap { listing in
            sections(of: listing.id).compactMap { section -> HomeModuleReference? in
                guard case .module(let moduleID, _) = section.binding, !installed.contains(moduleID) else { return nil }
                return HomeModuleReference(section: section, moduleID: moduleID, configuration: listing)
            }
        }
    }

    /// Takes the sections out of whichever 首頁配置 holds them.
    mutating func removeSections(_ ids: Set<UUID>) {
        sections.removeAll { ids.contains($0.id) }
        for index in configurations.indices {
            configurations[index].sections.removeAll { ids.contains($0.id) }
        }
    }
}
