import Testing
@testable import yuedu_app

struct ReaderOverlayComponentEditingTests {
    @Test("component picker catalog contains every supported kind exactly once")
    func pickerCatalogCoverage() {
        let catalogKinds = ReaderOverlayComponentPickerSection.all
            .flatMap(\.kinds)
            .map(\.rawValue)
            .sorted()
        let supportedKinds = ReaderOverlayComponentKind.allCases
            .map(\.rawValue)
            .sorted()

        #expect(catalogKinds == supportedKinds)
        #expect(Set(catalogKinds).count == catalogKinds.count)
    }

    @Test("new component placement starts at center and avoids occupied candidates")
    func collisionAwarePlacement() {
        let center = ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        let top = ReaderOverlayNormalizedPoint(x: 0.5, y: 0.36)

        #expect(ReaderOverlayDefaultPlacement.position(existing: []) == center)
        #expect(ReaderOverlayDefaultPlacement.position(existing: [center]) == top)
        #expect(
            ReaderOverlayDefaultPlacement.position(existing: [center, top])
                == ReaderOverlayNormalizedPoint(x: 0.5, y: 0.64)
        )
    }

    @Test("format editor exposes only formats meaningful to each component")
    func compatibleFormats() {
        #expect(
            ReaderOverlayComponentEditing.compatibleFormats(for: .chapterPage)
                == [.automatic, .compact, .fraction]
        )
        #expect(
            ReaderOverlayComponentEditing.compatibleFormats(for: .currentTime)
                == [.automatic, .hourMinute24, .hourMinute12]
        )
        #expect(
            ReaderOverlayComponentEditing.compatibleFormats(for: .currentDate)
                == [.automatic, .compact, .detailed]
        )
        #expect(
            ReaderOverlayComponentEditing.compatibleFormats(for: .readingDuration)
                == [.automatic, .compact, .detailed]
        )
        #expect(ReaderOverlayComponentEditing.compatibleFormats(for: .battery).isEmpty)
        #expect(ReaderOverlayComponentEditing.compatibleFormats(for: .progressBar).isEmpty)
    }

    @Test("custom text normalization caps persisted content")
    func customTextLengthCap() {
        let source = String(repeating: "字", count: 160)
        let configuration = ReaderOverlayComponentConfiguration(customText: source).normalized

        #expect(
            configuration.customText.count
                == ReaderOverlayComponentConfiguration.maximumCustomTextLength
        )
    }

    @Test("component edit cancellation restores the original value")
    func draftCancellationRestoresOriginal() {
        let original = ReaderOverlayComponent.make(
            kind: .bookTitle,
            position: ReaderOverlayNormalizedPoint(x: 0.2, y: 0.3)
        )
        var draft = ReaderOverlayComponentDraft(original)
        draft.value.position = ReaderOverlayNormalizedPoint(x: 0.8, y: 0.9)

        #expect(draft.cancelled() == original)
    }

    @Test("component edit confirmation returns a normalized draft")
    func draftConfirmationNormalizesChanges() {
        let original = ReaderOverlayComponent.make(
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
        )
        var draft = ReaderOverlayComponentDraft(original)
        draft.value.position = ReaderOverlayNormalizedPoint(x: 2, y: -1)
        draft.value.style.fontSize = 200

        let committed = draft.committed()

        #expect(committed.position == ReaderOverlayNormalizedPoint(x: 1, y: 0))
        #expect(committed.style.fontSize == 72)
    }
}
