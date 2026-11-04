#!/bin/bash
# Measure where WebKit draws list markers in the list fixtures, for the browser engine's
# markers to match (docs/superpowers/specs/2026-11-03-browser-list-markers-design.md §12).
# Not part of the oracle: nothing here is scored, and oracle.lock does not cover it.
#
# Usage:
#   scripts/fidelity/list_probe.sh [--run NAME] [fixture folder ...]
#
# Default folders: every fixtures/gaps/*list-markers. Each chapter's measurements land in
# $YUEDU_FIDELITY_OUT/list-probe/<run>/<folder>/<chapter>.json, with a crop of every marker.
# A folder whose fixture.json sets "elements": true (S001e-ua-rules, S001f-vertical-ua-rules,
# S001g-quotes-and-generic-families) also measures every [data-m] element; pass it by name.
#
# Environment:
#   YUEDU_DEST          simulator destination (default: scripts/sim.sh dest)
#   YUEDU_FIDELITY_OUT  capture cache (default: ~/Library/Caches/YueduFidelity)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUN="$(date +%Y%m%d-%H%M%S)"
FOLDERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    *) FOLDERS+=("$(cd "$1" && pwd)") || exit 1; shift ;;
  esac
done
if [[ ${#FOLDERS[@]} -eq 0 ]]; then
  for folder in "$HERE"/fixtures/gaps/*list-markers; do FOLDERS+=("$folder"); done
fi

OUT="${YUEDU_FIDELITY_OUT:-$HOME/Library/Caches/YueduFidelity}/list-probe/$RUN"
mkdir -p "$OUT" || exit 1
PLAN="$OUT/plan.json"
python3 - "$PLAN" "$OUT" "${FOLDERS[@]}" <<'PY' || exit 1
import json, sys
plan, out, folders = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(plan, "w", encoding="utf-8") as handle:
    json.dump({"out": out, "language": "zh-Hant", "fixtures": folders}, handle, ensure_ascii=False, indent=1)
PY
echo "plan: $PLAN"

# Builds share DerivedData and the simulator (measure.sh waits the same way).
waited=0
while pgrep -x xcodebuild > /dev/null; do
  if (( waited == 0 )); then echo "waiting for another xcodebuild to finish…"; fi
  if (( waited >= 3600 )); then echo "!! another xcodebuild is still running after an hour" >&2; exit 1; fi
  sleep 10
  waited=$((waited + 10))
done

LOG="/tmp/yuedu-list-probe-$RUN.log"
BUNDLE="/tmp/yuedu-list-probe-$RUN.xcresult"
rm -rf "$BUNDLE"
# The fixtures are Traditional Chinese; WebKit picks fonts and punctuation by the process language.
if ! (cd "$ROOT" && TEST_RUNNER_YUEDU_LIST_PROBE="$PLAN" bash scripts/xctest.sh -t 1800 -l "$LOG" -- \
    -only-testing:'yuedu appTests/ListMarkerProbeTests' -resultBundlePath "$BUNDLE" \
    -testLanguage zh-Hant -testRegion TW); then
  echo "!! probe failed; log: $LOG (result bundle kept: $BUNDLE)" >&2
  exit 1
fi
rm -rf "$BUNDLE"
# A green run that wrote nothing did not get the plan.
if [[ ! -f "$OUT/index.json" ]]; then
  echo "!! the test passed but wrote no index; the plan did not reach it. log: $LOG" >&2
  exit 1
fi
echo "out: $OUT"
