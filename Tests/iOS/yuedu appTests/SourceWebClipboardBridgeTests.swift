import Testing
import UIKit
@testable import yuedu_app

@Suite("Source browser clipboard bridge", .serialized)
@MainActor
struct SourceWebClipboardBridgeTests {
    @Test("browser bootstrap supports Clipboard API, legacy copy, and java.copyText")
    func bootstrapCoversPageCopyContracts() {
        let script = SourceWebClipboardBridge.bootstrapScript
        #expect(script.contains("navigator.clipboard"))
        #expect(script.contains("writeText"))
        #expect(script.contains("document.execCommand"))
        #expect(script.contains("window.java.copyText"))
        #expect(script.contains(SourceWebClipboardBridge.messageName))
    }

    @Test("java.copyText writes the system pasteboard")
    func javaCopyTextWritesSystemPasteboard() async {
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }
        UIPasteboard.general.string = nil
        var source = BookSource(
            bookSourceUrl: "clipboard-fixture-\(UUID().uuidString)",
            bookSourceName: "clipboard fixture"
        )
        source.jsLib = "function copyFixture(value) { java.copyText(value); }"

        _ = ModernParserBridge(source: source).evaluateSourceScript("copyFixture('copied from source')")
        for _ in 0..<20 where UIPasteboard.general.string != "copied from source" {
            await Task.yield()
        }

        #expect(UIPasteboard.general.string == "copied from source")
    }
}
