# BW-EPUB3-004 — MathML attachment metrics and complex-table safety

- Sample/checkpoint: linear-algebra / fcla-xml-2.30li16 inline equations plus fcla-xml-2.30li18 formula 479
- Sample checksum: 87e523d8e16c2d1f4b211b47c0495841687a3573c828d3ef36b1f77f91b2abd4
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: 7736203094d22816f331f53708afec6aa819aeea
- Fixture: `EPUBTestFixtures+MathML.swift` / `mathMLTypography()` and `mathMLUnarySignAfterTableCell()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/MathMLBaselineTests'`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, 390×844 pt viewport, 18 pt text, 1.4 line-height, 28 pt horizontal and 40 pt vertical insets
- Expected behavior: Inline MathML shares the prose baseline, final metrics reserve exactly the raster height, over-wide formulas fit once at device scale, and complex tables render or preserve fallback without crashing.
- Observed behavior: Before, formula rasters carried label padding and post-raster scaling; the official formula-479 chapter also aborted in iosMath on a relation/binary spacing pair. After, final ascent/descent drive both raster and attachment geometry, source table cells remain isolated, and all 499 formulas in the official chapter build without a crash. The paired image uses the identical fcla-xml-2.30li16 checkpoint so the metric change can be compared directly.
- Official content visible: yes
- License attribution: GNU FDL 1.2 (official catalog sample-specific license).
