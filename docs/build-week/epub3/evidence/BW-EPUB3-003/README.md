# BW-EPUB3-003 — Mixed-layout spine dispatch

- Sample/checkpoint: the-voyage-of-life / move from reflowable Childhood to the fixed-layout painting
- Sample checksum: e38ed606ff604e638f737efaf66e0fd0b2997c3eab7432bcba9a00a81a925cf3
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: 306fbc0b50b3ab04bcb02b9167fd8f12410343c8
- Fixture: `EPUBTestFixtures+MixedLayout.swift` / `mixedLayout()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/EPUBMixedLayoutRoutingTests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, default reader settings
- Expected behavior: Each spine item uses its effective item-level rendition layout while retaining one continuous page map.
- Observed behavior: Before, the fixed painting was dispatched through the reflowable path and the next page was blank; after, the painting is loaded by the fixed-layout controller and remains addressable between reflowable items.
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed).
