#!/usr/bin/env bash
# Saves the OPDS 2 fixtures GutenbergOPDS2FixtureTests reads, from Gutenberg's
# development endpoint (plan 2026-10-07-public-domain-libraries, decision 18).
# Four requests in total, one after another, no retries. Run by hand only;
# the app itself never points at this endpoint.
#
#   bash scripts/fetch_gutenberg_opds2_fixtures.sh
set -euo pipefail

ROOT_URL="https://opds-test.pglaf.org/opds/"
USER_AGENT="Yuedu/dev (iOS; +https://yuedureader.com/support)"
ACCEPT="application/opds+json, application/json;q=0.9"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Tests/iOS/yuedu appTests/Fixtures/GutenbergOPDS2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

fetch() { # name url
  local name="$1" url="$2"
  echo "GET $url -> $name" >&2
  curl -fsS -A "$USER_AGENT" -H "Accept: $ACCEPT" -D "$WORK/$name.headers" -o "$OUT/$name" "$url"
  local type
  type="$(grep -i '^content-type:' "$WORK/$name.headers" | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//')"
  printf '%s\t%s\t%s\n' "$name" "$url" "$type" >> "$WORK/sources.tsv"
}

# pick <mode> <file> <base url>: prints the next URL to request.
pick() {
  python3 -I - "$@" <<'PY'
import json, re, sys
from urllib.parse import urljoin
mode, path, base = sys.argv[1:4]
doc = json.load(open(path, encoding="utf-8"))
def rels(link):
    rel = link.get("rel", [])
    return [rel] if isinstance(rel, str) else rel
if mode == "group":
    for group in doc.get("groups", []):
        if group.get("publications"):
            for link in group.get("links", []):
                if "self" in rels(link):
                    print(urljoin(base, link["href"])); sys.exit(0)
    sys.exit("no publications group with a self link in the root")
if mode == "search":
    for link in doc.get("links", []):
        if "search" in rels(link):
            def expand(m):
                names = [n.strip() for n in m.group(2).split(",")]
                if "query" not in names: return ""
                return {"?": "?query=austen", "&": "&query=austen"}.get(m.group(1), "austen")
            print(urljoin(base, re.sub(r"\{([?&]?)([^{}]*)\}", expand, link["href"]))); sys.exit(0)
    sys.exit("no search link in the root")
if mode == "publication":
    for pub in doc.get("publications", []):
        for link in pub.get("links", []):
            if "self" in rels(link):
                print(urljoin(base, link["href"])); sys.exit(0)
    sys.exit("no publication with a self link in the group page")
PY
}

fetch root.json "$ROOT_URL"
GROUP_URL="$(pick group "$OUT/root.json" "$ROOT_URL")"
fetch group.json "$GROUP_URL"
fetch search.json "$(pick search "$OUT/root.json" "$ROOT_URL")"
fetch publication.json "$(pick publication "$OUT/group.json" "$GROUP_URL")"

python3 -I - "$WORK/sources.tsv" "$OUT/sources.json" <<'PY'
import json, sys
rows = [line.rstrip("\n").split("\t") for line in open(sys.argv[1], encoding="utf-8")]
sources = {name: {"url": url, "contentType": ctype} for name, url, ctype in rows}
json.dump(sources, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
open(sys.argv[2], "a").write("\n")
PY
echo "Saved to $OUT" >&2
