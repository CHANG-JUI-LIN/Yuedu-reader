import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader Touch Action Routing")
struct ReaderTouchActionRoutingTests {
    @Test("every touch action maps to one explicit reader command")
    func mapsAction() {
        let mappings: [(TouchAction, ReaderTouchCommand)] = [
            (.none, .none),
            (.toggleMenu, .toggleMenu),
            (.prevPage, .previousPage),
            (.nextPage, .nextPage),
            (.previousChapter, .previousChapter),
            (.nextChapter, .nextChapter),
            (.toggleBookmark, .toggleBookmark),
            (.tableOfContents, .tableOfContents),
            (.changeSource, .changeSource),
        ]

        for (action, command) in mappings {
            #expect(action.readerCommand == command)
        }
    }

    @Test("a zone layout saved before 換源 existed decodes unchanged")
    func legacyConfigDecodes() throws {
        let json = #"{"zones":["上一頁","上一頁","下一頁","目錄","選單","下一頁","添加/移除書籤","下一章","上一章"]}"#
        let config = try JSONDecoder().decode(TouchZoneConfig.self, from: Data(json.utf8))
        #expect(config.zones == [
            .prevPage, .prevPage, .nextPage,
            .tableOfContents, .toggleMenu, .nextPage,
            .toggleBookmark, .nextChapter, .previousChapter,
        ])
        // And a layout with 換源 round-trips.
        var withSource = config
        withSource.zones[0] = .changeSource
        let decoded = try JSONDecoder().decode(TouchZoneConfig.self, from: JSONEncoder().encode(withSource))
        #expect(decoded == withSource)
    }

    @Test("換源 is offered only where the reader has it")
    func editorOffersChangeSource() {
        #expect(TouchAction.editorCases(offersChangeSource: true).contains(.changeSource))
        #expect(!TouchAction.editorCases(offersChangeSource: false).contains(.changeSource))
    }

    @Test("only page and chapter turns put the reading menu away")
    func turnsPage() {
        let turns: Set<TouchAction> = [.prevPage, .nextPage, .previousChapter, .nextChapter]
        for action in TouchAction.allCases {
            #expect(action.readerCommand.turnsPage == turns.contains(action))
        }
    }
}
