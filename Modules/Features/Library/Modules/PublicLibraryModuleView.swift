import SwiftUI

/// 古騰堡's and 青空文庫's page in 資源庫's 官方模組, laid out as a bundled module's
/// (`RuleModuleDetailView`): what they give 首頁 and 搜索, and the sites they reach. An official
/// module has no page of books to browse (maintainer, 2026-10-21, and again 2026-10-22 when these
/// two still opened their shelves): its lists are read on 首頁, its books found by 搜索.
struct PublicLibraryModuleView: View {
    let key: SourceInstanceKey
    @ObservedObject private var aggregation = AggregationSettingsStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent(localized("網站"), value: site)
                attribution
            } header: {
                Text(title).foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                ForEach(lists, id: \.self) { list in
                    Text(list).foregroundStyle(DSColor.textPrimary)
                }
                Text(localized("搜索")).foregroundStyle(DSColor.textPrimary)
            } header: {
                Text(localized("清單")).foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                ForEach(hosts, id: \.self) { Text($0).foregroundStyle(DSColor.textPrimary) }
            } header: {
                Text(localized("會連線的網站")).foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                Text(localized("官方模組")).foregroundStyle(DSColor.textPrimary)
            } footer: {
                // They search and feed 最新, and fill nothing: not 資料來源, as a module's page says.
                Text(localized("隨閱讀一起更新，不能移除；不想用時，在「搜尋來源」和「最新來源」取消勾選。")).dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    private var title: String {
        AppOfficialModule.library(key).title
    }

    private var site: String {
        AppOfficialModule.library(key).summary
    }

    /// The license line its shelves carried.
    @ViewBuilder
    private var attribution: some View {
        if key.type == .aozora {
            Text(.init(localized("書誌資料：青空文庫（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）")))
                .foregroundStyle(DSColor.textSecondary)
        } else {
            Text(localized("Project Gutenberg 的書在美國屬於公有領域；所在地區的著作權規定可能不同。"))
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    /// What 首頁's 新增欄目 offers from it, in the same order and words.
    private var lists: [String] {
        if key.type == .aozora {
            return HomeSectionBinding.aozora.map { HomeSection(layout: .row, binding: $0).displayTitle(sourceName: "") }
        }
        return GutenbergShelf.shelves(languages: aggregation.readingLanguages.languages).map(\.title)
            + HomeSectionBinding.gutenbergCollections.map { HomeSection(layout: .row, binding: $0).displayTitle(sourceName: "") }
    }

    /// 青空文庫's catalog comes from our site, its texts from 青空文庫's; Gutenberg's feeds,
    /// covers and books all come from its own.
    private var hosts: [String] {
        if key.type == .aozora {
            return [AozoraCatalogStore.manifestURL.host(), AozoraLibraryDownloadService.host].compactMap { $0 }
        }
        var hosts = [GutenbergEndpoint.current.rootURL.host()].compactMap { $0 }
        if !hosts.contains("www.gutenberg.org") { hosts.append("www.gutenberg.org") }
        return hosts
    }
}

#Preview("古騰堡") {
    NavigationStack {
        PublicLibraryModuleView(key: SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue))
    }
}

#Preview("青空文庫") {
    NavigationStack {
        PublicLibraryModuleView(key: SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue))
    }
}
