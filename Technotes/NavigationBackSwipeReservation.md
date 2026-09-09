# Reserved Back-Swipe Region

For a SwiftUI page pushed into an existing NavigationStack:

```swift
BookReaderView(bookId: route.id)
    .navigationBarBackButtonHidden(true)
    .reservingNavigationBackSwipe()
```

The modifier lives in `Modules/SharedUI/Navigation/NavigationBackSwipeReservation.swift`. It uses UIKit's existing interactive-pop recognizer, including its percent-driven native transition and cancellation. It does not push/pop controllers itself, install an overlay, replace the UINavigationController delegate, or add a book animation. The destination's SwiftUI navigation route remains authoritative.

`NavigationBackSwipePolicy` owns the existing 30-point left-edge start limit and horizontal inward-drag decision. `NavigationBackEdgePanGestureRecognizer` is the extracted recognizer used by the bookshelf card-transition driver. Native and card navigation use the same geometry policy; competing page/scroll pans yield to back navigation, while taps are not given a failure dependency.

The reservation attaches to the exact ancestor navigation controller on viewDidAppear, refreshes when SwiftUI updates visible chrome, and relinquishes its delegate on viewDidDisappear or dismantling. Root pages do not attach. Adjacent reserved pages explicitly transfer ownership so they cannot restore a stale reservation as UIKit's delegate. No timer or global controller search is used.

Use the modifier on the pushed destination, not the NavigationStack root. Do not add it to the UIKit card reader: ReaderNavigationTransitionDriver already owns that route's recognizer and custom interactive animation. The current app languages are LTR; adding an RTL app localization requires mirroring the shared start-region policy and recognizer edge together.

Regression coverage: NavigationBackSwipeReservationTests checks the start region, pan/tap priority, hidden-back support, delegate restoration, root-page no-op and adjacent-page handoff. DetailReaderStackTests exercises the modifier through a real SwiftUI push, nested detail, return and reopen, checking that the system recognizer is reserved only while the reader is visible.

## Verification (2026-09-09)

- `xcodebuild test`: exit 0, 1 SwiftUI/UIKit integration test plus 37 tests across NavigationBackSwipeReservationTests, ReaderCardTransitionMathTests and ReaderNavigationTransitionDriverTests.
- Result bundle: `/tmp/yuedu-reserved-back-1.xcresult`; output: `/tmp/yuedu-reserved-back-1.log`.
- Simulator: iPhone 17 Pro, iOS 27.0, resolved via scripts/sim.sh. Production sources were live symlinks in the existing validation project snapshot; test source copies matched the workspace.
- Localization: all 3 files, 2366 keys passed.
- The integration test verifies the native recognizer is reserved on reader appearance, restored while its detail is above it, and reserved again on return. Gesture begin/priority/cancellation ownership is tested through UIKit; no automated finger-drag assertion is included.
