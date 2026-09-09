import Foundation
import SwiftUI

extension ReaderView {

    /// Opens the store the header/footer bars read imported battery SVGs from.
    ///
    /// All that survives of the in-place overlay editor. Editing moved to
    /// `ReaderBarLayoutEditorView`, a pushed settings page — so there is no longer
    /// a mode in which the reader hands its own surface over to an editor, and the
    /// interaction-suppression, scope-jumping and safe-area plumbing that mode
    /// needed went with it.
    ///
    /// The disposable fallback store matters: a text-only bar must still draw when
    /// the persistent store cannot be opened. Only a persistent store may mint
    /// asset IDs, which is why the flag is tracked separately.
    func ensureReaderOverlaySVGAssetStore() {
        guard readerOverlaySVGAssetStore == nil
                || !readerOverlaySVGAssetStoreIsPersistent
        else { return }
        do {
            readerOverlaySVGAssetStore = try ReaderOverlaySVGAssetStore.live()
            readerOverlaySVGAssetStoreIsPersistent = true
        } catch {
            if readerOverlaySVGAssetStore == nil {
                readerOverlaySVGAssetStore = ReaderOverlaySVGAssetStore(
                    rootDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ReaderOverlayFallback", isDirectory: true)
                )
            }
            readerOverlaySVGAssetStoreIsPersistent = false
        }
    }
}
