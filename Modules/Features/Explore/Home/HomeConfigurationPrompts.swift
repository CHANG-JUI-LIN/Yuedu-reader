import SwiftUI

// Unified library 5d-4: what is asked about a 首頁配置 (Phase 5 plan, decision 22). 新增首頁配置
// asks for a name and where to start in one alert (「可以問是要從預設調還是空白」); ••• → 首頁配置
// renames and deletes the reader's own (編輯首頁's card did until 2026-10-17).

enum HomeConfigurationPrompt: Identifiable {
    case create
    case rename(HomeConfigurationListing)
    case delete(HomeConfigurationListing)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let configuration): "rename|" + configuration.id.rawValue
        case .delete(let configuration): "delete|" + configuration.id.rawValue
        }
    }
}

extension View {
    /// The name alert and the delete dialog for `prompt`. One alert serves both names: two on
    /// one view compete for one presenter.
    func homeConfigurationPrompts(_ prompt: Binding<HomeConfigurationPrompt?>) -> some View {
        modifier(HomeConfigurationPrompts(prompt: prompt))
    }
}

private struct HomeConfigurationPrompts: ViewModifier {
    @Binding var prompt: HomeConfigurationPrompt?
    @ObservedObject private var store = HomePageStore.shared
    @State private var name = ""

    private var naming: HomeConfigurationPrompt? {
        switch prompt {
        case .create, .rename: prompt
        case .delete, nil: nil
        }
    }

    private var deleting: HomeConfigurationListing? {
        if case .delete(let configuration) = prompt { return configuration }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .alert(
                naming.map(title) ?? "",
                isPresented: Binding(get: { naming != nil }, set: { if !$0 { prompt = nil } }),
                presenting: naming
            ) { naming in
                TextField(localized("名稱"), text: $name)
                switch naming {
                case .create:
                    Button(localized("從預設開始")) { store.createConfiguration(named: name, from: .defaults) }
                    Button(localized("從空白開始")) { store.createConfiguration(named: name, from: .blank) }
                case .rename(let configuration):
                    Button(localized("確定")) { store.renameConfiguration(configuration.id, to: name) }
                case .delete:
                    EmptyView()
                }
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
                switch prompt {
                case .create: name = ""
                case .rename(let configuration): name = configuration.name
                case .delete, nil: break
                }
            }
    }

    private func title(_ prompt: HomeConfigurationPrompt) -> String {
        switch prompt {
        case .create: localized("新增首頁配置")
        case .rename, .delete: localized("重新命名")
        }
    }
}

#Preview("新增首頁配置") {
    @Previewable @State var prompt: HomeConfigurationPrompt? = .create
    Text(localized("探索"))
        .homeConfigurationPrompts($prompt)
}
