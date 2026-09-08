import Testing
@testable import yuedu_app

@Suite(.serialized)
struct LexborCSSFrontendSyntheticTests {
    @Test func snapshotsDOMAttributesTextAndCascade() throws {
        let html = "<html><body><p id='p' class='lead' style='color: red'>Hello <em>world</em></p></body></html>"
        let input = CSSFrontendInput(
            html: html,
            stylesheets: [AuthorStylesheet(
                source: .linked(href: "memory.css"), text: "p.lead { color: blue; width: 15%; }",
                sourceOrder: 0, currentCompatibilityOrder: nil,
                currentCompatibilityOnly: false, media: nil, isAlternate: false
            )]
        )
        let frontend = try LexborCSSFrontend(input: input)
        let snapshot = try frontend.snapshot(input: input)
        let paragraphEntry = try #require(snapshot.elements.first { $0.value.tagName == "p" })
        let paragraph = paragraphEntry.value
        let paragraphID = paragraphEntry.key
        #expect(paragraph.attribute("id") == "p")
        #expect(paragraph.classTokens == ["lead"])
        #expect(snapshot.textOrder.map(\.text).joined() == "Hello world")
        #expect(snapshot.winningDeclarations.contains { $0.property == "color" })
        #expect(snapshot.winningDeclarations.contains { $0.property == "width" })
        #expect(snapshot.winningDeclarations.contains { $0.origin == 1 })
        #expect(snapshot.winningDeclarations.filter { $0.property == "color" || $0.property == "width" }
            .allSatisfy { $0.nodeID == paragraphID })
    }
}
