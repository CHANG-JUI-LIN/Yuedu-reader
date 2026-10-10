import SwiftUI

/// What is being asked about the reader's custom pages: a name for a new page or a renamed
/// one, or whether to delete one. Shared by 探索's old root and the home (unified library 5c-3).
enum CustomExplorePagePrompt: Identifiable {
    case create
    case rename(CustomExplorePage)
    case delete(CustomExplorePage)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let page): "rename|" + page.id.uuidString
        case .delete(let page): "delete|" + page.id.uuidString
        }
    }
}

extension View {
    /// The name alert and the delete dialog for `prompt`. One alert serves both names: two on
    /// one view compete for one presenter. Deleting the page 首屏配置 opens turns 首屏配置 off.
    func customExplorePagePrompts(_ prompt: Binding<CustomExplorePagePrompt?>) -> some View {
        modifier(CustomExplorePagePrompts(prompt: prompt))
    }
}

/// A custom page's long-press actions.
struct CustomExplorePageMenuItems: View {
    let page: CustomExplorePage
    @Binding var prompt: CustomExplorePagePrompt?

    var body: some View {
        Button {
            prompt = .rename(page)
        } label: {
            Label(localized("重新命名"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            prompt = .delete(page)
        } label: {
            Label(localized("刪除"), systemImage: "trash")
        }
    }
}

private struct CustomExplorePagePrompts: ViewModifier {
    @Binding var prompt: CustomExplorePagePrompt?
    @ObservedObject private var pageStore = CustomExplorePageStore.shared
    @AppStorage(ExploreSettings.landingKey) private var landing = ExploreLanding.off.rawValue
    @State private var name = ""

    private var naming: CustomExplorePagePrompt? {
        switch prompt {
        case .create, .rename: prompt
        case .delete, nil: nil
        }
    }

    private var deleting: CustomExplorePage? {
        if case .delete(let page) = prompt { return page }
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
                    Button(localized("新建")) { pageStore.createPage(named: name) }
                case .rename(let page):
                    Button(localized("確定")) { pageStore.renamePage(id: page.id, to: name) }
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
                ) { page in
                    Button(localized("刪除"), role: .destructive) { delete(page) }
                    Button(localized("取消"), role: .cancel) {}
                } message: { _ in
                    Text(localized("頁面裡的元件會一起刪除。"))
                }
            }
            .onChange(of: prompt?.id) { _, _ in
                switch prompt {
                case .create: name = ""
                case .rename(let page): name = page.name
                case .delete, nil: break
                }
            }
    }

    private func title(_ prompt: CustomExplorePagePrompt) -> String {
        switch prompt {
        case .create: localized("新增自訂頁")
        case .rename, .delete: localized("重新命名")
        }
    }

    /// Deletes the page; 首屏配置 set to it goes back to off.
    private func delete(_ page: CustomExplorePage) {
        if ExploreLanding(rawValue: landing) == .customPage(id: page.id) {
            landing = ExploreLanding.off.rawValue
        }
        pageStore.deletePage(id: page.id)
    }
}
