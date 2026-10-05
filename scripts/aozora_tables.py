#!/usr/bin/env python3
"""Generate the Aozora Bunko gaiji and accent tables bundled with the app.

Input: a checkout of https://github.com/aozorahack/aozora2html (CC0) at the
pinned commit. Its `yml/jis2ucs.yml` maps every JIS X 0213 code to Unicode as
numeric character references, and `yml/accent_table.yml` maps an Aozora accent
decomposition (base letter plus mark, e.g. "e'") to a JIS code.

Output, in the given directory:
  aozora-jis2ucs.json           {"1-2-24": "ヿ", ...} in plane-row-cell order
  aozora-accent.json            {"e'": "1-9-63", ...}; resolved through the JIS
                                table when the app loads it
  aozora-tables.manifest.json   upstream commit and SHA-256 of inputs and outputs

The output is byte-for-byte reproducible: running the script twice writes the
same files.

Usage:
    git clone https://github.com/aozorahack/aozora2html /path/to/aozora2html
    git -C /path/to/aozora2html checkout 9ca5395
    python3 scripts/aozora_tables.py /path/to/aozora2html Resources/Assets
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

PINNED_COMMIT = "9ca5395fef8d5e96c44a0b0d7f4bba27013e66a4"
UPSTREAM = "https://github.com/aozorahack/aozora2html"
JIS_INPUT = "yml/jis2ucs.yml"
ACCENT_INPUT = "yml/accent_table.yml"
JIS_OUTPUT = "aozora-jis2ucs.json"
ACCENT_OUTPUT = "aozora-accent.json"
MANIFEST_OUTPUT = "aozora-tables.manifest.json"
EXPECTED_JIS_ENTRIES = 11233

JIS_LINE = re.compile(r'^:([12])-(\d{2})-(\d{2}): "((?:&#x[0-9A-Fa-f]+;)+)"$')
REFERENCE = re.compile(r"&#x([0-9A-Fa-f]+);")
CODE = re.compile(r"^\d-\d{2}/([12])-(\d{2})-(\d{2})$")


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def jis_key(plane, row, cell):
    return f"{int(plane)}-{int(row)}-{int(cell)}"


def read_jis_table(path):
    """`:1-02-24: "&#x30FF;"` per line; values may hold several references."""
    table = {}
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    if not lines or lines[0] != "---":
        fail(f"{path}: expected a YAML document marker on the first line")
    for number, line in enumerate(lines[1:], start=2):
        match = JIS_LINE.match(line)
        if not match:
            fail(f"{path}:{number}: unexpected line {line!r}")
        plane, row, cell, references = match.groups()
        text = "".join(chr(int(code, 16)) for code in REFERENCE.findall(references))
        key = jis_key(plane, row, cell)
        if key in table:
            fail(f"{path}:{number}: duplicate code {key}")
        table[key] = text
    return table


def unquote(token):
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        return token[1:-1]
    return token


def read_accent_table(path):
    """Nested mapping: base letter -> mark (-> second mark) -> [code, name].

    Only the shapes the file uses are accepted: keys at indent 0, 2 and 4,
    and two-item lists whose first item is `1-09/1-09-23`.
    """
    entries = {}
    stack = []  # (indent, key)
    pending = None  # (sequence, [items]) while reading a list
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    if not lines or lines[0] != "---":
        fail(f"{path}: expected a YAML document marker on the first line")
    for number, line in enumerate(lines[1:], start=2):
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        body = line.strip()
        if body.startswith("- "):
            if pending is None:
                fail(f"{path}:{number}: list item outside a mapping")
            pending[1].append(unquote(body[2:]))
            continue
        if not body.endswith(":"):
            fail(f"{path}:{number}: unexpected line {line!r}")
        if pending is not None:
            entries[pending[0]] = pending[1]
            pending = None
        key = unquote(body[:-1])
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, key))
        sequence = "".join(part for _, part in stack)
        pending = (sequence, [])
    if pending is not None:
        entries[pending[0]] = pending[1]
    table = {}
    for sequence, items in entries.items():
        if not items:
            continue  # an inner mapping such as "A" -> "E" -> ...
        if len(items) != 2:
            fail(f"{path}: {sequence!r} has {len(items)} items, expected code and name")
        match = CODE.match(items[0])
        if not match:
            fail(f"{path}: {sequence!r} has an unexpected code {items[0]!r}")
        table[sequence] = jis_key(*match.groups())
    return table


def numeric_order(key):
    return tuple(int(part) for part in key.split("-"))


def write_json(path, payload):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=0, sort_keys=False)
        handle.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("aozora2html")
    parser.add_argument("output")
    args = parser.parse_args()

    try:
        commit = subprocess.run(["git", "-C", args.aozora2html, "rev-parse", "HEAD"],
                                check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot read the aozora2html commit: {error}")
    if commit != PINNED_COMMIT:
        fail(f"aozora2html is at {commit}; check out {PINNED_COMMIT[:7]} first")

    jis_path = os.path.join(args.aozora2html, JIS_INPUT)
    accent_path = os.path.join(args.aozora2html, ACCENT_INPUT)
    jis = read_jis_table(jis_path)
    if len(jis) != EXPECTED_JIS_ENTRIES:
        fail(f"{JIS_INPUT}: {len(jis)} entries, expected {EXPECTED_JIS_ENTRIES}")
    accent = read_accent_table(accent_path)
    missing = sorted(code for code in accent.values() if code not in jis)
    if missing:
        fail(f"{ACCENT_INPUT}: codes missing from {JIS_INPUT}: {missing}")

    os.makedirs(args.output, exist_ok=True)
    jis_out = os.path.join(args.output, JIS_OUTPUT)
    accent_out = os.path.join(args.output, ACCENT_OUTPUT)
    write_json(jis_out, {key: jis[key] for key in sorted(jis, key=numeric_order)})
    write_json(accent_out, {key: accent[key] for key in sorted(accent)})
    manifest = {
        "generator": "scripts/aozora_tables.py",
        "license": "CC0-1.0",
        "upstream": UPSTREAM,
        "commit": commit,
        "inputs": {JIS_INPUT: sha256(jis_path), ACCENT_INPUT: sha256(accent_path)},
        "outputs": {JIS_OUTPUT: sha256(jis_out), ACCENT_OUTPUT: sha256(accent_out)},
        "entries": {JIS_OUTPUT: len(jis), ACCENT_OUTPUT: len(accent)},
    }
    with open(os.path.join(args.output, MANIFEST_OUTPUT), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"{JIS_OUTPUT}: {len(jis)} entries; {ACCENT_OUTPUT}: {len(accent)} entries")


if __name__ == "__main__":
    main()
