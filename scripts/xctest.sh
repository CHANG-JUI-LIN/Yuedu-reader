#!/bin/bash
# Run xcodebuild tests and stop the moment the verdict lands.
#
# xcodebuild regularly finishes every test, prints the verdict, and then sits at 0% CPU for
# five to fifteen minutes without exiting or writing another line. Measured 2026-09-13:
# tests done at 02:44:31, log's last write 02:45:11, process still alive and idle at 02:53.
# `-parallel-testing-enabled NO` does not prevent this — it prevents the simulator *clones*
# (verified: zero clones left behind), which is a different problem.
#
# So this does not wait for the process to exit. It watches the log for a verdict and kills
# xcodebuild as soon as one appears. The verdict is the result; the wrap-up is not.
#
# Usage:
#   scripts/xctest.sh [-l LOG] [-- <extra xcodebuild args>]
#   scripts/xctest.sh -- -only-testing:'yuedu appTests/TTSRoleVoiceCastTests'
set -uo pipefail

LOG="/tmp/yuedu-test-$(date +%H%M%S).log"
TIMEOUT=900

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l) LOG="$2"; shift 2 ;;
    -t) TIMEOUT="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"

echo "log:  $LOG"
echo "dest: $DEST"

xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination "$DEST" \
  -parallel-testing-enabled NO \
  "$@" > "$LOG" 2>&1 &
BUILD_PID=$!

# Only xcodebuild's own verdict means both halves are done. The per-framework lines are NOT
# usable for this: XCTest prints "Test Suite 'All tests' passed" while Swift Testing is still
# running, so keying on it cut a full run short and reported a partial pass — measured
# 2026-09-13, a run killed after 14 suites when the suite has many more.
VERDICT="\*\* TEST (SUCCEEDED|FAILED) \*\*|\*\* BUILD FAILED \*\*|The following build commands failed"
# There is deliberately no per-framework fallback. The documented hang happens *after*
# "** TEST SUCCEEDED **", so that line always arrives; cutting the run when a half reports
# only truncates it — the Swift Testing half runs for minutes more (BrowserLayoutABHarness
# alone is 107s). TIMEOUT is the only other exit.

elapsed=0
VERDICT_STOP=false
while kill -0 "$BUILD_PID" 2>/dev/null; do
  if grep -qE "$VERDICT" "$LOG" 2>/dev/null; then
    # Give the tail of the output a moment to land, then stop waiting.
    sleep 5
    if kill "$BUILD_PID" 2>/dev/null; then VERDICT_STOP=true; fi
    break
  fi
  if (( elapsed >= TIMEOUT )); then
    echo "!! no verdict after ${TIMEOUT}s; killing" >&2
    kill "$BUILD_PID" 2>/dev/null
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
wait "$BUILD_PID" 2>/dev/null
RAW_STATUS=$?
echo "xcodebuild status: $RAW_STATUS; wrapper verdict stop: $VERDICT_STOP"

echo "--- errors ---"
grep -nE "^/Users.*error:" "$LOG" | sed "s|$ROOT/||" | head -25
echo "--- verdict ---"
grep -E "Test run with [0-9]+ tests|Test Suite 'All tests' (passed|failed)|✘ Suite|\*\* TEST (SUCCEEDED|FAILED) \*\*|\*\* BUILD FAILED \*\*" "$LOG" | head -20

# Framework/background logs can contain "failed" on a successful run. Only the test
# runner's final verdict is authoritative; absence of a verdict is never success.
# A natural nonzero exit is failure even when a success line was printed earlier.
# Only our intentional post-verdict signal may replace normal process completion.
if (( RAW_STATUS != 0 )) && ! { [[ "$VERDICT_STOP" == true ]] && (( RAW_STATUS >= 128 )); }; then
  exit 1
fi
if ! grep -qE 'Test run with [1-9][0-9]* tests|Executed [1-9][0-9]* tests?' "$LOG"; then
  exit 1
fi
if grep -qE "\*\* TEST SUCCEEDED \*\*" "$LOG" && ! grep -qE "✘|\*\* TEST FAILED \*\*|\*\* BUILD FAILED \*\*" "$LOG"; then
  exit 0
fi
exit 1
