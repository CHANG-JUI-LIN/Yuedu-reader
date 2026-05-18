#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCES="$ROOT/sources"
SAMPLES="$ROOT/samples"

mkdir -p "$SAMPLES"

for source_dir in "$SOURCES"/*; do
  [ -d "$source_dir" ] || continue
  name="$(basename "$source_dir")"
  output="$SAMPLES/$name.epub"
  rm -f "$output"
  (
    cd "$source_dir"
    zip -X0 "$output" mimetype >/dev/null
    zip -Xr9D "$output" META-INF EPUB >/dev/null
  )
done

