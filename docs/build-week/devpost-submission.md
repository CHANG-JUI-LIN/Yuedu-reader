# Devpost Submission Copy — Yuedu Reader

## Project

- **Name:** Yuedu Reader
- **Tagline:** Premium native reading, without ecosystem lock-in.
- **Category:** Apps for Your Life
- **Repository:** https://github.com/CHANG-JUI-LIN/Yuedu-reader/tree/codex/openai-build-week
- **Built with:** Swift, SwiftUI, CoreText, Readium, Python, XCTest, Swift Testing, Codex, GPT-5.6

## Inspiration

Digital reading should not force people to choose between polished typography and control over their own library. Yuedu combines a high-quality native iOS reading experience with user-owned books, open catalogs, self-hosted libraries, feeds, and user-chosen content sources.

## What it does

Yuedu imports EPUB, TXT, CBZ, and ZIP content and connects to sources including RSS, OPDS, WebDAV, browser conversion, local-network import, and compatible book-source rules. Its reading surface is rendered natively with CoreText for precise pagination, CJK vertical writing, synchronized TTS, selection, and advanced layout control.

## What we built during OpenAI Build Week

We used the official IDPF EPUB 3 Samples to replace broad compatibility claims with reproducible evidence. The new workflow pins all 42 downloadable samples by checksum, downloads them outside Git, structurally scans each package, and runs 43 designated checks through Yuedu's production reading paths.

The event baseline passed 29 of 43 checks. The final production revision passes all 43 with no failures or skips. The work fixed non-ASCII resource loading, reliable TOC navigation, mixed and fixed-layout routing, direct image spine rendering, MathML attachment quality and safety, language-aware English typography, and authored fallback preservation for unsupported controls-less media.

## How we built it

Codex with GPT-5.6 helped map the existing CoreText pipeline, design the corpus harness, rank real failures, and reduce each selected defect into a minimal synthetic EPUB fixture. Each repair followed a red-green regression loop and received an implementation commit, focused test, compatibility-matrix entry, and durable before/after evidence.

The fixes stay in the production renderer. Official sample binaries and generated result bundles remain in a Git-ignored directory.

## Challenges

The hardest part was separating genuine product failures from harness limitations across reflowable, fixed-layout, mixed-layout, vertical, media, and mathematical content. Another challenge was improving compatibility without presenting pre-existing features as new work or expanding a one-week scope into a claim of complete EPUB 3 support.

## Accomplishments

- 42 official sample EPUBs represented in a checksum-verified manifest.
- 43/43 designated production smoke checks passing, up from 29/43.
- Seven committed before/after evidence packages.
- Minimal fixtures and focused automated regression tests for every claimed repair family.
- Safe fallback behavior: unsupported content does not crash, erase surrounding body text, or silently discard authored static fallback.

## What we learned

Format support is more credible as a maintained compatibility program than as a checkbox. Official samples expose interactions that isolated unit tests miss, while minimized fixtures turn those discoveries into fast, durable regression protection.

## What's next

Keep the corpus workflow as a release-quality gate, expand representative manual review, and address additional EPUB features only when a sample, fixture, and measurable production behavior justify the claim.

## Judge testing notes

1. Open the public Build Week branch linked above.
2. Follow `README.md` to validate the manifest and download the external official corpus.
3. Run the `Yuedu-Reader EPUB3 Corpus` scheme on an iPhone 17 Pro Max simulator.
4. Review `docs/build-week/epub3/compatibility-matrix.md` and the seven linked evidence packages.

No account or hosted service credentials are required for the compatibility harness.

## Values the submitter must provide in Devpost

- Submitter type: choose the truthful Devpost option.
- Country of residence: choose the truthful Devpost option.
- Demo video: provide the final public YouTube URL.
- `/feedback` Session ID: provide the ID returned by the Codex task where most of the work occurred.
- Confirm the branch is pushed and publicly readable before submitting.
