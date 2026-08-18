import Testing
import Foundation
@testable import yuedu_app

/// `java.androidId()` is asked for two incompatible reasons. Most sources use it
/// as a platform probe — 书山聚合's `deviceType()` reads any non-empty answer as
/// proof of Android — while 知秋's family uses it as a real device key. Answering
/// everyone made the probes classify this device as Android, which sent
/// `X-Device-Type: android` and broke chapter loading.
@Suite("Android identity opt-in")
struct AndroidIdentityOptInTests {

    private func bridge(optedIn: Bool) -> LegadoJSBridge {
        let bridge = LegadoJSBridge()
        bridge.presentsAndroidIdentityProvider = { optedIn }
        return bridge
    }

    @Test("a source that did not opt in gets no Android id")
    func defaultIsEmpty() {
        #expect(bridge(optedIn: false).androidId().isEmpty)
    }

    /// Empty rather than a thrown error: 知秋's `requestApiUrl` calls this bare,
    /// so throwing would take the whole request down instead of degrading.
    @Test("an opted-in source gets a 16-character lowercase hex id")
    func optedInShape() {
        let id = bridge(optedIn: true).androidId()
        #expect(id.count == 16)
        #expect(id == id.lowercased())
        #expect(id.allSatisfy { $0.isHexDigit })
    }

    /// The exact probe 书山聚合 runs. With no opt-in it must fall through to
    /// `deviceID()` and conclude iOS.
    @Test("the platform probe concludes iOS when the source did not opt in")
    func probeSeesIOS() {
        let b = bridge(optedIn: false)
        let androidAnswer = b.androidId()
        let looksAndroid = !androidAnswer.isEmpty
        #expect(looksAndroid == false)
        #expect(b.deviceID().isEmpty == false, "the probe's second branch needs a device id to return iOS")
    }

    @Test("the probe concludes Android once the source opts in")
    func probeSeesAndroidWhenOptedIn() {
        #expect(bridge(optedIn: true).androidId().isEmpty == false)
    }

    /// Legado source JSON never carries this field — it is ours — and upstream
    /// `androidId()` always answers. So an imported source must decode as opted IN,
    /// or every source that uses the value as a real device key silently gets
    /// nothing. See `BookSource.presentsAndroidIdentity` for why the default flipped.
    @Test("a source JSON without the field decodes as opted in")
    func decodesMissingFieldAsOn() throws {
        let json = #"{"bookSourceName":"x","bookSourceUrl":"https://example.com"}"#
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        #expect(source.presentsAndroidIdentity)
    }

    /// The escape hatch still has to survive a round trip: a source the user turned
    /// OFF must not come back on after an export/import cycle.
    @Test("an explicit false survives a decode round trip")
    func decodesExplicitFalse() throws {
        let json = #"{"bookSourceName":"x","bookSourceUrl":"https://example.com","presentsAndroidIdentity":false}"#
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        #expect(source.presentsAndroidIdentity == false)
    }

    @Test("an explicit true survives a decode round trip")
    func decodesExplicitTrue() throws {
        let json = #"{"bookSourceName":"x","bookSourceUrl":"https://example.com","presentsAndroidIdentity":true}"#
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        #expect(source.presentsAndroidIdentity)
    }
}
