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
#   YUEDU_PACKAGE_DIR=/path/to/package YUEDU_SCHEME=PackageName-Package scripts/xctest.sh -- ...
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
SCHEME="${YUEDU_SCHEME:-Yuedu-Reader}"
XCODEBUILD_COMMAND=(xcodebuild -project Yuedu-Reader.xcodeproj)
# A workspace can override a remote package with its original local checkout
# while a coordinated package change awaits publication. Default runs continue
# to verify the normal project and its published dependency.
if [[ -n "${YUEDU_PACKAGE_DIR:-}" ]]; then
  cd "$YUEDU_PACKAGE_DIR" || exit 1
  XCODEBUILD_COMMAND=(xcodebuild)
elif [[ -n "${YUEDU_WORKSPACE:-}" ]]; then
  XCODEBUILD_COMMAND=(xcodebuild -workspace "$YUEDU_WORKSPACE")
fi

echo "log:  $LOG"
echo "dest: $DEST"

# Drop a stale copy of the app's module before the tests compile against it.
#
# `@testable import yuedu_app` resolves to BUILT_PRODUCTS_DIR/yuedu_app.swiftmodule, a copy
# the app target makes of the module it emits under Intermediates. The test target does wait
# for that copy (its begin-compiling gate includes the app's modules-ready, which includes the
# Copy) — but Xcode can judge the Copy up to date while the copy is older than the module.
# Measured 2026-09-28 with Xcode open on this project, sharing this DerivedData: a copy written
# at 12:26 by that other build survived three command-line builds that re-emitted the module
# (13:34, 13:41, 13:44); the tests compiled against the 12:26 app and failed on code written
# after it ("no member 'isBookmarked'"). Had the API not changed, they would have passed while
# testing old code. Once a command-line build had written the copy itself, later edits were
# copied every time.
#
# A copy whose bytes differ from the module the app last emitted is stale by definition, so it
# goes, and Xcode has to copy again. An identical copy is left alone: replacing it would change
# its timestamp and make the whole test target recompile for nothing.
# Delete this block once, with Xcode open on the project and a stale copy put back by hand,
# a run compiles the tests against the fresh module without it.
drop_stale_app_module_copy() {
  local settings
  settings="$(mktemp)"
  if ! "${XCODEBUILD_COMMAND[@]}" -scheme "$SCHEME" -destination "$DEST" \
    -showBuildSettings -json > "$settings" 2>/dev/null; then
    echo "!! could not read build settings; app module copy not checked" >&2
    rm -f "$settings"
    return 0
  fi
  python3 - "$settings" <<'PY'
import filecmp, glob, json, os, shutil, sys

try:
    with open(sys.argv[1]) as f:
        entries = json.load(f)
except ValueError as error:
    print(f"!! build settings unreadable ({error}); app module copy not checked", file=sys.stderr)
    sys.exit(0)
app = next((e["buildSettings"] for e in entries
            if e.get("buildSettings", {}).get("PRODUCT_MODULE_NAME") == "yuedu_app"), None)
if app is None:
    print("!! no yuedu_app target in the scheme's settings; app module copy not checked", file=sys.stderr)
    sys.exit(0)
module = app["PRODUCT_MODULE_NAME"]
copy_dir = os.path.join(app["BUILT_PRODUCTS_DIR"], module + ".swiftmodule")
for copied in glob.glob(os.path.join(copy_dir, "*.swiftmodule")):
    arch = os.path.basename(copied).split("-", 1)[0]
    emitted = os.path.join(app["TARGET_TEMP_DIR"], "Objects-normal", arch, module + ".swiftmodule")
    if os.path.exists(emitted) and not filecmp.cmp(copied, emitted, shallow=False):
        print(f"stale app module copy ({arch}): removing {copy_dir}")
        shutil.rmtree(copy_dir)
        break
PY
  rm -f "$settings"
}
drop_stale_app_module_copy

# `-collect-test-diagnostics never`: after any failing test, xcodebuild's default
# (on-failure) runs `simctl diagnose ... --timeout=600` before it prints its verdict.
# Measured 2026-09-21: Swift Testing finished at 20:37:44 and the run then sat in that
# child process for ~10 minutes, twice in a row. Collect a sysdiagnose by hand when needed.
"${XCODEBUILD_COMMAND[@]}" test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
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
grep -E "Test run with [0-9]+ tests?|Test Suite 'All tests' (passed|failed)|✘ Suite|\*\* TEST (SUCCEEDED|FAILED) \*\*|\*\* BUILD FAILED \*\*" "$LOG" | head -20

# Every run hands its simulator back erased (maintainer, 2026-11-09). Tests write book caches,
# downloads, cookies and settings into the app's container and nothing ever removed them: the
# device the source audits ran on had grown to 41 GB. Erasing also starts every run from a
# clean install. A device another xcodebuild is still testing on is left alone — erasing it
# would kill that run; the run that ends last erases it. Only a `-destination id=<UDID>`
# names a device to erase (the wrapper's own test passes a fixture name).
erase_tested_simulator() {
  local udid="${DEST#id=}"
  [[ "$DEST" == id=* && "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 0
  if ps -Ao command | grep -E '[x]codebuild' | grep -q "id=$udid"; then
    echo "simulator: $udid still in use by another run; not erased"
    return 0
  fi
  # `shutdown` refuses a device that is already shut down, which is the state erase needs.
  xcrun simctl shutdown "$udid" >/dev/null 2>&1
  if xcrun simctl erase "$udid"; then
    echo "simulator: erased $udid"
  else
    echo "!! simulator $udid could not be erased" >&2
  fi
}
erase_tested_simulator

# Framework/background logs can contain "failed" on a successful run. Only the test
# runner's final verdict is authoritative; absence of a verdict is never success.
# A natural nonzero exit is failure even when a success line was printed earlier.
# Only our intentional post-verdict signal may replace normal process completion.
if (( RAW_STATUS != 0 )) && ! { [[ "$VERDICT_STOP" == true ]] && (( RAW_STATUS >= 128 )); }; then
  exit 1
fi
if ! grep -qE 'Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?' "$LOG"; then
  exit 1
fi
if grep -qE "\*\* TEST SUCCEEDED \*\*" "$LOG" && ! grep -qE "✘|\*\* TEST FAILED \*\*|\*\* BUILD FAILED \*\*" "$LOG"; then
  exit 0
fi
exit 1
