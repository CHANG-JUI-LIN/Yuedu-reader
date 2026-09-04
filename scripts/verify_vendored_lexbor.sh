#!/bin/bash
set -euo pipefail

package_dir="${1:-Packages/CLexbor}"
manifest="$package_dir/VENDOR-MANIFEST.json"

fail() {
  printf 'vendored Lexbor verification failed: %s\n' "$1" >&2
  exit 1
}

test -f "$manifest" || fail "missing $manifest"
jq -e . "$manifest" >/dev/null || fail "invalid manifest JSON"

test "$(jq -r '.upstream.repository' "$manifest")" = \
  "https://github.com/lexbor/lexbor.git" || fail "unexpected upstream repository"
test "$(jq -r '.upstream.tag' "$manifest")" = "v3.0.0" || fail "unexpected upstream tag"
test "$(jq -r '.upstream.tagType' "$manifest")" = "lightweight" || fail "unexpected tag type"
test "$(jq -r '.upstream.commit' "$manifest")" = \
  "2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe" || fail "unexpected upstream commit"
test "$(jq -r '.generation.command' "$manifest")" = \
  "perl single.pl --port=posix html css selectors style" || fail "unexpected generation command"
test "$(jq -c '.generation.requestedModules' "$manifest")" = \
  '["html","css","selectors","style"]' || fail "unexpected requested modules"
test "$(jq -c '.generation.resolvedModules' "$manifest")" = \
  '["core","css","dom","html","ns","selectors","style","tag"]' || \
  fail "unexpected resolved modules"

for key in LICENSE NOTICE lexbor_amalgamated_generated_h lexbor_amalgamated_generated_c; do
  relative="$(jq -er ".outputs.${key}.path" "$manifest")" || fail "missing output path for $key"
  expected="$(jq -er ".outputs.${key}.sha256" "$manifest")" || fail "missing hash for $key"
  [[ "$relative" != /* && "$relative" != *..* ]] || fail "unsafe output path for $key"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash for $key"
  test -f "$package_dir/$relative" || fail "missing output $relative"
  actual="$(shasum -a 256 "$package_dir/$relative" | awk '{print $1}')"
  test "$actual" = "$expected" || fail "hash mismatch for $relative"
done

printf 'vendored Lexbor verification passed (%s)\n' \
  "$(jq -r '.upstream.tag + "@" + .upstream.commit' "$manifest")"
