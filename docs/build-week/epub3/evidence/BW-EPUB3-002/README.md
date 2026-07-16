# BW-EPUB3-002 — Non-ASCII EPUB resource IRI resolution

- Sample/checkpoint: kusamakura / open the percent-encoded Japanese spine resource and render vertical body text
- Sample checksum: 6d4d4ed5eda3f612e3263c54fa0f74ccfa87260f43e81bb58ea658636e52eeb7
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: 691be18be213dd3b7455e2e2a541a6a2afa5fc15
- Fixture: `EPUBTestFixtures+NonASCIIIRI.swift` / `nonASCIIResourceIRI()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/EPUBResourceIRITests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, default reader settings
- Expected behavior: Encoded and decoded archive href variants resolve to the same authored Japanese resource.
- Observed behavior: Before, the reader remained at a loading state whose title exposed the percent-encoded href; after, the Unicode-named XHTML resource opens and its vertical Japanese body is retained.
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed).
