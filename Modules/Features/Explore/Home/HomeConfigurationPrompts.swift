import SwiftUI

// Unified library 5d-4: what is asked about a 首頁配置 (Phase 5 plan, decision 22). Since
// 2026-10-22 首頁配置's own page asks it: 新增首頁配置 from its 預設配置 template asks only the
// name, and deleting one of the reader's own asks first. A name is changed on the
// configuration's own page.

enum HomeConfigurationPrompt: Identifiable {
    /// 預設配置: from 預設's sections.
    case create
    case delete(HomeConfigurationListing)

    var id: String {
        switch self {
        case .create: "create"
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
    @State private var name = ""

    /// While a new one's name is asked.
    private var creating: Bool {
        if case .create = prompt { return true }
        return false
    }

    private var deleting: HomeConfigurationListing? {
        if case .delete(let configuration) = prompt { return configuration }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .alert(
                localized("新增首頁配置"),
                isPresented: Binding(get: { creating }, set: { if !$0 { prompt = nil } })
            ) {
                TextField(localized("名稱"), text: $name)
                Button(localized("新增")) { store.createConfiguration(named: name) }
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
                if creating { name = "" }
            }
    }
}

#Preview("新增首頁配置") {
    @Previewable @State var prompt: HomeConfigurationPrompt? = .create
    Text(localized("探索"))
        .homeConfigurationPrompts($prompt)
}
