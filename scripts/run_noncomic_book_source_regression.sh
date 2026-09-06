#!/bin/zsh

# Runs every non-comic Legado source in its own xcodebuild test process. A bad
# source can exhaust or crash JavaScriptCore/WebKit; process isolation ensures
# that failure is recorded and the remaining sources still run.

set -u
set -o pipefail

project_root=${0:A:h:h}
corpus_path=${BOOK_SOURCE_CORPUS_PATH:-/Users/zhangruilin/Desktop/Test document/RULE}
# Resolve the simulator at run time — a pinned UDID goes stale the moment a runtime
# is deleted, and the old default here had already become an orphaned device.
destination_id=${BOOK_SOURCE_SIMULATOR_ID:-$("$project_root/scripts/sim.sh" udid)} || exit 1
artifact_dir=${BOOK_SOURCE_REGRESSION_ARTIFACT_DIR:-/tmp/yuedu_noncomic_source_regression}
final_report=${BOOK_SOURCE_REGRESSION_REPORT_PATH:-/tmp/yuedu_noncomic_source_regression.json}
only_test='yuedu appTests/AllBookSourcesLiveRegressionTests'

mkdir -p "$artifact_dir"
find "$artifact_dir" -maxdepth 1 -type f \( -name 'source-*.json' -o -name 'source-*.log' \) -delete

integer ordinal=0
integer runner_failures=0
typeset -a reports

run_source_test() {
    TEST_RUNNER_RUN_ALL_SOURCE_LIVE_TESTS=1 \
    TEST_RUNNER_ALL_SOURCE_FILE_FILTER="$file_name" \
    TEST_RUNNER_ALL_SOURCE_NAME_FILTER="$source_name" \
    TEST_RUNNER_ALL_SOURCE_REPORT_PATH="$report_path" \
    xcodebuild test \
        -project "$project_root/Yuedu-Reader.xcodeproj" \
        -scheme Yuedu-Reader \
        -destination "id=$destination_id" \
        -only-testing:"$only_test" \
        -parallel-testing-enabled NO \
        -test-timeouts-enabled YES \
        -maximum-test-execution-time-allowance 300 \
        -collect-test-diagnostics never \
        -quiet
}

while IFS= read -r source_file; do
    file_name=${source_file:t}
    [[ "$file_name" == '35个漫画源.json' ]] && continue

    while IFS= read -r source_name; do
        [[ -z "$source_name" ]] && continue
        (( ordinal += 1 ))
        report_path="$artifact_dir/source-${ordinal}.json"
        log_path="$artifact_dir/source-${ordinal}.log"
        reports+=("$report_path")

        print -r -- "NONCOMIC_SOURCE [$ordinal] $file_name :: $source_name"
        # A fresh SpringBoard per case is part of the isolation contract. Merely
        # terminating the app still lets the next xcodebuild hit FBS "Busy".
        xcrun simctl shutdown "$destination_id" >/dev/null 2>&1 || true
        xcrun simctl boot "$destination_id" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$destination_id" -b >"$log_path" 2>&1
        run_source_test >"$log_path" 2>&1
        build_status=$?

        # Xcode can leave SpringBoard rejecting the next test host as Busy even
        # after xcodebuild has exited. This is a simulator launch failure before
        # any source code runs, not a source retry. Reboot once only on that exact
        # preflight signature and await CoreSimulator's real boot-complete signal.
        if (( build_status != 0 )) && \
            rg -q 'Application failed preflight checks|FBSOpenApplicationServiceErrorDomain.*Busy' \
                "$log_path"; then
            print -r -- "NONCOMIC_SOURCE [$ordinal] simulator busy; rebooting and retrying test host once"
            xcrun simctl shutdown "$destination_id" >/dev/null 2>&1 || true
            xcrun simctl boot "$destination_id" >/dev/null 2>&1 || true
            xcrun simctl bootstatus "$destination_id" -b >>"$log_path" 2>&1
            run_source_test >>"$log_path" 2>&1
            build_status=$?
        fi

        completed=0
        expected=1
        if [[ -s "$report_path" ]]; then
            completed=$(jq -r '.completedCount // 0' "$report_path" 2>/dev/null)
            expected=$(jq -r '.expectedCount // 1' "$report_path" 2>/dev/null)
        fi
        if [[ ! -s "$report_path" || "$completed" -ne "$expected" ]]; then
            (( runner_failures += 1 ))
            jq -n \
                --arg corpusPath "$corpus_path" \
                --arg file "$file_name" \
                --arg sourceName "$source_name" \
                --arg detail "isolated test process exited $build_status before completing its report" \
                '{
                    corpusPath: $corpusPath,
                    expectedCount: 1,
                    completedCount: 1,
                    passedCount: 0,
                    missingPrerequisiteCount: 0,
                    excludedCount: 0,
                    upstreamFailureCount: 0,
                    failedCount: 1,
                    currentFile: null,
                    currentSource: null,
                    results: [{
                        file: $file,
                        index: 0,
                        sourceName: $sourceName,
                        sourceIdentifier: "",
                        searchQuery: "",
                        status: "runnerFailure",
                        stage: "test process",
                        detail: $detail,
                        searchCount: null,
                        discoverCategoryCount: null,
                        discoverBookCount: null,
                        chapterCount: null,
                        contentLength: null,
                        reviewMarkerCount: null,
                        reviewStatus: "not reached",
                        elapsedSeconds: 0
                    }]
                }' >"$report_path"
        fi
    done < <(jq -r 'if type == "array" then .[] else . end | .bookSourceName // empty' "$source_file")
done < <(find "$corpus_path" -maxdepth 1 -type f -name '*.json' -print | sort)

if (( ${#reports[@]} == 0 )); then
    print -u2 -- "No non-comic book sources found in $corpus_path"
    exit 2
fi

jq -s --arg corpusPath "$corpus_path" '
    [.[].results[]] as $results |
    {
        corpusPath: $corpusPath,
        expectedCount: ($results | length),
        completedCount: ($results | length),
        passedCount: ([$results[] | select(.status == "passed")] | length),
        missingPrerequisiteCount: ([$results[] | select(.status == "missingPrerequisite")] | length),
        upstreamFailureCount: ([$results[] | select(.status == "upstreamFailure")] | length),
        runnerFailureCount: ([$results[] | select(.status == "runnerFailure")] | length),
        failedCount: ([$results[] | select(.status == "failed" or .status == "upstreamFailure" or .status == "runnerFailure")] | length),
        results: $results
    }
' "${reports[@]}" >"$final_report"

passed=$(jq -r '.passedCount' "$final_report")
missing=$(jq -r '.missingPrerequisiteCount' "$final_report")
failed=$(jq -r '.failedCount' "$final_report")
print -r -- "NONCOMIC_SOURCE_SUMMARY total=$ordinal passed=$passed missingPrerequisite=$missing failed=$failed runnerFailure=$runner_failures report=$final_report"

(( failed == 0 ))
