---
name: legado-compat
description: Raise how many sources of real Legado source packs work in Yuedu, one bridge or engine gap at a time, with scripted audit, probe, classification, verification gates and evidence. Use for 書源適配, 相容性, 精校源, 可用率, the YCK packs (1330, 1331, 1329), or any request to keep fixing source compatibility.
---

# Legado source compatibility loop

Goal: every pack in `scripts/legado-compat/state/config.json` reaches its target.
Usable = passed + dead in both probe regions + recorded evidence that the site or the source
is broken for Legado too.

`scripts/legado-compat/lc.py` makes every decision a rule can make: which sources are dead,
which failures are bridge gaps, which item comes next, whether a fix passed. You judge only
where an item's WHAT TO DO card asks you to. Run each command, paste its output before you
decide anything, and never write a number or a status that you did not read in an output.

`lc` below means `python3 -I scripts/legado-compat/lc.py`, run from the repo root.

## Start of every session

1. `lc status`. Paste the output. Do what its NEXT line says.
2. If an item is in progress, `lc show ITEM` and continue it. Never start a second one.

## The loop

1. `lc audit rN`: the full audit of every pack. It takes hours: run it in the background and
   wait for its notification. Use the next unused round name (`lc status` lists them).
2. `lc probe rN`: reachability from here and from the remote host. If the remote part fails,
   the score is PROVISIONAL and dead sources are not counted. Tell the user; never fill in
   reachability yourself.
3. `lc classify rN`: one class per failing source, the score, and the ledger of items.
   Then `lc recheck rN` (in the background) and `lc classify rN` again: the round's network
   failures audited once more on the same code, because one timeout in an audit of hundreds of
   sources does not show a source fails. Once per round, and only before any code changes
   (it refuses otherwise); `score` reports how many passed on the recheck. Report that number
   to the user as a measurement re-run, never as a fix.
4. `lc next`: takes the highest-priority item and prints its WHAT TO DO card. Follow it.
5. End the item in exactly one of these ways, then go back to 4:
   - a fix: `lc verify ITEM --tests 'yuedu appTests/Class'` until GATE PASS, then `lc done ITEM`;
   - evidence: `lc evidence add PACK#INDEX --kind KIND --diag TAG --proof '…' --legado '…'`;
   - a gap found while investigating: `lc add bridge:NAME --sources PACK#INDEX --controls 'REGEX' --why '…'`;
     when the fix makes the source fail the way Legado does (a silent empty result that
     Legado raises as an error), add `--expect 'REGEX'` with Legado's message: the item is
     met when its sources fail with it. An item in progress whose source fails on a wall Legado
     meets too (an anti-bot page its own resend cannot pass) gets that criterion with
     `lc expect ITEM --regex '…' --legado 'file:line, why'`; it holds before the fix as well, so
     the unit tests and the controls are what judge the fix, and the report says so. When its fix is already written, verify it next: `lc release` the item in progress
     (`--reason '…'`; it goes back to todo untouched), then `lc take bridge:NAME`;
   - network noise (network class only): `lc skip ITEM --reason '…'`; a regression, or any
     other non-bridge item, that passes again on this code: `lc diag TAG PACK#INDEX`, then
     `lc skip ITEM --diag TAG --reason '…'` (refused unless every one of its sources passed
     in that diag);
   - Legado fails the same way (bridge clusters only): `lc reject ITEM --legado 'file:line, why'`;
   - stuck: `lc block ITEM --reason '…'`. A blocked bridge fix whose sources all pass a later
     round (the block was the site, not the fix) is verified again with
     `lc take ITEM --reverify '…'`, then `verify` and `done` as usual; any other blocked item
     that passes now ends with `skip --diag`.
6. When `lc next` has no open item, start the next round at step 1.

## Gates

The scripts enforce these. Do not work around them.

- `verify` runs the unit tests you name, then audits the item's sources and up to 40 passing
  sources that use the same API. GATE FAIL: a test fails, an item source still raises the
  signature (or, for an `--expect` item, neither passes nor fails with Legado's error), or a
  control fails with anything other than a network error.
- Three failed verifications block the item. Undo only your own hunks, by hand with Edit,
  tell the user what failed, then `lc next`. One exception: the unit tests and every item
  source passed and only controls failed. Diag those controls on this code
  (`lc diag TAG PACK#INDEX`); when each passes there, or fails on what the site answers (a
  withdrawn book, a dead page), `lc unblock ITEM --diag TAG --reason '…'` (plus `--proof` and
  `--legado` for one that fails) excuses them for this item and gives one more verification.
  It refuses a diag on other code, and a control our code breaks is never excused.
- `done` refuses when the code changed after the passing verification.
- One item in progress at a time, one writer per file.

## Rules

- Fix the shared runtime or pipeline, never one source: no source names, no URL checks, no
  per-source branches.
- Expected values come from `lc oracle CASES.json` (Rhino 1.8.1 and jsoup 1.16.2, configured
  as legado-E configures them). Never guess a value. The oracle has none of Legado's own
  bindings (`java.ajax`, `source`, `book`, `cookie` and `cache` do not exist there): give it the
  smallest expression that shows the behaviour, never a whole source script, and never
  JavaScript downloaded from a site. Case format: the comment at the top of
  `scripts/legado-compat/oracle/Oracle.java`.
- Legado's code: `legado-E/` first, then `legado-md3/`, then `legado-upstream/` (repo root).
  Where they differ, follow legado-E and MD3.
- Never change an existing test's expected value to make it pass, never edit the oracle's
  output, never edit `scripts/legado-compat/state/*.json` by hand.
- Evidence needs a diagnostic dump of the failing request (`lc diag TAG PACK#INDEX`) and the
  reason Legado fails on the same input. Never try to get past a CAPTCHA, Cloudflare or WAF
  page, and never make your own requests pretend to be a browser.
- Root cause before fallback (CLAUDE.md, Engineering Discipline). A fallback needs a code
  comment and a line in your report.
- Never `git checkout --`, `git restore` or `git reset --hard`: they destroy the user's
  uncommitted work. Undo your own change by editing it back, hunk by hunk.
- Commit only when the user asks.
- `lc` runs tests through `scripts/xctest.sh` and waits for other builds. Never pass
  `-derivedDataPath`. Never run `ComicSourcesDebugTests` or `LegadoFullSourceFixtureTests`
  whole.

## Classes

Each failing source gets one class, first match wins: evidence, dead, bridge-gap, interaction,
antibot, network, http-error, js-error, empty, unknown. A source that passed in two of the
last three rounds and now fails (and is not dead, evidence or network) also gets a regression
item, which comes first. The patterns and the WHAT TO DO cards live in
`scripts/legado-compat/rules.json`.

## Packs

`lc audit` reads `pack-ID.json` from the work directory in config.json. If one is missing, ask
the user to download it from that pack's `url`.

## Report

At the end of a session: paste `lc score rN`, then list the items done (and the files each
changed), the evidence added, the items blocked and why, and every fallback or difference
from Legado you introduced.

## Maintaining this workflow

`.claude/skills/legado-compat/` and `.agents/skills/legado-compat/` must stay byte-identical.
After any change under `scripts/legado-compat/` or either skill copy, run `lc check` and paste
its output.
