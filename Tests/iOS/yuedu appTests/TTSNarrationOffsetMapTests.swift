import Foundation
import Testing
@testable import yuedu_app

/// The map exists so playback highlight can derive a position instead of searching the
/// page for the spoken text — a search picks the wrong `「嗯。」` as soon as a chapter
/// has two of them, which per-speaker segmentation makes routine.
@Suite("TTS narration offset map")
struct TTSNarrationOffsetMapTests {

    private func map(for source: String) -> (TTSNarrationOffsetMap, String) {
        let narration = ReaderView.narratableText(from: source)
        return (TTSNarrationOffsetMap(narration: narration, source: source), narration)
    }

    @Test("prose that needs no cleanup maps one to one")
    func identityForUntouchedProse() {
        let source = "第一章 医院\n\n夜晚时分，他走进了那扇门。"
        let (offsets, narration) = map(for: source)
        #expect(narration == source)
        for index in 0...(narration as NSString).length {
            #expect(offsets.sourceOffset(forNarrationOffset: index) == index)
        }
    }

    @Test("offsets step over a removed attachment marker")
    func skipsRemovedMarkers() {
        let source = "他说\u{FFFC}了一句话"
        let (offsets, narration) = map(for: source)
        #expect(narration == "他说了一句话")
        let ns = source as NSString
        // 了 is at narration 2 but source 3 — the marker is in between.
        #expect(offsets.sourceOffset(forNarrationOffset: 2) == 3)
        #expect(ns.substring(with: NSRange(location: 3, length: 1)) == "了")
    }

    /// Drift accumulates: this is the shape of a chapter dense with review anchors,
    /// and the reason a fixed guess at the offset is not good enough.
    @Test("offsets stay correct as marker drift accumulates")
    func tracksAccumulatedDrift() {
        let source = String(repeating: "字\u{FFFC}", count: 200)
        let (offsets, narration) = map(for: source)
        #expect((narration as NSString).length == 200)
        let ns = source as NSString
        for index in 0..<200 {
            let mapped = offsets.sourceOffset(forNarrationOffset: index)
            #expect(mapped == index * 2)
            #expect(ns.substring(with: NSRange(location: mapped, length: 1)) == "字")
        }
    }

    @Test("a trimmed leading run shifts every offset")
    func accountsForTrimmedPrefix() {
        let source = "\n\n   第一句。"
        let (offsets, narration) = map(for: source)
        #expect(narration == "第一句。")
        #expect(offsets.sourceOffset(forNarrationOffset: 0) == (source as NSString).range(of: "第").location)
    }

    @Test("a collapsed blank-line run maps onto real newlines")
    func mapsCollapsedBlankLines() {
        let source = "第一段\n\u{FFFC}\n\n\u{FFFC}\n第二段"
        let (offsets, narration) = map(for: source)
        #expect(narration == "第一段\n\n第二段")
        let ns = source as NSString
        for index in 0..<(narration as NSString).length {
            let mapped = offsets.sourceOffset(forNarrationOffset: index)
            let narrationChar = (narration as NSString).substring(with: NSRange(location: index, length: 1))
            let sourceChar = ns.substring(with: NSRange(location: mapped, length: 1))
            #expect(narrationChar == sourceChar)
        }
    }

    /// The property that actually matters: whatever the cleanup did, every narration
    /// character lands on a source character it could have come from, and the mapping
    /// never goes backwards.
    @Test("every narration character maps onto a compatible source character")
    func mapsOntoCompatibleCharacters() {
        let source = """
        第一章　医院\u{FFFC}

        \u{FFFC}　「嗯。」他说道。\t\t然后又是一句「嗯。」

        \u{FFFC}\u{FFFC}

        第二段落开始了。
        """
        let (offsets, narration) = map(for: source)
        let narrationNS = narration as NSString
        let sourceNS = source as NSString
        #expect(narrationNS.length > 0)

        var previous = -1
        for index in 0..<narrationNS.length {
            let mapped = offsets.sourceOffset(forNarrationOffset: index)
            #expect(mapped >= previous)
            previous = mapped
            #expect(mapped < sourceNS.length)
            let narrationChar = narrationNS.character(at: index)
            let sourceChar = sourceNS.character(at: mapped)
            let bothBlank = (narrationChar == 0x20 || narrationChar == 0x09)
                && (sourceChar == 0x20 || sourceChar == 0x09)
            #expect(narrationChar == sourceChar || bothBlank)
        }
    }

    /// Two identical lines must map to *different* places — the whole point.
    @Test("repeated lines map to their own occurrences")
    func distinguishesRepeatedLines() {
        let source = "「嗯。」张三道。\u{FFFC}「嗯。」李四道。"
        let (offsets, narration) = map(for: source)
        let narrationNS = narration as NSString
        let first = narrationNS.range(of: "「嗯。」")
        let second = narrationNS.range(
            of: "「嗯。」",
            options: [],
            range: NSRange(location: NSMaxRange(first), length: narrationNS.length - NSMaxRange(first))
        )
        #expect(second.location != NSNotFound)

        let firstSource = offsets.sourceRange(forNarrationRange: first)
        let secondSource = offsets.sourceRange(forNarrationRange: second)
        #expect(firstSource.location != secondSource.location)
        let ns = source as NSString
        #expect(ns.substring(with: firstSource) == "「嗯。」")
        #expect(ns.substring(with: secondSource) == "「嗯。」")
    }

    /// A stale layout must not take playback down with it.
    @Test("out-of-range offsets clamp instead of trapping")
    func clampsOutOfRange() {
        let (offsets, narration) = map(for: "短句。")
        let length = (narration as NSString).length
        #expect(offsets.sourceOffset(forNarrationOffset: -5) == 0)
        #expect(offsets.sourceOffset(forNarrationOffset: length + 99) == offsets.sourceOffset(forNarrationOffset: length))
    }

    /// Resuming mid-chapter hands the engine `narration[startCharOffset...]`, so every
    /// range it reports is short by that much.
    @Test("a map slid past a resume offset still lands on the right chapter position")
    func droppingNarrationPrefixRebasesOffsets() {
        let source = "第一段\u{FFFC}文字。\n\n第二段文字。"
        let narration = ReaderView.narratableText(from: source)
        let full = TTSNarrationOffsetMap(narration: narration, source: source)
        let drop = 3
        let sliced = full.droppingNarrationPrefix(drop)
        for offset in 0...(narration as NSString).length - drop {
            #expect(
                sliced.sourceOffset(forNarrationOffset: offset)
                    == full.sourceOffset(forNarrationOffset: offset + drop)
            )
        }
    }

    @Test("dropping nothing, or more than there is, stays inside the chapter")
    func droppingNarrationPrefixClamps() {
        let source = "第一段文字。"
        let map = TTSNarrationOffsetMap(narration: source, source: source)
        #expect(map.droppingNarrationPrefix(0).sourceOffset(forNarrationOffset: 2) == 2)
        let overrun = map.droppingNarrationPrefix(999)
        #expect(overrun.sourceOffset(forNarrationOffset: 0) == (source as NSString).length)
    }
}
