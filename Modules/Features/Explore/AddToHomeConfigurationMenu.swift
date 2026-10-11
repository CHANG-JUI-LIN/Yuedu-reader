import SwiftUI

/// 加入首頁配置's choices (unified library 5d-4, decision 22): each 首頁配置, adding the category
/// to it as a 橫向單排書架 at its end. One that shows the category already is ticked and left
/// alone.
struct AddToHomeConfigurationItems: View {
    let reference: ExploreCategoryReference

    @ObservedObject private var store = HomePageStore.shared

    var body: some View {
        ForEach(store.configurations) { configuration in
            let added = store.contains(reference, in: configuration.id)
            Button {
                store.addCategory(reference, to: configuration.id)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(format: localized("已加入「%@」"), configuration.name)
                )
            } label: {
                if added {
                    Label(configuration.name, systemImage: "checkmark")
                } else {
                    Text(configuration.name)
                }
            }
            .disabled(added)
        }
    }
}

/// 加入首頁配置 as a submenu, for a category's long-press menu.
struct AddToHomeConfigurationMenu: View {
    let reference: ExploreCategoryReference

    var body: some View {
        Menu {
            AddToHomeConfigurationItems(reference: reference)
        } label: {
            Label(localized("加入首頁配置"), systemImage: "rectangle.stack.badge.plus")
        }
    }
}

#Preview("加入首頁配置") {
    Menu("分類") {
        AddToHomeConfigurationMenu(reference: ExploreCategoryReference(sourceURL: "https://source.test", title: "玄幻", url: "/xuanhuan"))
    }
}
