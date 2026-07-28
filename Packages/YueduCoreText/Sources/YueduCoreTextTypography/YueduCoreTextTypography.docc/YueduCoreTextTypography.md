# ``YueduCoreTextTypography``

Native long-form reader typography built on Core Text.

## Overview

`YueduCoreTextTypography` provides the dependency-free typography primitives
used by Yuedu Reader. Its public API preserves UTF-16 offsets so applications
can keep stable reading locations while applying CJK punctuation and vertical
layout normalization.

The module performs no I/O, networking, persistence, analytics, or telemetry.
It has no third-party runtime dependencies. Keep Core Text framesetters and
frames confined to the layout operation or queue that creates them.

## Topics

### CJK Typography

- ``CJKTypographyProcessor``
- ``VerticalGlyphClassifier``
- ``VerticalGlyphKind``
- ``VerticalLayoutConfig``

### Core Text Construction

- ``CoreTextFramesetterFactory``
- ``ReaderHyphenation``

## Compatibility

The package follows semantic versioning. During 0.x development, minor releases
may refine public API. UTF-16 length preservation remains a compatibility
contract for text normalization APIs.
