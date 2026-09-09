import SwiftUI
import UIKit

/// A native detail destination above a UIKit-owned reader. Its push/pop is
/// intentionally independent of the book-cover animator used to close the reader.
@MainActor
final class ReaderDetailHostingController: UIHostingController<AnyView> {
    init(content: AnyView) {
        super.init(rootView: content)
        hidesBottomBarWhenPushed = true
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = localized("書籍詳情")
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.hidesBackButton = false
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
}
