# OpenAI Build Week Submission Package Design

## Status

Approved in conversation. This written specification is awaiting final user review before implementation planning.

## Objective

Turn the completed EPUB 3 compatibility work on `codex/openai-build-week` into an English, judge-ready submission package without changing application behavior or affecting `main`.

The package must make three facts immediately clear:

1. Yuedu Reader is a native iOS reader built around premium typography and user-owned books and sources.
2. Build Week work used the official IDPF EPUB 3 Samples to create a reproducible compatibility program and improve the designated production checks from 29/43 to 43/43.
3. Passing those checks is bounded evidence, not a claim of complete EPUB 3 support or newly invented support for capabilities that existed before the event baseline.

## Selected Approach

Modify the root `README.md` on `codex/openai-build-week` so the branch itself is the reviewable submission artifact. Preserve the durable product overview, but make the Build Week result, reproduction path, and evidence visible near the top.

Add two supporting English documents:

- `docs/build-week/devpost-submission.md`: polished Devpost title, tagline, description, technology list, category, required-field checklist, and judge-testing notes.
- `docs/build-week/demo-script.md`: a sub-three-minute English video plan with timestamps, on-screen actions, and voiceover.

This is preferred over replacing the README with a temporary event landing page or leaving all Build Week context only on Devpost.

## README Structure

The root README will use this order:

1. Product name, icon, positioning, language links, and existing distribution badges.
2. A short Build Week result block with the baseline tag, final production commit, 29/43 to 43/43 result, and links to the compatibility matrix and evidence packages.
3. A concise explanation of the product problem: premium native reading without ecosystem lock-in.
4. A clear “What changed during Build Week” section covering the official corpus harness and only the verified repair families.
5. A separate “Existing capabilities” section so pre-event support is not presented as new work.
6. Reproduction instructions for manifest verification, corpus download, structural scan, official-corpus smoke tests, and focused regression tests.
7. Architecture, standard build instructions, documentation, contribution, and license information retained from the existing README.

The README will link existing committed media and evidence rather than add new screenshots during this task.

## Devpost Narrative

The Devpost description will use the `Apps for Your Life` category and this positioning:

- `Premium native reading, without ecosystem lock-in.`
- `Your books. Your sources. Your reading experience.`

Its story will follow the judging criteria:

- **Technological implementation:** production CoreText paths, official corpus automation, minimal fixtures, TDD, and exact result bundles.
- **Design:** one coherent native reading experience rather than a demo-only renderer.
- **Potential impact:** users can keep their books and sources while retaining high-quality native typography.
- **Quality of the idea:** compatibility engineering is made measurable and reproducible instead of relying on broad format-support claims.

The copy will state that the official sample binaries are downloaded into a Git-ignored directory and are not committed.

The custom-field checklist will record the known recommendation—public branch URL for `codex/openai-build-week`—and enumerate the user-owned values still required at submission time: submitter type, country of residence, public YouTube URL, and the `/feedback` Session ID from the task where most work occurred. It will not invent those values.

## Codex and Model Disclosure

The package will describe the observable workflow truthfully: Codex helped inspect the codebase, design the corpus workflow, implement changes with red-green tests, diagnose official-sample failures, run verification, and assemble evidence.

The event requires entrants to explain their use of Codex and GPT-5.6. The documents must not infer or fabricate a model identity. They will include GPT-5.6 wording only when the user confirms that the qualifying task actually ran on GPT-5.6; otherwise the user-facing submission checklist will flag that disclosure for confirmation before final submission.

## Demo Video Design

The script will target 2:30–2:50, leaving margin below the three-minute limit. It will contain spoken narration, not music-only captions, and use five segments:

1. Problem and product promise.
2. Existing native reading experience and source freedom.
3. Build Week method: official corpus, baseline, and reproducible harness.
4. Before/after highlights: MathML, English typography, routing/resource fixes, fixed-layout images, and safe media fallback.
5. 43/43 result, evidence links, scope boundary, and closing message.

The script will distinguish existing product capability shots from Build Week improvements on screen and in narration.

## Scope Boundaries

This task changes documentation only. It will not:

- modify application code, tests, or project configuration;
- merge or cherry-pick changes from `main`;
- push the branch or submit the Devpost project without a separate explicit instruction;
- claim complete EPUB 3 support;
- claim that CFI, Ruby, fixed layout, Media Overlay, audio/video, RTL/Bidi, PLS/SSML, or the original MathML pipeline were created during Build Week;
- fabricate a repository state, video URL, session ID, team status, country, or model identity.

## Verification

Before committing the submission package:

- check every repository-relative Markdown link;
- run `python3 scripts/epub3_samples.py manifest-check` and `matrix-check` so copied result claims remain aligned with committed evidence;
- confirm that all test commands match the existing schemes and simulator names;
- scan for `TBD`, `TODO`, dummy URLs, unsupported superlatives, and accidental complete-EPUB-3 claims;
- verify that the video narration remains under three minutes at a conservative speaking pace;
- run `git diff --check` and confirm only the three documentation files are changed.

The implementation will be committed separately from this design document.
