import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var readerBookId: UUID? = nil
    @State private var selectedBookFrame: CGRect = .zero
    @State private var isReaderExpanded = false
    @State private var bookFrames: [UUID: CGRect] = [:]

    var body: some View {
        ZStack {
            TabView {
                HomeView(openBook: { id in
                    guard readerBookId == nil else { return }
                    selectedBookFrame = bookFrames[id] ?? UIScreen.main.bounds
                    readerBookId = id
                })
                .tabItem { Label(gs.t("書架"), systemImage: "books.vertical") }
                .environmentObject(store)

                BrowserView()
                    .tabItem { Label(gs.t("瀏覽"), systemImage: "globe") }

                SettingsView()
                    .tabItem { Label(gs.t("設定"), systemImage: "gearshape") }
            }

            if let bookId = readerBookId {
                BookReaderOverlay(
                    bookId: bookId,
                    sourceFrame: selectedBookFrame,
                    isExpanded: isReaderExpanded,
                    onClose: {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                            isReaderExpanded = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            readerBookId = nil
                        }
                    }
                )
                .environmentObject(store)
                .onAppear {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        isReaderExpanded = true
                    }
                }
                .ignoresSafeArea()
            }
        }
        .onPreferenceChange(BookFramePreferenceKey.self) { frames in
            bookFrames = frames
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BookStore())
}
