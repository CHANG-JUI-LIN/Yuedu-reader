import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Dialogue speaker detection")
struct ReaderDialogueSpeakerTests {
    @Test("reads the speaker from the attribution before the quote")
    func detectsLeadIn() {
        #expect(
            ReaderDialogueSpeakerDetector.speaker(before: "張若塵道：", after: "") == "張若塵"
        )
        #expect(
            ReaderDialogueSpeakerDetector.speaker(before: "齊源老道說道：", after: "")
                == "齊源老道"
        )
    }

    @Test("reads the speaker from the attribution after the quote")
    func detectsTrailer() {
        #expect(
            ReaderDialogueSpeakerDetector.speaker(before: "", after: "張若塵道。") == "張若塵"
        )
        #expect(
            ReaderDialogueSpeakerDetector.speaker(before: "", after: "，池瑤冷冷地說。")
                == "池瑤"
        )
    }

    /// Narration that merely mentions someone is not an attribution.
    @Test("says nothing when the narration does not attribute the line")
    func refusesNonAttribution() {
        #expect(
            ReaderDialogueSpeakerDetector.speaker(
                before: "",
                after: "屋裡沒有人回答。"
            ) == nil
        )
        #expect(ReaderDialogueSpeakerDetector.speaker(before: "", after: "") == nil)
    }

    /// One speaker keeps one side for the whole chapter — the reason the name is
    /// read at all. Alternation only fills in for unattributed lines.
    @Test("pins a speaker to one side across the chapter")
    func pinsSpeakerToSide() {
        let attr = NSMutableAttributedString(
            string: [
                "張若塵道：「甲。」",
                "池瑤道：「乙。」",
                "張若塵又道：「丙。」",
            ].joined(separator: "\n"),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        ReaderDialogueBubbleMarker.apply(
            style: ReaderDialogueBubbleStyle(isEnabled: true),
            columnWidth: 340,
            bodyFontSize: 18,
            to: attr
        )

        var sides: [String: ReaderDialogueBubbleSide] = [:]
        attr.enumerateAttribute(
            ReaderDialogueBubbleMarker.attributeKey,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, range, _ in
            guard let mark = value as? ReaderDialogueBubbleMark else { return }
            sides[(attr.string as NSString).substring(with: range)] = mark.side
        }

        #expect(sides.count == 3)
        // 甲 and 丙 are the same speaker, so they share a side; 乙 is the other.
        let first = try? #require(sides.first { $0.key.contains("甲") }?.value)
        let third = try? #require(sides.first { $0.key.contains("丙") }?.value)
        let second = try? #require(sides.first { $0.key.contains("乙") }?.value)
        #expect(first == third)
        #expect(first != second)
    }
}

@Suite("Dialogue bubble variants")
struct ReaderDialogueBubbleVariantTests {
    /// The hash has to match the script's FNV-1a exactly, or an imported style
    /// picks different colours for the same line than the file it came from.
    @Test("hashes text the way the source scripts do")
    func matchesScriptHash() {
        // FNV-1a over "甲|0", computed from the script's own algorithm.
        #expect(
            ReaderDialogueBubbleVariantResolver.hash(text: "甲", index: 0)
                == expectedHash("甲|0")
        )
        #expect(
            ReaderDialogueBubbleVariantResolver.hash(text: "hello", index: 3)
                == expectedHash("hello|3")
        )
    }

    @Test("gives the same line the same palette every time")
    func isStablePerText() {
        let variants = ReaderDialogueBubbleVariants(
            selection: .text,
            items: [
                ReaderDialogueBubbleVariantItem(fillHex: 0x111111),
                ReaderDialogueBubbleVariantItem(fillHex: 0x222222),
                ReaderDialogueBubbleVariantItem(fillHex: 0x333333),
            ]
        )
        let first = ReaderDialogueBubbleVariantResolver.variant(
            variants,
            text: "今天天氣真好",
            index: 0
        )
        let again = ReaderDialogueBubbleVariantResolver.variant(
            variants,
            text: "今天天氣真好",
            index: 9
        )

        #expect(first?.fillHex == again?.fillHex)
    }

    @Test("cycles straight through the palette when asked")
    func cyclesByIndex() {
        let variants = ReaderDialogueBubbleVariants(
            selection: .cycle,
            items: [
                ReaderDialogueBubbleVariantItem(fillHex: 0x111111),
                ReaderDialogueBubbleVariantItem(fillHex: 0x222222),
            ]
        )

        #expect(
            ReaderDialogueBubbleVariantResolver.variant(variants, text: "a", index: 0)?
                .fillHex == 0x111111
        )
        #expect(
            ReaderDialogueBubbleVariantResolver.variant(variants, text: "a", index: 1)?
                .fillHex == 0x222222
        )
        #expect(
            ReaderDialogueBubbleVariantResolver.variant(variants, text: "a", index: 2)?
                .fillHex == 0x111111
        )
    }

    @Test("drifts a text-index sticker only to a neighbouring anchor")
    func keepsStickerOnItsEdge() {
        let decoration = ReaderDialogueBubbleDecoration(
            anchor: .topRight,
            variation: .textIndex
        )
        for index in 0..<24 {
            let resolved = ReaderDialogueBubbleVariantResolver.decoration(
                decoration,
                kindOverride: nil,
                text: "第\(index)句",
                index: index
            )
            #expect(
                ReaderDialogueBubbleAnchor.topRight.neighbours.contains(
                    resolved?.anchor ?? .left
                )
            )
        }
    }

    private func expectedHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in value.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
