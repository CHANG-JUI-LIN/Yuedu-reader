# BW-EPUB3-006 — Fixed-layout direct image spine rendering

- Sample/checkpoint: haruko-jpeg / first JPEG spine item
- Sample checksum: 5e9fc05e366d99607acc4b312c76b6e8928578ced0121fd5d8befa85e219703e
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: 98c341183e33344a7253a58b2c709f3eef03eaed
- Fixture: `EPUBTestFixtures+FixedImageSpine.swift` / `fixedImageSpine()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/EPUBFixedImageSpineTests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, fixed-layout page, 390 pt snapshot width, first spine item
- Expected behavior: A direct JPEG spine item is wrapped as an image document, decoded, and displayed without exposing binary data as text.
- Observed behavior: Before, the fixed-layout WKWebView snapshot was blank; after, the authored first manga page fills the fixed-layout snapshot. The focused test also requires one complete natural-size image, no body text, and a data-image source.
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed).
