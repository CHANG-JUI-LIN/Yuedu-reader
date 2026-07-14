import Foundation
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

    func ensureReaderOverlaySVGAssetStore() {
        guard readerOverlaySVGAssetStore == nil
                || !readerOverlaySVGAssetStoreIsPersistent
        else { return }
        do {
            readerOverlaySVGAssetStore = try ReaderOverlaySVGAssetStore.live()
            readerOverlaySVGAssetStoreIsPersistent = true
        } catch {
            // Runtime text/system-battery components must still render. The editor is
            // blocked below so this disposable store can never create persisted IDs.
            if readerOverlaySVGAssetStore == nil {
                readerOverlaySVGAssetStore = ReaderOverlaySVGAssetStore(
                    rootDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ReaderOverlayFallback", isDirectory: true)
                )
            }
            readerOverlaySVGAssetStoreIsPersistent = false
        }
    }

    func presentReaderHeaderFooterEditor() {
        guard !effectiveScrollMode else { return }
        ensureReaderOverlaySVGAssetStore()
        guard readerOverlaySVGAssetStoreIsPersistent else {
            showReaderOverlaySVGStoreError = true
            return
        }

        readerHeaderFooterEditorModel = ReaderHeaderFooterEditorModel(
            initial: settings.readerOverlayLayout,
            activeScope: ReaderOverlayPageScope.resolve(
                chapterPage: readerOverlayContentSnapshot.chapterPage
            ),
            onScopeChange: { scope in
                guard scope == .chapterOpening else { return }
                jumpToReaderOverlayChapterOpening()
            },
            onSave: { layout in
                guard settings.saveReaderOverlayLayout(layout) else {
                    throw ReaderOverlayEditorPersistenceError.writeFailed
                }
            }
        )
        showBars = false
    }

    private func jumpToReaderOverlayChapterOpening() {
        jumpToChapter(currentChapterIndex, charOffset: 0)
        pageTurnVersion &+= 1
        pageTurnCommand = ReaderPageTurnCommand(
            target: currentPage,
            animated: false,
            version: pageTurnVersion
        )
    }
}
