import Testing
import UIKit
@testable import yuedu_app

struct BrowserLayoutFeatureTests {
    @Test func featureIsOffByDefault() {
        #expect(BrowserLayoutFeature.isEnabled == false)
    }
}
