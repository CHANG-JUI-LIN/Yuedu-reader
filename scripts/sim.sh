#!/bin/bash
# Resolve a simulator at call time instead of hardcoding a device name anywhere.
#
# Why this exists: this machine's simulators get deleted and re-installed often, and
# two things go wrong every time.
#   1. `-destination 'platform=iOS Simulator,name=…'` matches by name and picks
#      silently — and a deleted runtime leaves same-named orphans behind.
#   2. A runtime NEWER than the ACTIVE Xcode's SDK can be booted by `simctl` but cannot
#      be built against, so the scheme ends up with zero usable destinations while
#      `simctl list` still cheerfully reports the device as available. With both a
#      release Xcode and an Xcode-beta installed, this usually means `xcode-select`
#      points at the release while the runtimes belong to the beta — the GUI works and
#      only the command line breaks.
# So: pick the Xcode whose SDK covers the installed runtimes, filter devices by that
# SDK, and address the device by UDID.
#
# Usage:
#   sim.sh udid [filter]   UDID of the best buildable simulator
#   sim.sh dest [filter]   ready-made xcodebuild destination: id=<UDID>
#   sim.sh name [filter]   "<name> — iOS <ver> — <udid>"
#   sim.sh list            every buildable simulator, newest runtime first
#   sim.sh xcode           DEVELOPER_DIR of the Xcode these devices need
#   sim.sh doctor          full inventory: Xcodes, SDK, runtimes, orphans, duplicates
#
# `dest` and `xcode` are a pair — export the one before using the other:
#   export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
#   xcodebuild … -destination "$(bash scripts/sim.sh dest)"
#
# `filter` is a case-insensitive substring of the device name (default: iPhone).
# Selection: newest compatible runtime, then Pro Max > Pro > plain, then name desc.
set -euo pipefail

CMD="${1:-doctor}"
FILTER="${2:-iPhone}"

py() { FILTER="${1:-}" MODE="$2" python3 - <<'PY'
import glob, json, os, re, subprocess, sys

flt  = os.environ["FILTER"].lower()
mode = os.environ["MODE"]

def sh(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"{' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout

def parse_version(text):
    try:
        v = tuple(int(p) for p in text.strip().split("."))
    except ValueError:
        return None
    return (v + (0, 0))[:2]

def sim_sdk_of(developer_dir):
    """Highest iPhoneSimulator SDK inside an Xcode, or None."""
    sdk_dir = os.path.join(developer_dir,
                           "Platforms/iPhoneSimulator.platform/Developer/SDKs")
    best = None
    try:
        entries = os.listdir(sdk_dir)
    except OSError:
        return None
    for name in entries:
        m = re.fullmatch(r"iPhoneSimulator(\d+(?:\.\d+)*)\.sdk", name)
        if m:
            v = parse_version(m.group(1))
            if v and (best is None or v > best):
                best = v
    return best

# Every Xcode on the machine, plus whichever one is currently selected.
active = os.environ.get("DEVELOPER_DIR") or sh("xcode-select", "-p").strip()
xcodes = {}                                    # developer_dir -> sim SDK version
for app in sorted(glob.glob("/Applications/Xcode*.app")):
    dev = os.path.join(app, "Contents/Developer")
    v = sim_sdk_of(dev)
    if v:
        xcodes[dev] = v
if active not in xcodes:
    v = sim_sdk_of(active)
    if v:
        xcodes[active] = v
if not xcodes:
    sys.exit("No Xcode with an iPhoneSimulator SDK found under /Applications.")

# Newest installed iOS runtime — that is what the toolchain has to be able to reach.
runtimes = json.loads(sh("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
runtime_versions = [parse_version(r["version"]) for r in runtimes
                    if r.get("isAvailable") and r.get("identifier", "").rsplit(".", 1)[-1]
                    .startswith("iOS-")]
runtime_versions = [v for v in runtime_versions if v]
newest_runtime = max(runtime_versions) if runtime_versions else None

# Prefer the active Xcode when it can already build to the newest runtime; otherwise
# fall back to the one with the highest SDK. Never switch silently without saying so.
chosen = active if active in xcodes else max(xcodes, key=lambda d: xcodes[d])
if newest_runtime and xcodes.get(chosen, (0, 0)) < newest_runtime:
    better = max(xcodes, key=lambda d: xcodes[d])
    if xcodes[better] >= newest_runtime:
        chosen = better

sdk = xcodes[chosen]
switched = os.path.realpath(chosen) != os.path.realpath(active)

def runtime_version(identifier):
    tail = identifier.rsplit(".", 1)[-1]          # iOS-27-0
    if not tail.startswith("iOS-"):
        return None
    try:
        v = tuple(int(p) for p in tail[4:].split("-"))
    except ValueError:
        return None
    return (v + (0, 0))[:2]

def tier(name):
    # Strip parenthetical chip/runtime suffixes first, so "iPad mini (A17 Pro)"
    # does not outrank "iPad Pro 11-inch (M5)".
    low = re.sub(r"\([^)]*\)", "", name).lower()
    if "pro max" in low: return 3
    if "pro" in low:     return 2
    if "max" in low:     return 1
    return 0

os.environ["DEVELOPER_DIR"] = chosen
devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]

usable, too_new = [], []
for identifier, devs in devices.items():
    version = runtime_version(identifier)
    if version is None:
        continue
    for d in devs:
        if not d.get("isAvailable") or flt not in d["name"].lower():
            continue
        (too_new if version > sdk else usable).append((version, tier(d["name"]), d["name"], d["udid"]))

def label(r):
    return f"{r[2]} — iOS {'.'.join(map(str, r[0]))} — {r[3]}"

sdk_str = ".".join(map(str, sdk))

if mode == "sdk":
    print(sdk_str)
    sys.exit(0)

if mode == "xcode":
    print(chosen)
    sys.exit(0)

if mode == "xcodes":
    for dev, v in sorted(xcodes.items(), key=lambda kv: kv[1], reverse=True):
        marks = []
        if os.path.realpath(dev) == os.path.realpath(active): marks.append("xcode-select")
        if dev == chosen: marks.append("chosen")
        suffix = ("  <- " + ", ".join(marks)) if marks else ""
        print(f"{dev}  ·  sim SDK iOS {'.'.join(map(str, v))}{suffix}")
    sys.exit(0)

if mode == "switched":
    print("yes" if switched else "no")
    sys.exit(0)

if mode == "toonew":
    for r in sorted(too_new, reverse=True):
        print(label(r))
    sys.exit(0)

if not usable:
    if too_new:
        newest = ".".join(map(str, max(r[0] for r in too_new)))
        sys.exit(
            f"No BUILDABLE simulator matching {os.environ['FILTER']!r}.\n"
            f"  Chosen toolchain: {chosen}\n"
            f"  Its simulator SDK is iOS {sdk_str}, but every matching device runs\n"
            f"  iOS {newest} — newer than the SDK, so `simctl` boots it happily while\n"
            f"  `xcodebuild` reports no eligible destination.\n"
            f"  No other installed Xcode has a high enough SDK either. Either install a\n"
            f"  newer Xcode, or add a runtime this one can reach:\n"
            f"    xcodebuild -downloadPlatform iOS")
    sys.exit(f"No available simulator matching {os.environ['FILTER']!r}. "
             "Create one in Xcode ▸ Window ▸ Devices and Simulators.")

usable.sort(key=lambda r: (r[0], r[1], r[2].lower()), reverse=True)

if mode == "list":
    for r in usable:
        print(label(r))
else:
    best = usable[0]
    print({"udid": best[3], "dest": "id=" + best[3], "name": label(best)}[mode])
PY
}

case "$CMD" in
  udid|dest|name|list|sdk|xcode|xcodes|switched) py "$FILTER" "$CMD" ;;
  doctor)
    echo "== Xcode toolchains =="
    py "" xcodes | sed 's/^/  /'
    echo
    if [ "$(py '' switched)" = "yes" ]; then
      echo "  ⚠️  xcode-select points at an Xcode whose SDK cannot build to the installed"
      echo "      runtimes. sim.sh is using the one marked 'chosen' instead — the GUI works"
      echo "      and only the command line breaks, which is why this looks like a"
      echo "      missing-runtime problem when it is really a toolchain problem."
      echo "      Per-command fix (no password needed):"
      echo "        export DEVELOPER_DIR=\"\$(bash scripts/sim.sh xcode)\""
      echo "      Permanent fix (needs your password, so run it yourself):"
      echo "        sudo xcode-select -s $(py '' xcode)"
      echo
    fi
    echo "  Effective simulator SDK: iOS $(py '' sdk)"
    echo
    echo "== Installed runtimes =="
    xcrun simctl list runtimes | sed -n '2,$p' | sed 's/^/  /'
    echo
    echo "== Buildable devices (newest first) =="
    if py "" list 2>/dev/null | sed 's/^/  /'; then :; else
      echo "  ⛔️ NONE — nothing in this Xcode can be built to a simulator right now."
    fi
    echo
    echo "== Default picks =="
    echo "  iPhone: $(py iPhone name 2>/dev/null || echo '⛔️ none buildable')"
    echo "  iPad:   $(py iPad   name 2>/dev/null || echo '⛔️ none buildable')"
    echo

    toonew=$(py "" toonew 2>/dev/null || true)
    if [ -n "$toonew" ]; then
      echo "⚠️  Bootable but NOT buildable — runtime is newer than this Xcode's SDK:"
      echo "$toonew" | sed 's/^/   /'
      echo "   No installed Xcode has an SDK this high. Either install a newer Xcode, or"
      echo "   add a runtime the current one can reach: xcodebuild -downloadPlatform iOS"
      echo
    fi

    orphans=$(xcrun simctl list devices 2>/dev/null | sed -n '/^-- Unavailable/,$p' | grep -c '(unavailable' || true)
    if [ "${orphans:-0}" -gt 0 ]; then
      echo "⚠️  ${orphans} device(s) stranded by a deleted runtime:"
      xcrun simctl list devices | sed -n '/^-- Unavailable/,$p' | grep '(unavailable' | sed 's/^/   /'
      echo "   These keep their names, so they shadow live devices in name-based matching."
      echo "   Clear with: xcrun simctl delete unavailable"
      echo "   (destructive — also erases those devices' app data, so read the list first)"
      echo
    fi

    dupes=$(xcrun simctl list devices available 2>/dev/null | grep -oE '^\s+[^(]+' | sed 's/ *$//;s/^ *//' | sort | uniq -d || true)
    if [ -n "$dupes" ]; then
      echo "⚠️  Same device name on more than one runtime — name-based -destination is ambiguous:"
      echo "$dupes" | sed 's/^/   /'
      echo
    fi

    if [ -z "$toonew" ] && [ "${orphans:-0}" -eq 0 ] && [ -z "$dupes" ]; then
      echo "✅ Simulator setup is clean."
    fi
    ;;
  *) echo "Usage: sim.sh {udid|dest|name|list|sdk|xcode|doctor} [filter]" >&2; exit 2 ;;
esac
