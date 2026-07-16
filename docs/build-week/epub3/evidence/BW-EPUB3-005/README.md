# BW-EPUB3-005 — English language-aware typography

- Sample/checkpoint: moby-dick / chapter_001.xhtml, first body paragraph beginning “Call me Ishmael”
- Sample checksum: 81bc079841a38e91a02a7776d04786a2fc311cfd300064e9fc533ce7c54cf7b4
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: ab8806d14bd80e39a359cbfffec84812ad2c3352
- Fixture: `EPUBTestFixtures+EnglishTypography.swift` / `englishTypography()` and `englishTypographyChapters()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/EnglishEPUBTypographyTests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, 390×844 pt viewport, 18 pt text, 1.4 line-height, 28 pt horizontal and 40 pt vertical insets
- Expected behavior: EPUB language and CSS hyphenation reach CoreText, eligible non-final English body lines justify without CJK spacing, and source UTF-16 offsets remain stable.
- Observed behavior: Before, the same Moby-Dick paragraph stayed ragged-right; after, eligible non-final lines reach the right edge while the final line remains natural. Fixture tests cover `none`, `manual`, `auto`, soft-hyphen selection offsets, links, anchors, paged layout, scroll slicing, and chapter boundaries.
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed).
