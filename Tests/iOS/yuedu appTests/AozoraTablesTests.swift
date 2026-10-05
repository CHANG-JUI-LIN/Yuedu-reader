import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora tables")
struct AozoraTablesTests {
    private let tables = AozoraTables.shared

    @Test("the bundle carries all of JIS X 0213 and every accent resolves")
    func completeTables() {
        #expect(tables.characters.count == 11_233)
        #expect(tables.accents.count == 72)
    }

    @Test("JIS codes resolve to their exact scalars", arguments: [
        ("1-84-77", [0x6318]),            // 挘
        ("1-2-24", [0x30FF]),             // ヿ
        ("2-1-1", [0x20089]),             // outside the BMP
        ("1-4-87", [0x304B, 0x309A]),     // か゚, a combining sequence
        ("1-2-54", [0xFF5F]),             // full-width ｟, suited to vertical text
        ("1-2-55", [0xFF60]),             // full-width ｠
    ])
    func jisCode(code: String, scalars: [UInt32]) throws {
        let parts = code.split(separator: "-").compactMap { Int($0) }
        let value = try #require(tables.character(plane: parts[0], row: parts[1], cell: parts[2]))
        #expect(value.unicodeScalars.map(\.value) == scalars)
    }

    @Test("one accent per mark type", arguments: [
        ("!@", 0x00A1),   // ¡
        ("a`", 0x00E0),   // à
        ("e'", 0x00E9),   // é
        ("o^", 0x00F4),   // ô
        ("n~", 0x00F1),   // ñ
        ("u:", 0x00FC),   // ü
        ("a&", 0x00E5),   // å
        ("s&", 0x00DF),   // ß
        ("a_", 0x0101),   // ā
        ("c,", 0x00E7),   // ç
        ("o/", 0x00F8),   // ø
        ("ae&", 0x00E6),  // æ, a three-character ligature
        ("OE&", 0x0152),  // Œ
    ])
    func accent(sequence: String, scalar: UInt32) throws {
        let value = try #require(tables.accent(sequence))
        #expect(value.unicodeScalars.map(\.value) == [scalar])
    }

    @Test("unknown codes and sequences resolve to nothing")
    func unknownCodes() {
        #expect(tables.character(plane: 1, row: 99, cell: 1) == nil)
        #expect(tables.accent("x'") == nil)
    }
}
