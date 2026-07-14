import SwiftUI

private enum ReaderOverlayEditorPersistenceError: Error {
    case writeFailed
}

extension ReaderView {
    var readerOverlayEditorReaderStyle: ReaderOverlayReaderStyle {
        ReaderOverlayReaderStyle(
            font: UserReaderFontResolver.bodyFont(size: max(fontSize, 8)),
            textColor: readerTheme.uiTextColor,
            availablePostScriptNames: Set(settings.userFonts.map(\.postScriptName))
        )
    }

    var readerOverlayEditorSafeAreaInsets: EdgeInsets {
        let insets = keyWindowScene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
    }

    func presentReaderHeaderFooterEditor() {
        guard !effectiveScrollMode else { return }
        if readerOverlaySVGAssetStore == nil {
            readerOverlaySVGAssetStore = try? ReaderOverlaySVGAssetStore.live()
        }
        guard readerOverlaySVGAssetStore != nil else { return }

        readerHeaderFooterEditorModel = ReaderHeaderFooterEditorModel(
            initial: settings.readerOverlayLayout
        ) { layout in
            guard settings.saveReaderOverlayLayout(layout) else {
                throw ReaderOverlayEditorPersistenceError.writeFailed
            }
        }
        showBars = false
    }
}
