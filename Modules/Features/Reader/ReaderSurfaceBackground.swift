import SwiftUI

/// The surface a page is read on: the reading theme's colour, under the saved background's
/// picture when it wears one. The reader draws it behind its pages and its 載入中…, and so does
/// a book still being readied before there is a reader (`ReaderPreparingView`).
struct ReaderSurfaceBackground: View {
    let theme: ReaderTheme
    /// `GlobalSettings.readerBackgroundImageURL(wearing:)`.
    let imageURL: URL?

    var body: some View {
        // Keep decorative pixels out of layout measurement. A tall image used
        // as a ZStack child reports its aspect-sized height and pushes reader
        // chrome beyond both viewport edges; an overlay inherits the color's
        // already-constrained reader surface instead.
        theme.backgroundColor
            .overlay {
                if let imageURL, let image = UIImage(contentsOfFile: imageURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

#Preview("Reading surface · 黑色") {
    ReaderSurfaceBackground(theme: .night, imageURL: nil)
}
