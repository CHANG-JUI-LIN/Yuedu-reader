import SwiftUI

struct PublicLibraryHomeView: View {
    var modeMenu: ExploreModeMenu? = nil
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section(localized("公有書庫")) {
                    Text(localized("公有書庫"))
                }.interfaceSectionSurface()
            }
            .listStyle(.insetGrouped)
            .themedAppSurface(for: .explore)
            .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
            .toolbar {
                if let modeMenu {
                    ToolbarItem(placement: .topBarTrailing) { modeMenu }
                }
            }
        }
    }
}

#Preview { PublicLibraryHomeView().environmentObject(BookStore()) }
