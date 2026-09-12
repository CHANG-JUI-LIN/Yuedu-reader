import Foundation
import Testing
@testable import yuedu_app

// MARK: - LoginFormLayoutTests
// 書源/TTS 登入表單的版面模型測試：
//   1. `style` 寬鬆解析（新 cols、舊 flex 欄位、壞值不丟欄位）
//   2. 12 欄正規化（LoginField.gridSpec）
//   3. 先到先占格打包（LoginGridPacker）
//   4. viewName 字面值 vs 動態 JS 表達式判定

@Suite("LoginFormLayout")
struct LoginFormLayoutTests {

    // MARK: - Style parsing

    @Test("loginUi style 解析新舊兩代欄位")
    func parseStyleFields() throws {
        let json = """
        [
            {"name":"登入","type":"button","style":{"cols":2}},
            {"name":"獲取驗證碼","type":"button","style":{"layout_flexGrow":1}},
            {"name":"選項","type":"select","chars":["a","b"],"style":{"layout_flexBasisPercent":0.33,"layout_wrapBefore":true,"layout_justifySelf":"flex_end"}},
            {"name":"多行","type":"text","style":{"rows":2}}
        ]
        """
        let fields = LoginManager.shared.parseLoginUi(json)

        #expect(fields.count == 4)
        #expect(fields[0].style?.cols == 2)
        #expect(fields[1].style?.flexGrow == 1)
        #expect(fields[2].style?.basisPercent == 0.33)
        #expect(fields[2].style?.wrapBefore == true)
        #expect(fields[2].style?.justifySelf == "flex_end")
        #expect(fields[3].style?.rows == 2)
    }

    @Test("style 值是數字/字串混用時仍可解析")
    func parseStyleLenientScalars() throws {
        // 真實聚合源的 style 值常是數字或布林（layout_flexBasisPercent: 0.45），
        // 嚴格 [String:String] 會整個解析失敗。
        let json = """
        [
            {"name":"a","type":"button","style":{"cols":"3","layout_flexGrow":"1.5","layout_wrapBefore":"true"}},
            {"name":"b","type":"button","style":{"layout_flexBasisPercent":"0.45"}}
        ]
        """
        let fields = LoginManager.shared.parseLoginUi(json)

        #expect(fields[0].style?.cols == 3)
        #expect(fields[0].style?.flexGrow == 1.5)
        #expect(fields[0].style?.wrapBefore == true)
        #expect(fields[1].style?.basisPercent == 0.45)
    }

    @Test("壞掉的 style 只丟 style，不丟欄位")
    func malformedStyleKeepsField() throws {
        let json = """
        [
            {"name":"a","type":"button","style":"cols: 2"},
            {"name":"b","type":"button","style":{}},
            {"name":"c","type":"button","style":null},
            {"name":"d","type":"button"}
        ]
        """
        let fields = LoginManager.shared.parseLoginUi(json)

        #expect(fields.map(\.name) == ["a", "b", "c", "d"])
        #expect(fields.allSatisfy { $0.style == nil })
    }

    // MARK: - Grid spec

    @Test("沒有 style 時：輸入框整行、按鈕/開關/下拉半行")
    func defaultSpans() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"t","type":"text"},
            {"name":"p","type":"password"},
            {"name":"b","type":"button"},
            {"name":"tg","type":"toggle","chars":["🔳","✅"]},
            {"name":"s","type":"select","chars":["a","b"]}
        ]
        """)

        #expect(fields[0].gridSpec.colSpan == 12)
        #expect(fields[1].gridSpec.colSpan == 12)
        #expect(fields[2].gridSpec.colSpan == 6)
        #expect(fields[3].gridSpec.colSpan == 6)
        #expect(fields[4].gridSpec.colSpan == 6)
        #expect(fields.allSatisfy { $0.gridSpec.rowSpan == 1 })
    }

    @Test("cols 1...4 映射到 12 欄的整行/半/三分之一/四分之一")
    func colsMapping() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"a","type":"button","style":{"cols":1}},
            {"name":"b","type":"button","style":{"cols":2}},
            {"name":"c","type":"button","style":{"cols":3}},
            {"name":"d","type":"button","style":{"cols":4}}
        ]
        """)

        #expect(fields.map(\.gridSpec.colSpan) == [12, 6, 4, 3])
    }

    @Test("舊 flex 欄位近似：basisPercent 換算欄數、flexGrow 半行、wrapBefore 換行")
    func legacyFlexMapping() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"a","type":"button","style":{"layout_flexBasisPercent":0.5}},
            {"name":"b","type":"button","style":{"layout_flexBasisPercent":0.33}},
            {"name":"c","type":"button","style":{"layout_flexGrow":1}},
            {"name":"d","type":"button","style":{"layout_flexBasisPercent":-1}},
            {"name":"e","type":"button","style":{"layout_wrapBefore":true}}
        ]
        """)

        #expect(fields[0].gridSpec.colSpan == 6)
        #expect(fields[1].gridSpec.colSpan == 4)
        #expect(fields[2].gridSpec.colSpan == 6)
        // -1 is Legado's "unset" sentinel, it must not become a tiny span.
        #expect(fields[3].gridSpec.colSpan == 6)
        #expect(fields[4].gridSpec.wrapBefore)
    }

    @Test("basisPercent >= 1 與 rows 縱跨都反映到 spec")
    func fullRowAndRowSpan() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"a","type":"button","style":{"layout_flexBasisPercent":1}},
            {"name":"b","type":"text","style":{"rows":2}}
        ]
        """)

        #expect(fields[0].gridSpec.colSpan == 12)
        #expect(fields[0].gridSpec.wrapBefore)
        #expect(fields[1].gridSpec.rowSpan == 2)
    }

    @Test("cols 超出 1...4 會被夾到合法範圍")
    func colsClamped() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"a","type":"button","style":{"cols":0}},
            {"name":"b","type":"button","style":{"cols":9}}
        ]
        """)

        #expect(fields[0].gridSpec.colSpan == 12)
        #expect(fields[1].gridSpec.colSpan == 3)
    }

    @Test("輔助使用字級以單欄保留書源順序，不改寫原始樣式")
    func accessibilityUsesFullWidthWithoutMutatingStyle() {
        let fields = LoginManager.shared.parseLoginUi("""
        [{"name":"a","type":"button","style":{"cols":3,"rows":2}},
         {"name":"b","type":"button","style":{"cols":2}}]
        """)
        let accessible = fields.map { $0.gridSpec(accessibilityLayout: true) }
        #expect(accessible.allSatisfy { $0.colSpan == 12 && $0.rowSpan == 1 })
        #expect(LoginGridPacker.pack(specs: accessible).map(\.row) == [0, 1])
        #expect(fields.map { $0.gridSpec(accessibilityLayout: false).colSpan } == [4, 6])
        #expect(fields[0].style?.rows == 2)
    }

    // MARK: - Packing

    private func pack(_ spans: [(Int, Int, Bool)]) -> [LoginGridCell] {
        LoginGridPacker.pack(
            specs: spans.map {
                LoginGridSpec(colSpan: $0.0, rowSpan: $0.1, wrapBefore: $0.2)
            }
        )
    }

    @Test("四個半行按鈕排成兩列")
    func packHalfWidthButtons() {
        let cells = pack(Array(repeating: (6, 1, false), count: 4))

        #expect(cells == [
            LoginGridCell(row: 0, column: 0, rowSpan: 1, colSpan: 6),
            LoginGridCell(row: 0, column: 6, rowSpan: 1, colSpan: 6),
            LoginGridCell(row: 1, column: 0, rowSpan: 1, colSpan: 6),
            LoginGridCell(row: 1, column: 6, rowSpan: 1, colSpan: 6),
        ])
    }

    @Test("三個三分之一行共用一列，整行輸入框自成一列")
    func packThirdsAndFullRow() {
        let cells = pack([
            (12, 1, false),  // text
            (4, 1, false),   // three thirds
            (4, 1, false),
            (4, 1, false),
            (12, 1, false),  // next text
        ])

        #expect(cells[0].row == 0)
        #expect(cells[1].row == 1 && cells[1].column == 0)
        #expect(cells[2].row == 1 && cells[2].column == 4)
        #expect(cells[3].row == 1 && cells[3].column == 8)
        #expect(cells[4].row == 2)
    }

    @Test("wrapBefore 強制換行，即使上一列還有空位")
    func packWrapBefore() {
        let cells = pack([
            (3, 1, false),   // quarter
            (3, 1, true),    // quarter but forced to a new row
        ])

        #expect(cells[0] == LoginGridCell(row: 0, column: 0, rowSpan: 1, colSpan: 3))
        #expect(cells[1] == LoginGridCell(row: 1, column: 0, rowSpan: 1, colSpan: 3))
    }

    @Test("縱跨項佔住的水位會把後續項擠到下方")
    func packRowSpanHighWater() {
        let cells = pack([
            (12, 2, false),  // full-width, two rows tall
            (6, 1, false),
        ])

        #expect(cells[0] == LoginGridCell(row: 0, column: 0, rowSpan: 2, colSpan: 12))
        #expect(cells[1] == LoginGridCell(row: 2, column: 0, rowSpan: 1, colSpan: 6))
    }

    // MARK: - viewName

    @Test("viewName：短引號字面值 vs 動態 JS 表達式")
    func viewNameLiteralVersusDynamic() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"a","type":"toggle","viewName":"' 段评开关'"},
            {"name":"b","type":"text","viewName":"'1. API Key'"},
            {"name":"c","type":"button","viewName":"getTitle()"},
            {"name":"d","type":"button","viewName":"apiKey"},
            {"name":"e","type":"button","viewName":"''"},
            {"name":"f","type":"button"}
        ]
        """)

        #expect(fields[0].literalViewName == " 段评开关")
        #expect(!fields[0].hasDynamicViewName)
        #expect(fields[1].literalViewName == "1. API Key")
        #expect(fields[2].literalViewName == nil)
        #expect(fields[2].hasDynamicViewName)
        // A short bare word is still a JS expression (legado only strips quotes).
        #expect(fields[3].hasDynamicViewName)
        // Too short to be a quoted literal.
        #expect(fields[4].literalViewName == nil)
        #expect(fields[4].hasDynamicViewName)
        #expect(fields[5].literalViewName == nil)
        #expect(!fields[5].hasDynamicViewName)
    }

    @Test("literalViewNames 只收集字面值標籤")
    func literalLabelCollection() throws {
        let fields = LoginManager.shared.parseLoginUi("""
        [
            {"name":"a","type":"button","viewName":"'登入'"},
            {"name":"b","type":"button","viewName":"state.label()"}
        ]
        """)

        #expect(fields.literalViewNames == ["a": "登入"])
        #expect(fields.hasDynamicViewNames)
    }
}
