import Foundation
import Testing
@testable import yuedu_app

/// 新增來源配置 (Phase 5 plan, decision 31; 5h-4): the one flow behind 來源配置管理's 「+」 and
/// 資源庫's •••. A scratch library, so the simulator's own sources are never touched.
@MainActor
@Suite(.serialized)
struct BookSourceAddFlowTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BookSourceAddFlowTests-\(UUID().uuidString)", isDirectory: true)

    private let oneSource = #"[{"bookSourceName":"甲","bookSourceUrl":"https://a.test"}]"#

    /// Runs `body` with the source disclaimer set as given, then puts the reader's value back.
    private func withDisclaimer(accepted: Bool, _ body: () throws -> Void) rethrows {
        let settings = GlobalSettings.shared
        let saved = settings.sourceDisclaimerAccepted
        settings.sourceDisclaimerAccepted = accepted
        defer { settings.sourceDisclaimerAccepted = saved }
        try body()
    }

    @Test("a route waits for the disclaimer, then opens")
    func disclaimerFirst() {
        withDisclaimer(accepted: false) {
            let flow = BookSourceAddFlow(store: BookSourceStore(directory: directory))
            flow.begin(.network)
            #expect(flow.showsDisclaimer)
            #expect(!flow.showsNetworkImport)
            flow.acceptDisclaimer()
            flow.afterDisclaimerDismissal()
            #expect(flow.showsNetworkImport)
        }
    }

    @Test("each route opens its sheet")
    func routes() {
        withDisclaimer(accepted: true) {
            let flow = BookSourceAddFlow(store: BookSourceStore(directory: directory))
            flow.begin(.add)
            flow.begin(.local)
            flow.begin(.network)
            #expect(flow.showsEditor && flow.showsImport && flow.showsNetworkImport)
            #expect(!flow.showsDisclaimer)
        }
    }

    @Test("iOS 17's chooser opens the route only after it dismisses")
    func chooserSequenced() {
        withDisclaimer(accepted: true) {
            let flow = BookSourceAddFlow(store: BookSourceStore(directory: directory))
            flow.openChooser()
            flow.choose(.local)
            #expect(!flow.showsImport)
            flow.afterChooserDismissal()
            #expect(flow.showsImport)
        }
    }

    @Test("text that is not a source is an error, and nothing is reviewed")
    func badText() {
        let flow = BookSourceAddFlow(store: BookSourceStore(directory: directory))
        flow.importText("not a source")
        #expect(flow.message?.isError == true)
        #expect(flow.importCoordinator.pending == nil)
    }

    @Test("the review waits for the import sheet to dismiss, and writes nothing")
    func reviewAfterTheSheet() {
        let store = BookSourceStore(directory: directory)
        let flow = BookSourceAddFlow(store: store)
        flow.showsImport = true
        flow.importJSON = oneSource
        flow.importText(flow.importJSON)
        #expect(!flow.showsImport)
        #expect(flow.importJSON.isEmpty)
        #expect(flow.importCoordinator.pending == nil)
        flow.afterImportSheetDismissal()
        #expect(flow.importCoordinator.pending != nil)
        #expect(store.sources.isEmpty)
    }
}
