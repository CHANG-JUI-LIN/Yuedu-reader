import Foundation

final class ReaderRuntimeState {
    var systemBrightness: Double = 0.5
    var isRestoringPosition = true
    var savedPositionSnapshot: Double = 0
    var savedCoreTextRestoreTarget: (chapterIndex: Int, charOffset: Int)?
    var isApplyingCoreTextRestore = false
    var hasAppliedNonZeroRestore = false
    var isLoadingPipeline = false
    var curlStartupStartedAt: CFAbsoluteTime?
    var hasLoggedCurlInteractiveReady = false
    var hasPerformedInitialLoad = false
}
