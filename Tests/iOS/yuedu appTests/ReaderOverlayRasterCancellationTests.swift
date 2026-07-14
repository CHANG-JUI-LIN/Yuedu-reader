import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct ReaderOverlayRasterCancellationTests {
    @Test("cancelling an active raster request resumes without a stale image")
    @MainActor
    func activeRasterCancellation() async {
        let unique = UUID().uuidString
        let svg = """
        <svg width="80" height="40" xmlns="http://www.w3.org/2000/svg">
          <rect width="80" height="40" fill="#3366CC"/>
          <text x="4" y="24" font-size="8">\(unique)</text>
        </svg>
        """
        let task = Task { @MainActor in
            await SVGWebViewRasterizer.shared.render(
                svgString: svg,
                size: CGSize(width: 80, height: 40)
            )
        }

        // Let the request enter the pending/active queue, then verify cancellation resumes its
        // continuation rather than waiting for WebKit's normal completion or watchdog timeout.
        await Task.yield()
        task.cancel()

        let result = await task.value
        #expect(result == nil)
    }
}
