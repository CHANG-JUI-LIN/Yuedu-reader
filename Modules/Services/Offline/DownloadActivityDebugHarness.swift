#if DEBUG
import ActivityKit
import Foundation
import UIKit

/// Starts a Live Activity with invented data so the Dynamic Island can be looked at without a
/// real download.
///
/// A Live Activity cannot be rendered by a unit test or a SwiftUI preview that `xcodebuild` can
/// run, so the only way to check its layout is to put one on screen. Reaching that state
/// normally needs a book source, a network, and several minutes of downloading — which made
/// every layout change a round trip through the user.
///
/// Launch with `-debugDownloadActivity` to start one, and `-debugDownloadActivityPaused` to
/// start it in the paused state. DEBUG only; nothing here ships.
@MainActor
enum DownloadActivityDebugHarness {

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-debugDownloadActivity") else { return }
        let paused = arguments.contains("-debugDownloadActivityPaused")
        let bookCount = arguments.contains("-debugDownloadActivityMultiple") ? 3 : 1

        publishFakeCovers(count: bookCount)
        if arguments.contains("-debugDownloadActivityFresh") {
            let state = makeState(bookCount: bookCount, paused: paused)
            Task {
                for activity in Activity<DownloadActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    for await activityState in activity.activityStateUpdates {
                        guard activityState != .ended, activityState != .dismissed else { break }
                    }
                }
                do {
                    _ = try Activity.request(
                        attributes: DownloadActivityAttributes(),
                        content: ActivityContent(state: state, staleDate: nil)
                    )
                } catch {
                    AppLogger.cache("⟐ fresh debug Live Activity failed", error: error)
                }
            }
            return
        }
        DownloadLiveActivityController.shared.apply(makeState(bookCount: bookCount, paused: paused))

        // `-debugDownloadActivityToggle` exercises the update path rather than the start path:
        // pausing a real download pushes exactly one more state and then goes quiet, so if that
        // push is dropped the activity is stuck on stale content with nothing to correct it.
        // Apply it immediately after `start` so it deliberately lands inside the progress
        // throttle window; waiting several seconds only exercised the zero-delay happy path.
        guard arguments.contains("-debugDownloadActivityToggle") else { return }
        DownloadLiveActivityController.shared.apply(
            makeState(bookCount: bookCount, paused: !paused)
        )
        AppLogger.cache("⟐ debug harness toggled paused state", context: ["paused": !paused])
    }

    private static func makeState(
        bookCount: Int,
        paused: Bool
    ) -> DownloadActivityAttributes.ContentState {
        let titles = ["巫師：從合成寶石開始", "劍來", "詭祕之主"]
        let books = (0..<bookCount).map { index in
            DownloadActivityAttributes.ContentState.Book(
                id: fakeBookId(index).uuidString,
                title: titles[index % titles.count],
                completedChapters: 4 + index * 7,
                totalChapters: 50,
                isPaused: paused,
                coverFilename: "\(fakeBookId(index).uuidString).jpg"
            )
        }
        return .init(books: books)
    }

    /// A flat colour is enough to see how the artwork is framed — the point is the geometry.
    private static func publishFakeCovers(count: Int) {
        guard let directory = DownloadActivityAttributes.coverDirectory() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemIndigo, .systemTeal, .systemOrange]
        for index in 0..<count {
            let url = directory.appendingPathComponent("\(fakeBookId(index).uuidString).jpg")
            let size = CGSize(width: 120, height: 180)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                colors[index % colors.count].setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            try? image.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
        }
    }

    /// Stable across launches so the published cover and the state agree.
    private static func fakeBookId(_ index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", index))")
            ?? UUID()
    }
}
#endif
