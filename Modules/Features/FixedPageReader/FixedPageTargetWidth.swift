import UIKit

/// The width fixed-page images are decoded for: the reader's own view, kept current by
/// `FixedPageReaderViewController` as that view resizes (a Stage Manager or Split View window,
/// a rotation, a fold). Held by reference so the mode readers — which hand it to every page and
/// cell they create — read the width at the moment they load, not the one they were installed with.
///
/// Zero until the view's first layout, which `FixedPageImageLoader` reads as "no downscale".
@MainActor
final class FixedPageTargetWidth {
    var value: CGFloat = 0
}
