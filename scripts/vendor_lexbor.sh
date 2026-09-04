#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'usage: %s /path/to/checked-out/lexbor\n' "$0" >&2
  exit 64
fi

upstream_dir="${1%/}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
package_dir="$repository_root/Packages/CLexbor"
source_dir="$package_dir/Sources/CLexbor"

expected_commit='2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe'
expected_version='LEXBOR_VERSION=3.0.0'
expected_version_sha='6c4ca09e0d3549711034c2ce201cd27153bdd686cd57a60db8d7aed76068e087'
expected_generator_sha='8bf7856ea4195ad41945a81d3b37343a2ef489a5ff8f9abdffd481979d1c7ea2'
expected_license_sha='7321caa1f366dfbebf799b6c6c2604772dbb12ef10ed6a6b7cbb384b3401c4dd'
expected_notice_sha='b87f965fd2eba846a0a502d633dd7e7a680b93de5c514c404c948ccf1e5c9dc7'
release_date='Tue Mar 31 18:45:44 2026 UTC'

fail() {
  printf 'Lexbor vendoring failed: %s\n' "$1" >&2
  exit 1
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

test -d "$upstream_dir/.git" || fail "argument is not an already-checked-out Git repository"
test -f "$upstream_dir/single.pl" || fail "missing upstream single.pl"
test -f "$upstream_dir/version" || fail "missing upstream version"
test -f "$upstream_dir/LICENSE" || fail "missing upstream LICENSE"
test -f "$upstream_dir/NOTICE" || fail "missing upstream NOTICE"

actual_commit="$(git -C "$upstream_dir" rev-parse HEAD)"
test "$actual_commit" = "$expected_commit" || fail "unexpected upstream commit $actual_commit"
git -C "$upstream_dir" tag --points-at HEAD | grep -Fxq 'v3.0.0' || fail "HEAD is not tagged v3.0.0"
test "$(cat "$upstream_dir/version")" = "$expected_version" || fail "unexpected version file"
test "$(sha256 "$upstream_dir/version")" = "$expected_version_sha" || fail "version hash mismatch"
test "$(sha256 "$upstream_dir/single.pl")" = "$expected_generator_sha" || fail "single.pl hash mismatch"
test "$(sha256 "$upstream_dir/LICENSE")" = "$expected_license_sha" || fail "LICENSE hash mismatch"
test "$(sha256 "$upstream_dir/NOTICE")" = "$expected_notice_sha" || fail "NOTICE hash mismatch"

work_dir="$(mktemp -d /tmp/yuedu-lexbor-generate.XXXXXX)"
trap 'find "$work_dir" -depth -delete 2>/dev/null || true' EXIT

generate() {
  local output="$1"
  (
    cd "$upstream_dir"
    LC_ALL=C TZ=UTC perl ./single.pl --port=posix html css selectors style
  ) > "$output"
}

normalize() {
  local input="$1"
  local output="$2"
  perl -0pe '
    BEGIN { $copyright_count = 0; $date_count = 0; }
    $copyright_count += s/^ \* Copyright \(C\) 2018-[0-9]{4} Alexander Borisov$/ * Copyright (C) 2018-2026 Alexander Borisov/m;
    $date_count += s/^ \* Date: .*$/ * Date: Tue Mar 31 18:45:44 2026 UTC/m;
    END {
      die "unexpected generated copyright field count: $copyright_count\n" unless $copyright_count == 1;
      die "unexpected generated Date field count: $date_count\n" unless $date_count == 1;
    }
  ' "$input" > "$output"
}

generate "$work_dir/raw-first"
generate "$work_dir/raw-second"
normalize "$work_dir/raw-first" "$work_dir/normalized-first"
normalize "$work_dir/raw-second" "$work_dir/normalized-second"
cmp "$work_dir/normalized-first" "$work_dir/normalized-second" >/dev/null || \
  fail "two normalized official generator runs differ"

grep -Fq ' * Version: 3.0.0' "$work_dir/normalized-first" || fail "generated version is not 3.0.0"
grep -Fq ' * Modules: css-1.4.0, html-2.9.0, selectors-0.6.0, style-0.3.0' \
  "$work_dir/normalized-first" || fail "generated requested-module set differs"
grep -Fq ' * Dependencies: core-3.0.0, dom-2.1.0, ns-1.4.0, tag-1.5.0' \
  "$work_dir/normalized-first" || fail "generated dependency closure differs"

source_line="$(awk '/^\/\* Source:/ { print NR; exit }' "$work_dir/normalized-first")"
test -n "$source_line" || fail "generated output has no source boundary"
test "$source_line" -gt 1 || fail "invalid generated source boundary"

{
  printf '#ifndef YUEDU_LEXBOR_AMALGAMATED_GENERATED_H\n'
  printf '#define YUEDU_LEXBOR_AMALGAMATED_GENERATED_H\n\n'
  sed -n "1,$((source_line - 1))p" "$work_dir/normalized-first"
  printf '\n#endif /* YUEDU_LEXBOR_AMALGAMATED_GENERATED_H */\n'
} > "$work_dir/lexbor-amalgamated.generated.h"

{
  printf '#include "lexbor-amalgamated.generated.h"\n\n'
  sed -n "${source_line},\$p" "$work_dir/normalized-first"
  printf '\n#include "CLexborBridgeImplementation.inc"\n'
} > "$work_dir/lexbor-amalgamated.generated.c"

cp "$upstream_dir/LICENSE" "$work_dir/LICENSE"
cp "$upstream_dir/NOTICE" "$work_dir/NOTICE"

license_output_sha="$(sha256 "$work_dir/LICENSE")"
notice_output_sha="$(sha256 "$work_dir/NOTICE")"
header_output_sha="$(sha256 "$work_dir/lexbor-amalgamated.generated.h")"
source_output_sha="$(sha256 "$work_dir/lexbor-amalgamated.generated.c")"

jq -n -S \
  --arg commit "$expected_commit" \
  --arg releaseDate "$release_date" \
  --arg versionSHA "$expected_version_sha" \
  --arg generatorSHA "$expected_generator_sha" \
  --arg licenseSHA "$license_output_sha" \
  --arg noticeSHA "$notice_output_sha" \
  --arg headerSHA "$header_output_sha" \
  --arg sourceSHA "$source_output_sha" \
  '{
    schemaVersion: 1,
    upstream: {
      repository: "https://github.com/lexbor/lexbor.git",
      tag: "v3.0.0",
      tagType: "lightweight",
      commit: $commit,
      version: "3.0.0",
      releaseDateUTC: $releaseDate
    },
    generation: {
      generatorPath: "single.pl",
      generatorSHA256: $generatorSHA,
      versionFileSHA256: $versionSHA,
      command: "perl single.pl --port=posix html css selectors style",
      environment: {LC_ALL: "C", TZ: "UTC"},
      requestedModules: ["html", "css", "selectors", "style"],
      resolvedModules: ["core", "css", "dom", "html", "ns", "selectors", "style", "tag"],
      normalization: [
        "generated Date set to upstream v3.0.0 commit date",
        "generated copyright end-year set to 2026"
      ],
      vendoringScript: "scripts/vendor_lexbor.sh",
      offlineVerifier: "scripts/verify_vendored_lexbor.sh"
    },
    outputs: {
      LICENSE: {path: "LICENSE", sha256: $licenseSHA},
      NOTICE: {path: "NOTICE", sha256: $noticeSHA},
      lexbor_amalgamated_generated_h: {
        path: "Sources/CLexbor/lexbor-amalgamated.generated.h",
        sha256: $headerSHA
      },
      lexbor_amalgamated_generated_c: {
        path: "Sources/CLexbor/lexbor-amalgamated.generated.c",
        sha256: $sourceSHA
      }
    }
  }' > "$work_dir/VENDOR-MANIFEST.json"

mkdir -p "$source_dir"
install -m 0644 "$work_dir/LICENSE" "$package_dir/LICENSE"
install -m 0644 "$work_dir/NOTICE" "$package_dir/NOTICE"
install -m 0644 "$work_dir/VENDOR-MANIFEST.json" "$package_dir/VENDOR-MANIFEST.json"
install -m 0644 "$work_dir/lexbor-amalgamated.generated.h" \
  "$source_dir/lexbor-amalgamated.generated.h"
install -m 0644 "$work_dir/lexbor-amalgamated.generated.c" \
  "$source_dir/lexbor-amalgamated.generated.c"

printf 'Vendored Lexbor v3.0.0 from %s\n' "$expected_commit"
