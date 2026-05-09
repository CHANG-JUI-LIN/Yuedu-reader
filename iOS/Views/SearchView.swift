import SwiftUI

struct SearchView: View {

    @State private var text = ""

    var body: some View {
        List {
            Text("搜尋結果")
        }
        .searchable(text: $text)
        .navigationTitle("搜尋")
    }
}
