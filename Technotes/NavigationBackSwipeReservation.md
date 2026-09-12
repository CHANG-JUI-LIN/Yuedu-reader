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

On iOS 26+, the reservation uses UIKit's public `interactiveContentPopGestureRecognizer` and restricts its first touch to the 30-point strip. The physical-edge recognizer accepted a 1-point start but ignored 8- and 28-point starts in the iOS 27 reproduction, even though the reservation accepted the touch. Changing the delegate cannot expand that recognizer's internal edge region. The alternate physical-edge recognizer is suspended during ownership and its original enabled state is restored afterwards. Earlier systems use the native screen-edge recognizer with the OS-controlled start region.

Unimplemented delegate selectors are deliberately not forwarded: UIKit's original delegate includes a hidden-navigation-bar event veto that runs before the reservation's public touch/begin callbacks. The native recognizer and transition targets still supply progress, completion and cancellation; no custom animator or navigation-controller delegate is installed.

Use the modifier on the pushed destination, not the NavigationStack root. Do not add it to the UIKit card reader: ReaderNavigationTransitionDriver already owns that route's recognizer and custom interactive animation. The current app languages are LTR; adding an RTL app localization requires mirroring the shared start-region policy and recognizer edge together.

Regression coverage: NavigationBackSwipeReservationTests checks the start region, pan/tap priority, hidden-back support, delegate restoration, root-page no-op and adjacent-page handoff. DetailReaderStackTests exercises the modifier through a real SwiftUI push, nested detail, return and reopen, checking that the system recognizer is reserved only while the reader is visible.

`DetailReaderBackSwipeUITests` delivers actual edge drags to the production Explore → detail → reader route in slide, cover, curl, instant and scroll modes. It checks short-drag cancellation, interior page turns, return to the original detail, and reopening. Its deterministic local source avoids external website or login dependencies.

To reproduce on a booted simulator with the app installed, resolve its UDID using `scripts/sim.sh`, stop the app, and run:

```sh
python3 scripts/navigation_swipe_fixture.py prepare --simulator "$SIMULATOR_ID"
python3 scripts/navigation_swipe_fixture.py serve
```

Keep the server running while invoking `xcodebuild test` from the original checkout with `-destination "id=$SIMULATOR_ID" -parallel-testing-enabled NO -only-testing:'yuedu appUITests/DetailReaderBackSwipeUITests'`. After the run, stop the app and server, then run `python3 scripts/navigation_swipe_fixture.py clean --simulator "$SIMULATOR_ID"`. Prepare/clean only affect records owned by the fixture source UUID. The test's language, navigation and page-style preferences are launch arguments, not persistent user-setting edits.

## Verification (2026-09-12)

- Reproduced the failure with actual XCTest drags, then isolated the physical-edge limit: a 1 pt start worked while 8/28 pt starts failed. Using the native content-pop recognizer with the same reservation delegate allowed the 28 pt start.
- Current production code: all five `DetailReaderBackSwipeUITests` modes passed, including short-drag cancellation, interior page turns, 28 pt return, reopen and return again. Result: `/tmp/yuedu-back-swipe-ui-final.xcresult`, exit 0.
- Repeated cover mode with no shelf entry: the actual `Read Now` entry, return, and second entry passed. In the same standard-scheme run, 38 Swift Testing cases and the SwiftUI navigation-stack integration case passed. Result: `/tmp/yuedu-back-swipe-regression-final.xcresult`, exit 0.
- Built in the original checkout using `Yuedu-Engine.xcworkspace`, iPhone 17 Pro / iOS 27.0. A temporary UI-only scheme was used while unrelated engine-migration unit tests could not compile; it was removed before the final standard `Yuedu-Reader` scheme run.
- Fixture source and shelf records were removed after verification. No diagnostic recognizer, logging probe or debugger mutation remains in production code.

## Verification (2026-09-09)

- `xcodebuild test`: exit 0, 1 SwiftUI/UIKit integration test plus 37 tests across NavigationBackSwipeReservationTests, ReaderCardTransitionMathTests and ReaderNavigationTransitionDriverTests.
- Result bundle: `/tmp/yuedu-reserved-back-1.xcresult`; output: `/tmp/yuedu-reserved-back-1.log`.
- Simulator: iPhone 17 Pro, iOS 27.0, resolved via scripts/sim.sh. Production sources were live symlinks in the existing validation project snapshot; test source copies matched the workspace.
- Localization: all 3 files, 2366 keys passed.
- The integration test verifies the native recognizer is reserved on reader appearance, restored while its detail is above it, and reserved again on return. Gesture begin/priority/cancellation ownership is tested through UIKit; no automated finger-drag assertion is included.
