#!/bin/bash
# Measure render fidelity for one checkout: plan → capture → score.
#
# The oracle is the copy in THIS directory. The engine being measured comes from
# --tree. Running the main checkout's copy against another checkout keeps a
# change under test from also changing how it is scored; the tree's own
# copies of the frozen files are checked against oracle.lock first.
#
# Usage:
#   scripts/fidelity/measure.sh [--run NAME] [--sets dev|holdout|dev,holdout] [--books id,id]
#                               [--only id:spine,spine]... [--tree DIR] [--markdown FILE]
#                               [--tiles N] [--timeout SECONDS] [--require-goal] [--score-only]
#
# Environment:
#   YUEDU_WORKSPACE     workspace to build with, e.g. one pairing the app with a local package checkout
#   YUEDU_DEST          simulator destination (default: scripts/sim.sh dest)
#   YUEDU_FIDELITY_OUT  capture cache (default: ~/Library/Caches/YueduFidelity)
#
# Exit: 0 measured · 1 capture or scoring failed, or a workspace build that did not use the local engine
#       2 frozen oracle files differ · 3 goal not met (--require-goal)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORACLE_ROOT="$(cd "$HERE/../.." && pwd)"
TREE="$ORACLE_ROOT"
RUN="$(date +%Y%m%d-%H%M%S)"
SETS="dev"
TILES=4
TIMEOUT=5400
MARKDOWN=""
SCORE_ONLY=false
PLAN_ARGS=()
SCORE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --sets) SETS="$2"; shift 2 ;;
    --books) PLAN_ARGS+=(--books "$2"); shift 2 ;;
    --only) PLAN_ARGS+=(--only "$2"); shift 2 ;;
    --tree) TREE="$(cd "$2" && pwd)" || exit 1; shift 2 ;;
    --markdown) MARKDOWN="$2"; shift 2 ;;
    --tiles) TILES="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --require-goal) SCORE_ARGS+=(--require-goal); shift ;;
    --score-only) SCORE_ONLY=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$MARKDOWN" ]] && SCORE_ARGS+=(--markdown "$MARKDOWN")

OUT="${YUEDU_FIDELITY_OUT:-$HOME/Library/Caches/YueduFidelity}"
export YUEDU_FIDELITY_OUT="$OUT"

if ! python3 "$HERE/fidelity.py" lock --check --tree "$TREE"; then
  echo "!! the frozen oracle files differ from scripts/fidelity/oracle.lock; nothing was measured" >&2
  exit 2
fi

if [[ "$SCORE_ONLY" == false ]]; then
  PLAN="$(python3 "$HERE/fidelity.py" plan --run "$RUN" --sets "$SETS" --tiles "$TILES" ${PLAN_ARGS[@]+"${PLAN_ARGS[@]}"})" || exit 1
  echo "plan: $PLAN"

  # Builds share DerivedData and the simulator. A second xcodebuild fails with
  # "build.db: database is locked" and skews any timing run in progress.
  waited=0
  while pgrep -x xcodebuild > /dev/null; do
    if (( waited == 0 )); then echo "waiting for another xcodebuild to finish…"; fi
    if (( waited >= 3600 )); then echo "!! another xcodebuild is still running after an hour" >&2; exit 1; fi
    sleep 10
    waited=$((waited + 10))
  done

  LOG="/tmp/yuedu-fidelity-$RUN.log"
  BUNDLE="/tmp/yuedu-fidelity-$RUN.xcresult"
  rm -rf "$BUNDLE"
  # Every capture runs in the plan's language, whatever the simulator is set to:
  # the reader and WebKit both choose fonts and punctuation by it.
  LANGUAGE="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["language"])' "$PLAN")" || exit 1
  BUILT="$(python3 "$HERE/fidelity.py" describe "$TREE")" || exit 1
  REGION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["region"])' "$PLAN")" || exit 1
  if ! (cd "$TREE" && TEST_RUNNER_YUEDU_FIDELITY_PLAN="$PLAN" bash scripts/xctest.sh -t "$TIMEOUT" -l "$LOG" -- \
      -only-testing:'yuedu appTests/RenderFidelityOracleTests' -resultBundlePath "$BUNDLE" \
      -testLanguage "$LANGUAGE" -testRegion "$REGION"); then
    echo "!! capture failed; log: $LOG (result bundle kept: $BUNDLE)" >&2
    exit 1
  fi
  rm -rf "$BUNDLE"
  grep -E "^FIDELITY book=.*(Error|error)" "$LOG" | cut -c1-300 | head -20
  # Which checkout and which engine package this capture was built from. With a
  # workspace the engine has to be the folder it lists; a build that used the
  # published package instead did not measure the change under test.
  python3 "$HERE/fidelity.py" provenance --run "$RUN" --tree "$TREE" --log "$LOG" --built "$BUILT" \
    --workspace "${YUEDU_WORKSPACE:-}" || exit 1
fi

python3 "$HERE/fidelity.py" score --run "$RUN" ${SCORE_ARGS[@]+"${SCORE_ARGS[@]}"}
