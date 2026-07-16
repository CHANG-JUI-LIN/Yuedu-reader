# BW-EPUB3-007 — Preserve unsupported media fallback

- Sample/checkpoint: cc-shared-culture / `xhtml/p60.xhtml` controls-less background soundtrack
- Sample checksum: 7bec3acf5ca153fd8a3b8bba50549c5cde3cb617ddd74c1d3b26fbc5eb9eebdf
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: df45d95cc9f158f7d5daef0338ee129b23cf79aa
- Fixture: `EPUBTestFixtures+MediaFallback.swift` / `controlslessAudioFallback()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/EPUBMediaFallbackTests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, 390 x 844 pt, 2x capture
- Expected behavior: When a controls-less background audio element cannot surface a native player, the authored static fallback and surrounding transcript remain readable without creating a false media attachment.
- Observed behavior: Before, the page silently skipped from the title to the transcript body; after, the author's red unsupported-audio message appears before the same surviving transcript body. The focused test also verifies source order and the absence of a media attachment.
- Official content visible: yes
- License attribution: CC BY-NC-SA 3.0 Unported (official catalog sample-specific license).
