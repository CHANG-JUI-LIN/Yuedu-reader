# BW-EPUB3-001 — TOC dismissal before navigation

- Sample/checkpoint: accessible-epub3 / select Preface from the long TOC sheet
- Sample checksum: 67f75b8e3cd1abe4bb143d91d5424191d5af3115c9d26ff029a38e19f8d16feb
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: 84e8a34fa88ce656e9216a0cd6b625463548ddd0
- Fixture: `EPUBTestFixtures+LongTOC.swift` / `longTOC()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/ReaderTOCSelectionTimingTests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, default reader settings
- Expected behavior: Selecting a TOC row dismisses the sheet before loading and displaying the destination chapter.
- Observed behavior: Before, Preface selection left the TOC sheet presented; after, the sheet is gone and the Preface body is visible. The same ordering fix covers the horizontal and vertical TOC variants.
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed).
