import SwiftUI

struct RSSFaviconView: View {
    let source: RSSSource
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url = RSSFaviconResolver.faviconURL(for: source) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.18), style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: max(4, size * 0.18), style: .continuous)
            .fill(DSColor.accent.opacity(0.14))
            .overlay {
                Image(systemName: "newspaper")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundColor(DSColor.accent)
            }
    }
}

#Preview {
    RSSFaviconView(source: RSSSource(
        name: "BBC",
        url: "https://feedx.net/rss/bbc.xml",
        homepageURL: "https://www.bbc.com",
        sortOrder: 0
    ))
    .padding()
}
