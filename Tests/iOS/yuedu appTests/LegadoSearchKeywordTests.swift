import Testing
@testable import yuedu_app

@Suite("Legado qualified search keyword")
struct LegadoSearchKeywordTests {
    @Test("extracts title before aggregate source qualifier")
    func extractsSourceQualifier() {
        #expect(LegadoSearchKeyword.matchingTitle(from: "我的@番茄") == "我的")
    }

    @Test("extracts title after media prefix with ASCII colon")
    func extractsMediaPrefix() {
        #expect(LegadoSearchKeyword.matchingTitle(from: "m:十日終焉@番茄") == "十日終焉")
    }

    @Test("extracts title after media prefix with full-width colon")
    func extractsFullWidthMediaPrefix() {
        #expect(LegadoSearchKeyword.matchingTitle(from: "t：三體@喜馬拉雅") == "三體")
    }

    @Test("keeps an ordinary keyword unchanged")
    func keepsOrdinaryKeyword() {
        #expect(LegadoSearchKeyword.matchingTitle(from: "詭秘之主") == "詭秘之主")
    }
}
