import SwiftUI
import UIKit

/// Presents a duokan footnote as an arrow popover anchored to its tapped marker (多看-style),
/// keeping the reader in place instead of jumping to the chapter tail. Shared by the paged
/// reader (`CoreTextPageViewController`) and the scroll reader
/// (`CoreTextCollectionScrollViewController`) so both modes behave identically.
final class FootnotePopoverHost: UIHostingController<FootnotePopoverContent>, UIPopoverPresentationControllerDelegate {

    static func present(
        text: String,
        from presenter: UIViewController,
        sourceView: UIView,
        sourceRect: CGRect
    ) {
        if presenter.presentedViewController != nil { return }
        let maxWidth = min(300, max(200, sourceView.bounds.width - 64))
        let host = FootnotePopoverHost(rootView: FootnotePopoverContent(text: text))
        host.modalPresentationStyle = .popover
        host.preferredContentSize = FootnotePopoverContent.preferredSize(text: text, maxWidth: maxWidth)
        if let popover = host.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = host
        }
        presenter.present(host, animated: true)
    }

    // Keep the footnote presentation an anchored popover (with arrow) even in a compact width
    // class, instead of adapting to a full-screen sheet.
    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

/// Footnote popover body — scrollable note text, sized to fit its content.
struct FootnotePopoverContent: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(FootnotePopoverContent.contentInset)
        }
    }

    static let contentInset: CGFloat = 14

    /// Measures the note so the popover can size itself (UIKit popovers need a preferredContentSize).
    static func preferredSize(text: String, maxWidth: CGFloat) -> CGSize {
        let font = UIFont.preferredFont(forTextStyle: .callout)
        let textWidth = maxWidth - contentInset * 2
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let height = ceil(bounds.height) + contentInset * 2
        return CGSize(width: maxWidth, height: min(height, 360))
    }
}

#Preview {
    FootnotePopoverContent(text: "◎近年来，韩国将长词句缩短、化作简称的各式流行语风行一时，原先起自网络族群，现在大众的日常用语、会话中也日渐普及。")
        .frame(width: 280, height: 160)
}
