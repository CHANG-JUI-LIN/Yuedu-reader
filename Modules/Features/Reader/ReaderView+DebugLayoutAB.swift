#if DEBUG
import SwiftUI

extension ReaderView {
    var debugLayoutABAvailable: Bool {
        isEPUB
            && !effectiveScrollMode
            && !usesFixedLayoutRenderer
            && !isVerticalEPUB
            && activePublicationSession != nil
    }

    var debugEffectiveLayoutEngine: ReaderDebugLayoutEngine {
        ReaderDebugLayoutEngine(featureMode: epubRenderer.debugEffectiveLayoutEngine)
    }

    var debugLayoutABOverlay: some View {
        ReaderDebugLayoutABOverlay(
            effectiveEngine: debugEffectiveLayoutEngine,
            selectedEngine: debugSelectedLayoutEngine,
            isSwitching: !epubRenderer.isCoreTextReady,
            onSelect: switchDebugLayoutEngine
        )
    }

    func switchDebugLayoutEngine(_ target: ReaderDebugLayoutEngine) {
        guard debugLayoutABAvailable,
              epubRenderer.isCoreTextReady,
              target != debugEffectiveLayoutEngine,
              let engine = epubRenderer.engine else {
            debugSelectedLayoutEngine = debugEffectiveLayoutEngine
            return
        }

        let position: CoreTextReadingPosition
        if let exact = engine.readingPosition(forPage: currentPage) {
            position = exact
        } else {
            let fallback = engine.charOffset(forPage: currentPage)
            position = CoreTextReadingPosition(
                spineIndex: fallback.spineIndex,
                charOffset: fallback.charOffset
            )
        }

        savedCoreTextRestoreTarget = (position.spineIndex, position.charOffset)
        debugSelectedLayoutEngine = target
        isRestoringPosition = true
        guard epubRenderer.debugReloadPublication(
            mode: target.featureMode,
            renderSize: currentReaderRenderSize,
            settings: activeReaderRenderSettings
        ) else {
            savedCoreTextRestoreTarget = nil
            isRestoringPosition = false
            debugSelectedLayoutEngine = debugEffectiveLayoutEngine
            return
        }
        // The new engine's page zero is the only valid binding value until its
        // exact (spineIndex, charOffset) target is resolved by the existing
        // applyInitialProgressIfNeeded path.
        currentPage = 0
    }
}
#endif
