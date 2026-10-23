import SwiftUI

// Unified library 5d-4: what is asked about a 首頁配置 (Phase 5 plan, decision 22). Since
// 2026-10-22 首頁配置's own page asks it: 新增首頁配置 from one of its templates asks only the
// name (where to start is the template), and deleting one of the reader's own asks first. A
// name is changed on the configuration's own page.

enum HomeConfigurationPrompt: Identifiable {
    /// From the template tapped.
    case create(HomeConfigurationTemplate)
    case delete(HomeConfigurationListing)

    var id: String {
        switch self {
        case .create(let template): "create|" + template.rawValue
        case .delete(let configuration): "delete|" + configuration.id.rawValue
        }
    }
}

extension View {
    /// 新增首頁配置's name alert and the delete dialog for `prompt`.
    func homeConfigurationPrompts(_ prompt: Binding<HomeConfigurationPrompt?>) -> some View {
        modifier(HomeConfigurationPrompts(prompt: prompt))
    }
}

private struct HomeConfigurationPrompts: ViewModifier {
    @Binding var prompt: HomeConfigurationPrompt?
    @ObservedObject private var store = HomePageStore.shared
    @Environment(\.homeDefaults) private var homeDefaults
    @State private var name = ""

    /// Where a new one starts, while its name is asked.
    private var creating: HomeConfigurationTemplate? {
        if case .create(let template) = prompt { return template }
        return nil
    }

    private var deleting: HomeConfigurationListing? {
        if case .delete(let configuration) = prompt { return configuration }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .alert(
                localized("新增首頁配置"),
                isPresented: Binding(get: { creating != nil }, set: { if !$0 { prompt = nil } }),
                presenting: creating
            ) { template in
                TextField(localized("名稱"), text: $name)
                Button(localized("新增")) {
                    if let homeDefaults { store.createConfiguration(named: name, from: template, defaults: homeDefaults) }
                }
                // The home's stack, the only one that pushes 首頁配置's page, says whom the
                // defaults are for; a preview has none.
                .disabled(homeDefaults == nil)
                Button(localized("取消"), role: .cancel) {}
            }
            .background {
                Color.clear.confirmationDialog(
                    String(format: localized("刪除「%@」？"), deleting?.name ?? ""),
                    isPresented: Binding(get: { deleting != nil }, set: { if !$0 { prompt = nil } }),
                    titleVisibility: .visible,
                    presenting: deleting
                ) { configuration in
                    Button(localized("刪除"), role: .destructive) { store.deleteConfiguration(configuration.id) }
                    Button(localized("取消"), role: .cancel) {}
                } message: { _ in
                    Text(localized("首頁配置裡的欄目會一起刪除。"))
                }
            }
            .onChange(of: prompt?.id) { _, _ in
                if creating != nil { name = "" }
            }
    }
}

#Preview("新增首頁配置") {
    @Previewable @State var prompt: HomeConfigurationPrompt? = .create(.blank)
    Text(localized("探索"))
        .homeConfigurationPrompts($prompt)
        .environment(\.homeDefaults, HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: true,
                                                              languages: ["zh"]))
}

extension EnvironmentValues {
    /// Whom the home's defaults are for, set by the home for the pages it pushes: 預設配置
    /// makes a 首頁配置 from them.
    @Entry var homeDefaults: HomePageDefaults.Context? = nil
}
