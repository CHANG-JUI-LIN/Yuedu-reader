#!/bin/bash
# Verify an xcodebuild test run actually executed the expected number of tests.
#
# Usage:
#   scripts/verify_test_run.sh <min-expected-tests> [xcresult-path]
#
# Fails (exit 1) when:
#   - no xcresult is found / cannot be parsed
#   - totalTestCount is zero or below <min-expected-tests>
#   - any test failed
#
# This guards against the environment quirk where method-level -only-testing
# filters execute ZERO tests (xcresult totalTestCount: 0) while xcodebuild
# still reports "TEST EXECUTE SUCCEEDED".

set -u

MIN_EXPECTED="${1:?usage: verify_test_run.sh <min-expected-tests> [xcresult-path]}"
RESULT_PATH="${2:-$(ls -td "$HOME/Library/Developer/Xcode/DerivedData/Yuedu-Reader-"*/Logs/Test/*.xcresult 2>/dev/null | head -1)}"

if [[ -z "$RESULT_PATH" || ! -d "$RESULT_PATH" ]]; then
    echo "FAIL: no xcresult bundle found" >&2
    exit 1
fi

JSON="$(xcrun xcresulttool get test-results summary --path "$RESULT_PATH" 2>/dev/null)"
if [[ -z "$JSON" ]]; then
    echo "FAIL: xcresulttool could not read $RESULT_PATH" >&2
    exit 1
fi

read -r TOTAL FAILED <<< "$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print(d.get('totalTestCount') or 0, d.get('failedTests') or 0)
" "$JSON")"

echo "guard: total=$TOTAL failed=$FAILED expected>=$MIN_EXPECTED"

if [[ "$TOTAL" -lt "$MIN_EXPECTED" ]]; then
    echo "FAIL: only $TOTAL tests ran (expected at least $MIN_EXPECTED) — zero-test run guard" >&2
    exit 1
fi
if [[ "$FAILED" -ne 0 ]]; then
    echo "FAIL: $FAILED test(s) failed" >&2
    exit 1
fi

echo "PASS: $TOTAL tests executed, 0 failures"
