#!/usr/bin/env python3
"""Legado source-compatibility loop: audit, probe, classify, score, fix one item, verify.

Run with `python3 -I scripts/legado-compat/lc.py COMMAND`. Start every session with `status`;
it prints the next command. The procedure is `.claude/skills/legado-compat/SKILL.md`.

Scripts decide; the model judges. Every decision a rule can make (is a source dead, is a
failure a bridge gap, did a fix regress anything, which item comes next) is made here, from
the audit reports, the logs and the probes, so two agents given the same files reach the same
answer. State lives in `state/` next to this file and is tracked in git. Bulky files (packs,
reports, logs, diagnostic dumps) live in the work directory named in `state/config.json`.

Standard library only. Nothing here runs JavaScript or anything else taken from a site.
"""
import argparse
import collections
import contextlib
import datetime
import fcntl
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STATE = os.path.join(HERE, "state")
RULES_PATH = os.path.join(HERE, "rules.json")
AUDIT_CONFIG = "/tmp/yuedu-source-audit.json"
DIAG_CONFIG = "/tmp/yuedu-source-diag.json"
TEST_RUN_LOCK = "/tmp/yuedu-lc-testrun.lock"
AUDIT_TEST = "yuedu appTests/BookSourceCompatibilityAuditTests"
DIAG_TEST = "yuedu appTests/BookSourceDiagnosticDumpTests"
MAX_ATTEMPTS = 3
CONTROL_LIMIT = 40
COUNTED = {"evidence", "dead"}  # failing sources that still count as usable
PRIORITY = ["regression", "bridge-gap", "js-error", "empty", "http-error", "antibot",
            "interaction", "network", "unknown"]


# ── small helpers ────────────────────────────────────────────────────────────────────────

def die(message, code=2):
    print(f"✗ {message}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def load(path, default=None):
    if not os.path.exists(path):
        if default is None:
            die(f"missing {path}")
        return default
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


@contextlib.contextmanager
def state_lock():
    """One writer at a time: agents in parallel sessions share these files."""
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, ".lock"), "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


@contextlib.contextmanager
def test_config(path, value):
    """Write the config a test reads, run the body, remove the config: one lc test run at a time.

    Each kind of run hands its test a config at one fixed path (AUDIT_CONFIG, DIAG_CONFIG). Two
    diags started together overwrote each other's: on 11-09 diag e5 ran h14's sources and wrote
    nothing, and h14 found its config already removed. The lock is held from the write to the
    removal, so a second run waits for the first instead.
    """
    with open(TEST_RUN_LOCK, "w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("… another lc test run (audit, diag or verify) is in progress; waiting for it", flush=True)
            fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            with open(path, "w") as f:
                json.dump(value, f)
            yield
        finally:
            if os.path.exists(path):
                os.remove(path)
            fcntl.flock(handle, fcntl.LOCK_UN)


def config():
    return load(os.path.join(STATE, "config.json"))


def workdir():
    path = os.path.expanduser(config()["workdir"])
    os.makedirs(path, exist_ok=True)
    return path


def packs():
    return [p["id"] for p in config()["packs"]]


def target(pack):
    return next(p["target"] for p in config()["packs"] if p["id"] == pack)


def rules():
    return load(RULES_PATH)


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True).stdout


def fingerprint():
    """The code an audit or verify ran against: tracked diffs plus untracked sources."""
    dirs = ["Modules", "Targets", "Tests", "Packages", "Resources"]
    digest = hashlib.sha256(git("rev-parse", "HEAD").encode())
    digest.update(git("diff", "HEAD", "--", *dirs).encode())
    for name in sorted(git("ls-files", "--others", "--exclude-standard", "--", *dirs).split("\n")):
        if name and os.path.isfile(os.path.join(ROOT, name)):
            digest.update(name.encode())
            with open(os.path.join(ROOT, name), "rb") as f:
                digest.update(f.read())
    return digest.hexdigest()[:16]


def origin_of(url):
    url = (url or "").strip().split("#")[0].split(",")[0].strip()
    if not re.match(r"https?://", url, re.I):
        return None
    parts = urllib.parse.urlsplit(url)
    return f"{parts.scheme.lower()}://{parts.netloc}" if parts.hostname else None


def listed_sources(pack_path):
    """The pack as the audit lists it: every media type, first source per bookSourceUrl."""
    seen, listed = set(), []
    for source in load(pack_path):
        url = source.get("bookSourceUrl") or ""
        if url and url not in seen:
            seen.add(url)
            listed.append(source)
    return listed


def pack_path(pack):
    return os.path.join(workdir(), f"pack-{pack}.json")


def report_path(pack, round_):
    return os.path.join(workdir(), f"report-{pack}-{round_}.json")


def log_path(pack, round_):
    return os.path.join(workdir(), f"audit-{pack}-{round_}.log")


def recheck_report_path(pack, round_):
    return os.path.join(workdir(), f"report-{pack}-{round_}-recheck.json")


def recheck_log_path(pack, round_):
    return os.path.join(workdir(), f"audit-{pack}-{round_}-recheck.log")


def parse_ref(text):
    """`1330#42` → ("1330", 42)."""
    match = re.fullmatch(r"(\w+)#(\d+)", text.strip())
    if not match:
        die(f"expected PACK#INDEX, got {text!r}")
    return match.group(1), int(match.group(2))


def first_failure(row):
    for stage in row.get("stages", []):
        if stage.get("status") == "fail":
            return stage
    return {}


# ── running tests ────────────────────────────────────────────────────────────────────────

def wait_for_other_builds():
    """Other sessions share this DerivedData and simulator; never start beside their build."""
    announced = False
    while True:
        busy = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0
        if not busy:
            time.sleep(3)
            if subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode != 0:
                return
        if not announced:
            print("… another xcodebuild is running; waiting for it to finish")
            announced = True
        time.sleep(15)


def xctest(log, only, timeout):
    """scripts/xctest.sh, which stops at the verdict. Returns (passed, verdict line)."""
    wait_for_other_builds()
    bundle = log[:-4] + "-" + time.strftime("%H%M%S") + ".xcresult"
    command = ["bash", os.path.join(ROOT, "scripts/xctest.sh"), "-l", log, "-t", str(timeout), "--",
               "-resultBundlePath", bundle] + [f"-only-testing:{name}" for name in only]
    print("$ " + " ".join(shlex.quote(c) for c in command))
    subprocess.run(command, cwd=ROOT)
    verdict = ""
    if os.path.exists(log):
        with open(log, errors="replace") as f:
            for line in f:
                if "Test run with" in line or "** TEST " in line:
                    verdict = line.strip()
    passed = "passed" in verdict and "failed" not in verdict or verdict == "** TEST SUCCEEDED **"
    return passed, verdict


def run_audit(pack_file, report, log, timeout, indices=None):
    stamped = report[:-5] + "-pack.json"
    sources = load(pack_file)
    stamp = int(time.time() * 1000)
    for source in sources:
        # A fresh lastUpdateTime per run, so no cached result from an earlier run answers.
        source["lastUpdateTime"] = stamp
    save(stamped, sources)
    audit = {"pack": stamped, "limit": 100000, "sourceTypes": [], "reportPath": report,
             "cancelInteractiveRequests": True, "unpaced": True}
    if indices is not None:
        audit["indices"] = sorted(indices)
    with test_config(AUDIT_CONFIG, audit):
        passed, verdict = xctest(log, [AUDIT_TEST], timeout)
    if not os.path.exists(report):
        die(f"the audit wrote no report ({verdict or 'no verdict'}); read {log}")
    data = load(report)
    print(f"  {os.path.basename(report)}: completed {data['completedCount']}/{data['expectedCount']}, "
          f"passed {data['passedCount']}  [{verdict}]")
    if data["completedCount"] != data["expectedCount"]:
        die(f"the audit stopped early; read {log}")
    return data


# ── logs: JavaScript exceptions per source ──────────────────────────────────────────────

EXCEPTION_LINE = re.compile(r"^\[ERROR\] Book source rule JS exception \| \[(?P<ctx>.*)\]\s*$")


def exceptions_by_source(log, sources):
    """{bookSourceUrl: [message, …]} from an audit log.

    Logs written since 2026-11-08 carry `sourceUrl=`. Older ones name the source only, and a
    pack repeats names, so a name is attributed to every source that carries it, and the
    message is marked ambiguous.
    """
    by_name = collections.defaultdict(list)
    for source in sources:
        by_name[source.get("bookSourceName", "")].append(source["bookSourceUrl"])
    found = collections.defaultdict(list)
    if not os.path.exists(log):
        return found
    with open(log, errors="replace") as f:
        for line in f:
            match = EXCEPTION_LINE.match(line)
            if not match:
                continue
            ctx = match.group("ctx")
            url_at = ctx.rfind(" sourceUrl=")
            if url_at >= 0:
                url = ctx[url_at + len(" sourceUrl="):]
                ctx = ctx[:url_at]
            else:
                url = None
            name_at = ctx.rfind(" source=")
            if not ctx.startswith("error=") or name_at < 0:
                continue
            message, name = ctx[len("error="):name_at], ctx[name_at + len(" source="):]
            if url:
                found[url].append(message)
            else:
                for candidate in by_name.get(name, []):
                    found[candidate].append(message + ("  [name shared by several sources]"
                                                        if len(by_name[name]) > 1 else ""))
    return found


def signature(message, rule_set, rejected):
    """The bridge gap a JavaScript exception names, or None.

    Only a positive match counts: a call to a method that exists on a Java or jsoup object in
    Legado (`X is not a function`), a Legado global that is not bound, or a Legado API our
    runtime reports as unsupported. `null is not an object` and the like are not gaps.
    """
    found = None
    match = re.search(r"TypeError: (?P<expr>.+?) is not a function", message)
    if match:
        expr = match.group("expr")
        if expr == "undefined":
            near = re.search(r"near '\.\.\.(?P<near>[^']*?)\.\.\.'", message)
            expr = near.group("near") if near else ""
        name = re.search(r"([A-Za-z_$][\w$]*)\s*$", expr)
        if name and "." in expr and name.group(1) in rule_set["methods"]:
            found = "method:" + name.group(1)
        elif name and "." not in expr and name.group(1) in rule_set["globals"]:
            found = "global:" + name.group(1)
    match = re.search(r"UnsupportedLegadoAPIError: (?P<api>Packages\.[\w.$]+)", message)
    if match:
        found = "api:" + match.group("api")
    match = re.search(r"ReferenceError: Can't find variable: (?P<name>[\w$]+)", message)
    if match and match.group("name") in rule_set["globals"]:
        found = "global:" + match.group("name")
    if found in rejected:
        return None
    return found


# ── probes ──────────────────────────────────────────────────────────────────────────────

def probe_path(round_, region):
    return os.path.join(workdir(), f"probe-{region}-{round_}.json")


def load_probes(round_):
    """({origin: verdict} local, {origin: verdict} remote or None)."""
    local = probe_path(round_, "local")
    remote = probe_path(round_, "remote")
    to_map = lambda path: {row["origin"]: row["verdict"] for row in load(path)}
    return (to_map(local) if os.path.exists(local) else None,
            to_map(remote) if os.path.exists(remote) else None)


def cmd_probe(args):
    origins = set()
    for pack in packs():
        if not os.path.exists(report_path(pack, args.round)):
            continue
        for row in load(report_path(pack, args.round))["results"]:
            if not row["passed"]:
                origin = origin_of(row["sourceIdentifier"])
                if origin:
                    origins.add(origin)
    if not origins:
        die(f"no failing source with an http(s) origin in round {args.round}")
    listing = os.path.join(workdir(), f"probe-origins-{args.round}.json")
    save(listing, sorted(origins))
    script = os.path.join(HERE, "probe.py")
    print(f"probing {len(origins)} origins locally …")
    subprocess.run([sys.executable, "-I", script, listing, probe_path(args.round, "local")], check=True)
    summarize_probe(probe_path(args.round, "local"))
    remote = config().get("remoteProbe")
    if not remote:
        print("no remoteProbe in config.json: scores stay provisional")
        return
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
           "-i", os.path.expanduser(remote["identity"]), remote["host"]]
    print(f"probing {len(origins)} origins from {remote['host']} …")
    try:
        with open(script, "rb") as f:
            subprocess.run(ssh + ["mkdir -p /tmp/lc-probe && cat > /tmp/lc-probe/probe.py"],
                           stdin=f, check=True, timeout=60)
        with open(listing, "rb") as f:
            subprocess.run(ssh + ["cat > /tmp/lc-probe/origins.json"], stdin=f, check=True, timeout=60)
        out = subprocess.run(ssh + ["python3 -I /tmp/lc-probe/probe.py /tmp/lc-probe/origins.json"],
                             capture_output=True, check=True, timeout=1800)
        rows = json.loads(out.stdout)
    except (subprocess.SubprocessError, ValueError) as error:
        die(f"remote probe failed ({error}); scores for {args.round} stay provisional until it runs")
    save(probe_path(args.round, "remote"), rows)
    summarize_probe(probe_path(args.round, "remote"))


def summarize_probe(path):
    counts = collections.Counter(row["verdict"] for row in load(path))
    print(f"  {os.path.basename(path)}: " + ", ".join(f"{k} {v}" for k, v in counts.most_common()))


# ── classification ──────────────────────────────────────────────────────────────────────

def classify_round(round_):
    """Every failing source of every pack in `round_` gets exactly one class."""
    rule_set = rules()
    evidence = load(os.path.join(STATE, "evidence.json"), {"entries": []})["entries"]
    ledger = load(os.path.join(STATE, "ledger.json"), {"items": {}})
    rejected = {item["signature"] for item in ledger["items"].values()
                if item.get("status") == "rejected" and item.get("signature")}
    history = load(os.path.join(STATE, "history.json"), {"rounds": []})["rounds"]
    earlier = [r for r in history if r["round"] != round_][-3:]
    local, remote = load_probes(round_)
    patterns = {k: re.compile(v, re.I) for k, v in rule_set["patterns"].items()}
    active_evidence = {(e["pack"], e["url"]): e for e in evidence if e.get("status", "active") == "active"}
    out = {"round": round_, "classifiedAt": now(), "provisional": remote is None,
           "probes": {"local": local is not None, "remote": remote is not None}, "packs": {}}
    for pack in packs():
        path = report_path(pack, round_)
        if not os.path.exists(path):
            continue
        report = load(path)
        sources = listed_sources(pack_path(pack))
        exceptions = exceptions_by_source(log_path(pack, round_), sources)
        interactive = {r.get("sourceURL") for r in report.get("interactionRequests", [])}
        # `lc recheck`: the round's network failures audited once more on the same code. Its row
        # replaces the first one, and its log the first log, for those sources only.
        recheck = load(recheck_report_path(pack, round_), {"results": []})
        rechecked = {r["index"]: r for r in recheck["results"]}
        recheck_exceptions = (exceptions_by_source(recheck_log_path(pack, round_), sources)
                              if rechecked else {})
        interactive |= {r.get("sourceURL") for r in recheck.get("interactionRequests", [])}
        rows, passed, passed_on_recheck = [], 0, 0
        for row in report["results"]:
            again = rechecked.get(row["index"]) if not row["passed"] else None
            if again is not None:
                row = again
            url = row["sourceIdentifier"]
            if row["passed"]:
                passed += 1
                passed_on_recheck += again is not None
                continue
            stage = first_failure(row)
            text = " ".join([stage.get("summary", ""), row.get("apiError", "")])
            messages = (recheck_exceptions if again is not None else exceptions).get(url, [])
            signatures = sorted({s for s in (signature(m, rule_set, rejected) for m in messages) if s})
            origin = origin_of(url)
            verdicts = [(local or {}).get(origin), (remote or {}).get(origin)]
            dead = (local is not None and remote is not None
                    and all(v in rule_set["deadVerdicts"] for v in verdicts)
                    and bool(patterns["network"].search(text) or patterns["http"].search(text)))
            was_passing = sum(1 for r in earlier if url in r["packs"].get(pack, {}).get("passed", []))
            if (pack, url) in active_evidence:
                cls = "evidence"
            elif dead:
                cls = "dead"
            elif signatures:
                cls = "bridge-gap"
            elif url in interactive or patterns["interaction"].search(text + " ".join(messages)):
                cls = "interaction"
            elif patterns["antibot"].search(text + " ".join(messages)):
                cls = "antibot"
            elif patterns["network"].search(text):
                cls = "network"
            elif patterns["http"].search(text):
                cls = "http-error"
            elif row.get("failureCategory") == "jsError" or messages:
                cls = "js-error"
            elif row.get("failureCategory") in ("tocEmpty", "contentEmpty", "searchFailed",
                                                "discoveryFailed"):
                cls = "empty"
            else:
                cls = "unknown"
            regression = (was_passing >= 2 and cls not in ("evidence", "dead", "network")
                          and verdicts[0] not in rule_set["deadVerdicts"])
            rows.append({
                "index": row["index"], "url": url, "name": row["sourceName"], "class": cls,
                "regression": regression, "passedEarlier": was_passing,
                "signatures": signatures, "stage": stage.get("stage", ""),
                "summary": stage.get("summary", "")[:200], "apiError": row.get("apiError", "")[:200],
                "category": row.get("failureCategory", ""), "probe": verdicts,
                "messages": sorted(set(messages))[:5], "rechecked": again is not None,
            })
        counted = sum(1 for r in rows if r["class"] in COUNTED)
        out["packs"][pack] = {
            "audited": report["expectedCount"], "passed": passed, "passedOnRecheck": passed_on_recheck,
            "rechecked": len(rechecked), "usable": passed + counted,
            "target": target(pack), "classes": dict(collections.Counter(r["class"] for r in rows)),
            "failures": rows,
        }
    return out


def classified_path(round_):
    return os.path.join(workdir(), f"classified-{round_}.json")


def cmd_classify(args):
    result = classify_round(args.round)
    if not result["packs"]:
        die(f"no reports for round {args.round} in {workdir()}")
    with state_lock():
        save(classified_path(args.round), result)
        record_round(args.round)
        sync_ledger(result)
        retire_evidence(result)
    print_score(result)
    print(f"\nwrote {classified_path(args.round)}; next: python3 -I scripts/legado-compat/lc.py next")


def print_score(result):
    flag = "  (PROVISIONAL: no remote probe — dead sources are not counted)" if result["provisional"] else ""
    print(f"round {result['round']}{flag}")
    for pack, data in result["packs"].items():
        dead = data["classes"].get("dead", 0)
        evidence = data["classes"].get("evidence", 0)
        mark = "✓" if data["usable"] >= data["target"] else "✗"
        print(f"  {mark} {pack}: usable {data['usable']}/{data['audited']} (target {data['target']}) = "
              f"passed {data['passed']} + dead {dead} + evidence {evidence}")
        if data.get("rechecked"):
            print(f"      recheck: {data['rechecked']} network failures audited again, "
                  f"{data.get('passedOnRecheck', 0)} passed (counted in passed)")
        rest = {k: v for k, v in data["classes"].items() if k not in COUNTED}
        if rest:
            print("      open: " + ", ".join(f"{k} {v}" for k, v in sorted(rest.items(), key=lambda kv: -kv[1])))


def cmd_score(args):
    path = classified_path(args.round)
    if not os.path.exists(path):
        die(f"round {args.round} is not classified; run: lc.py classify {args.round}")
    print_score(load(path))


def record_round(round_):
    """Passing sources per pack, kept for the regression rule (passed in ≥2 earlier rounds)."""
    path = os.path.join(STATE, "history.json")
    history = load(path, {"rounds": []})
    entry = {"round": round_, "recordedAt": now(), "packs": {}}
    for pack in packs():
        if os.path.exists(report_path(pack, round_)):
            rows = load(report_path(pack, round_))["results"]
            rechecked = load(recheck_report_path(pack, round_), {"results": []})["results"]
            passing = {r["sourceIdentifier"] for r in rows + rechecked if r["passed"]}
            entry["packs"][pack] = {"audited": len(rows), "passed": sorted(passing)}
    meta = load(os.path.join(workdir(), f"round-{round_}.json"), {})
    entry["fingerprint"] = meta.get("fingerprint", "")
    history["rounds"] = [r for r in history["rounds"] if r["round"] != round_] + [entry]
    history["rounds"] = history["rounds"][-6:]
    save(path, history)


def cmd_record(args):
    with state_lock():
        record_round(args.round)
    print(f"recorded {args.round} in state/history.json")


# ── ledger ──────────────────────────────────────────────────────────────────────────────

def ledger_path():
    return os.path.join(STATE, "ledger.json")


def item_priority(item):
    rank = PRIORITY.index(item["class"]) if item["class"] in PRIORITY else len(PRIORITY)
    return (rank, -len(item["sources"]), item["id"])


def sync_ledger(result):
    """Items from a classified round. Done and blocked items keep their status unless the gap
    they claimed to fix shows up again, which reopens them."""
    ledger = load(ledger_path(), {"items": {}})
    items = ledger["items"]
    wanted = {}
    clusters = collections.defaultdict(list)
    for pack, data in result["packs"].items():
        for row in data["failures"]:
            ref = {"pack": pack, "index": row["index"], "url": row["url"], "name": row["name"]}
            if row["class"] == "bridge-gap":
                for sig in row["signatures"]:
                    clusters[sig].append(ref)
            elif row["regression"]:
                wanted[f"regression:{pack}#{row['index']}"] = ("regression", None, [ref])
            elif row["class"] not in COUNTED:
                wanted[f"{row['class']}:{pack}#{row['index']}"] = (row["class"], None, [ref])
    for sig, refs in clusters.items():
        wanted[f"bridge:{sig}"] = ("bridge-gap", sig, refs)
    # A round audited before an item closed says nothing about the fix: only a later round
    # reopens it. Rounds from before lc.py have no start time and never reopen anything.
    started = load(os.path.join(workdir(), f"round-{result['round']}.json"), {}).get("startedAt", "")
    for item_id, (cls, sig, refs) in wanted.items():
        item = items.get(item_id)
        if item is None:
            items[item_id] = {"id": item_id, "class": cls, "signature": sig, "sources": refs,
                              "status": "todo", "openedIn": result["round"], "attempts": [],
                              "notes": []}
            continue
        item["sources"] = refs
        closed = item.get("doneAt") if item["status"] == "done" else item.get("closedAt")
        if item["status"] in ("done", "resolved", "skipped") and started and closed and started > closed:
            item["status"] = "todo"
            item["notes"].append(f"{now()} reopened: still failing in {result['round']}")
    for item_id, item in items.items():
        if item_id not in wanted and item["status"] in ("todo", "in_progress") and not item.get("manual"):
            item["status"] = "resolved"
            item["closedAt"] = now()
            item["notes"].append(f"{now()} no longer failing this way in {result['round']}")
    ledger["round"] = result["round"]
    save(ledger_path(), ledger)


def retire_evidence(result):
    """Evidence is for failing sources only: once a source passes, its entry retires."""
    path = os.path.join(STATE, "evidence.json")
    data = load(path, {"entries": []})
    failing = {(pack, row["url"]) for pack, d in result["packs"].items() for row in d["failures"]}
    audited = {pack for pack in result["packs"]}
    changed = 0
    for entry in data["entries"]:
        if entry.get("status", "active") == "active" and entry["pack"] in audited \
                and (entry["pack"], entry["url"]) not in failing:
            entry["status"] = "retired"
            entry["retiredIn"] = result["round"]
            changed += 1
    if changed:
        save(path, data)
        print(f"retired {changed} evidence entries whose sources now pass")


def find_item(item_id):
    ledger = load(ledger_path(), {"items": {}})
    if item_id not in ledger["items"]:
        die(f"no item {item_id!r}; list them with: lc.py items")
    return ledger, ledger["items"][item_id]


def cmd_items(args):
    ledger = load(ledger_path(), {"items": {}})
    rows = sorted(ledger["items"].values(), key=item_priority)
    shown = [i for i in rows if args.status in (None, i["status"])]
    for item in shown[: args.limit]:
        print(f"{item['status']:11s} {item['id']:48s} {len(item['sources']):3d} source(s)")
    print(f"{len(shown)} item(s)" + (f", first {args.limit} shown" if len(shown) > args.limit else ""))


def current_round():
    ledger = load(ledger_path(), {"items": {}})
    return ledger.get("round")


def cmd_next(args):
    with state_lock():
        ledger = load(ledger_path(), {"items": {}})
        busy = [i for i in ledger["items"].values() if i["status"] == "in_progress"]
        if busy:
            print(f"✗ {busy[0]['id']} is already in progress. Finish it (lc.py verify / done) "
                  f"or block it (lc.py block ID --reason ...). One item at a time.")
            show_item(busy[0])
            sys.exit(1)
        todo = sorted((i for i in ledger["items"].values() if i["status"] == "todo"), key=item_priority)
        if not todo:
            print("no open item. Run a new round: lc.py audit ROUND, then probe and classify.")
            return
        item = todo[0]
        item["status"] = "in_progress"
        item["startedAt"] = now()
        item["owner"] = args.owner
        save(ledger_path(), ledger)
    show_item(item)


def show_item(item):
    round_ = current_round()
    classified = load(classified_path(round_), {}) if round_ else {}
    print(f"ITEM  {item['id']}  [{item['status']}]  class={item['class']}  sources={len(item['sources'])}")
    if item.get("signature"):
        print(f"SIGNATURE  {item['signature']}")
    for ref in item["sources"][:12]:
        row = next((r for r in classified.get("packs", {}).get(ref["pack"], {}).get("failures", [])
                    if r["url"] == ref["url"]), {})
        print(f"  {ref['pack']}#{ref['index']}  {ref['name']}  {ref['url']}")
        if row:
            print(f"      {row['stage']}: {row['summary'][:150]}")
            if row.get("apiError"):
                print(f"      api: {row['apiError'][:150]}")
            for message in row.get("messages", [])[:2]:
                print(f"      js: {message[:180]}")
    if len(item["sources"]) > 12:
        print(f"  … and {len(item['sources']) - 12} more (lc.py show {item['id']} --all)")
    for attempt in item.get("attempts", [])[-3:]:
        print(f"  attempt {attempt['n']}: {attempt['gate']} — {attempt['detail'][:200]}")
    for note in item.get("notes", [])[-3:]:
        print(f"  note: {note[:200]}")
    card = rules()["workCards"].get(item["class"], [])
    if card:
        print("WHAT TO DO")
        for i, step in enumerate(card, 1):
            print(f"  {i}. {step.format(id=item['id'], ref=ref_text(item))}")


def ref_text(item):
    ref = item["sources"][0]
    return f"{ref['pack']}#{ref['index']}"


def cmd_show(args):
    _, item = find_item(args.item)
    if args.all:
        for ref in item["sources"]:
            print(f"{ref['pack']}#{ref['index']}\t{ref['name']}\t{ref['url']}")
        return
    show_item(item)


def cmd_block(args):
    with state_lock():
        ledger, item = find_item(args.item)
        item["status"] = "blocked"
        item["notes"].append(f"{now()} blocked: {args.reason}")
        save(ledger_path(), ledger)
    print(f"blocked {args.item}. Tell the user why; then: lc.py next")


def cmd_release(args):
    """Put the item in progress back in line, untouched: for a fix found while working on
    another item (`add`), which `next` then takes by priority. Not for giving up: that is
    `block`, with the reason."""
    with state_lock():
        ledger, item = find_item(args.item)
        if item["status"] != "in_progress":
            die(f"{args.item} is {item['status']}; only the item in progress is released")
        item["status"] = "todo"
        item["notes"].append(f"{now()} released: {args.reason}")
        save(ledger_path(), ledger)
    print(f"released {args.item}; it is todo again. To take a particular item: lc.py take ITEM")


def cmd_expect(args):
    """Give the item in progress `add --expect`'s criterion after the fact: its sources are met
    when they fail with Legado's own failure. For a fix whose source fails on something Legado
    fails on too — bridge:regex-unmatched-group (11-09): 起点中文 1331#370's search meets
    起点's 202 probe.js wall, which Legado's resend gets as well, so the source passes neither
    before nor after. The criterion holds before the fix too: the unit tests and the controls
    are what judge it, and the report says so."""
    with state_lock():
        ledger, item = find_item(args.item)
        if item["status"] != "in_progress":
            die(f"{args.item} is {item['status']}; only the item in progress gets a criterion")
        if len(args.legado.strip()) < 15:
            die("--legado must say where Legado fails the same way (file:line, what it gets)")
        try:
            re.compile(args.regex)
        except re.error as error:
            die(f"--regex: {error}")
        item["expectFailure"] = args.regex
        item["notes"].append(f"{now()} expects {args.regex!r}: {args.legado}")
        save(ledger_path(), ledger)
    print(f"{args.item} is met when its sources pass or fail matching {args.regex!r}. "
          "That holds before the fix too: the unit tests and the controls judge it.")


def cmd_unblock(args):
    """A blocked item whose last verification failed only on controls, each of which a diag on
    the same code shows passing (a flake) or failing on what the site answers. Those controls
    are excused for this item and it gets one more verification; a fourth failure blocks it
    again. The case (11-09): bridge:java-byte-sign fixed 西瓜免费 and passed its tests, and its
    one regression was 1330#25 番茄漫画, whose first search result had been withdrawn since the
    baseline round (book page 404, content API code 1021001). Not for a control our code breaks:
    then the hunks are reverted."""
    fp = fingerprint()
    with state_lock():
        ledger, item = find_item(args.item)
        if item["status"] != "blocked":
            die(f"{args.item} is {item['status']}; only a blocked item is unblocked")
        busy = [i for i in ledger["items"].values() if i["status"] == "in_progress"]
        if busy:
            die(f"{busy[0]['id']} is in progress; finish, block or release it first")
        last = item["attempts"][-1] if item["attempts"] else None
        if not last or last["gate"] != "FAIL":
            die(f"{args.item} has no failed verification to look at")
        # The diag must be on this code; the failed verification need not be (another session's
        # commit moves the fingerprint). The verification `unblock` grants runs on this code too.
        detail = last.get("detail", "")
        if item["class"] == "bridge-gap" and "unit tests: ** TEST SUCCEEDED **" not in detail:
            die("the unit tests did not pass in that verification: fix that, it is not the site")
        own = re.search(r"item sources [^;]*?(\d+)/(\d+)", detail)
        if not own or own.group(1) != own.group(2):
            die("not every item source passed in that verification: the fix is not done")
        still = re.search(r"still raising [^;]*: (\d+)", detail)
        if still and still.group(1) != "0":
            die("an item source still raises the signature: the fix is not done")
        regressed = re.search(r"REGRESSED: (.*)$", detail)
        if not regressed:
            die("that verification did not fail on a control")
        refs = []
        for piece in regressed.group(1).split(" | "):
            m = re.match(r"(\S+?)#(\d+) ", piece)
            if not m:
                die(f"cannot read the regressed control in {piece[:80]!r}")
            refs.append((m.group(1), int(m.group(2))))
        excuses = []
        for pack, index in refs:
            meta = load(diag_meta_path(args.diag, pack), {})
            if meta.get("fingerprint") != fp:
                die(f"diag {args.diag} for pack {pack} did not run on this code "
                    f"({meta.get('fingerprint') or 'no fingerprint recorded'}); run: "
                    f"lc.py diag {args.diag} {pack}#{index}")
            url = listed_sources(pack_path(pack))[index]["bookSourceUrl"]
            directory, rows = diag_rows(args.diag, pack)
            row = rows.get(url)
            if row is None:
                die(f"no dump for {pack}#{index} in {directory}; run: lc.py diag {args.diag} {pack}#{index}")
            entry = {"pack": pack, "index": index, "url": url, "diag": directory,
                     "passedInDiag": bool(row.get("passed")), "at": now()}
            if not row.get("passed"):
                seen = observed(row)
                if not seen:
                    die(f"{pack}#{index}: the dump recorded no response or error to point at")
                if not args.proof or len(args.legado or "") < 15:
                    die(f"{pack}#{index} fails in the diag too: give --proof (what the site answered) "
                        "and --legado (why Legado fails on the same input)")
                entry.update({"observed": seen, "proof": args.proof, "legado": args.legado})
            excuses.append(entry)
        item.setdefault("excusedControls", []).extend(excuses)
        item["status"] = "in_progress"
        item["notes"].append(f"{now()} unblocked: {args.reason} (excused "
                             + ", ".join(f"{p}#{i}" for p, i in refs) + f" by diag {args.diag})")
        save(ledger_path(), ledger)
    print(f"unblocked {args.item}: " + ", ".join(f"{p}#{i}" for p, i in refs)
          + f" excused. One more verification: lc.py verify {args.item} --tests '…'")


def cmd_take(args):
    """Take one named todo item, when nothing is in progress: the fix for it is already
    written (found while investigating another source, then `add`ed)."""
    with state_lock():
        ledger = load(ledger_path(), {"items": {}})
        busy = [i for i in ledger["items"].values() if i["status"] == "in_progress"]
        if busy:
            die(f"{busy[0]['id']} is in progress; finish, block or release it first")
        if args.item not in ledger["items"]:
            die(f"no item {args.item}")
        item = ledger["items"][args.item]
        if item["status"] != "todo":
            die(f"{args.item} is {item['status']}; only a todo item is taken")
        item["status"] = "in_progress"
        item["startedAt"] = now()
        item["owner"] = args.owner
        save(ledger_path(), ledger)
    show_item(item)


def cmd_skip(args):
    with state_lock():
        ledger, item = find_item(args.item)
        if item["class"] == "regression" or (args.diag and item["class"] != "bridge-gap"):
            # A failure that passes again on the code it failed on was the network or the site
            # that round (r10: six of seven 1330 regressions passed a diag an hour later; r11: a
            # one-off HTTP 400 that 台湾小说's loginCheckJs rethrew as a script error, so the
            # class said js-error). Only a diag on this code that passes every one of its
            # sources shows that. A bridge gap closes through verify and done, never this way.
            if not args.diag:
                die("a regression is skipped only with --diag TAG: a diag on this code in which "
                    "every one of its sources passes")
            for ref in item["sources"]:
                _, rows = diag_rows(args.diag, ref["pack"])
                if not rows.get(ref["url"], {}).get("passed"):
                    die(f"{ref['pack']}#{ref['index']} did not pass in diag {args.diag}: "
                        f"find what broke it (lc.py show {args.item})")
            args.reason += f" (diag {args.diag} passed on this code)"
        elif item["class"] not in ("network", "unknown"):
            die("only network noise is skipped without --diag; other classes end in evidence, a "
                "fix, block, or skip --diag TAG with a diag on this code in which every source passes")
        item["status"] = "skipped"
        item["closedAt"] = now()
        item["notes"].append(f"{now()} skipped: {args.reason}")
        save(ledger_path(), ledger)
    print(f"skipped {args.item} for round {current_round()}; it reopens if it fails again. next: lc.py next")


def cmd_reject(args):
    with state_lock():
        ledger, item = find_item(args.item)
        if item["class"] != "bridge-gap":
            die("only a bridge-gap cluster can be rejected; for one source, add evidence or block it")
        if len(args.legado) < 20:
            die("--legado must say where in Legado's source the same call fails too (file and line)")
        item["status"] = "rejected"
        item["notes"].append(f"{now()} rejected: Legado fails the same way: {args.legado}")
        save(ledger_path(), ledger)
    print(f"rejected {args.item}: its sources become js-error items at the next classify")


def cmd_add(args):
    if not re.fullmatch(r"bridge:[\w:.$-]+", args.item):
        die("a manual item is a bridge gap: bridge:<short-name>")
    refs = []
    classified = load(classified_path(current_round()), {})
    for text in args.sources.split(","):
        pack, index = parse_ref(text)
        row = next((r for r in classified.get("packs", {}).get(pack, {}).get("failures", [])
                    if r["index"] == index), None)
        if row is None:
            die(f"{pack}#{index} is not failing in round {current_round()}")
        refs.append({"pack": pack, "index": index, "url": row["url"], "name": row["name"]})
    with state_lock():
        ledger = load(ledger_path(), {"items": {}})
        if args.item in ledger["items"]:
            die(f"{args.item} exists")
        ledger["items"][args.item] = {
            "id": args.item, "class": "bridge-gap", "signature": None, "manual": True,
            "controlPattern": args.controls, "expectFailure": args.expect, "sources": refs, "status": "todo",
            "openedIn": current_round(), "attempts": [], "notes": [f"{now()} added: {args.why}"]}
        for ref in refs:
            for other in ledger["items"].values():
                if other["id"] != args.item and other["status"] in ("todo", "in_progress") \
                        and any(s["url"] == ref["url"] for s in other["sources"]) and len(other["sources"]) == 1:
                    other["status"] = "resolved"
                    other["closedAt"] = now()
                    other["notes"].append(f"{now()} moved into {args.item}")
        save(ledger_path(), ledger)
    print(f"added {args.item}; it is next in line after regressions and larger gaps")


# ── verify and done ─────────────────────────────────────────────────────────────────────

def control_pattern(item):
    if item.get("controlPattern"):
        return re.compile(item["controlPattern"])
    sig = item.get("signature") or ""
    kind, _, name = sig.partition(":")
    if kind == "method":
        return re.compile(r"\." + re.escape(name) + r"\s*\(")
    if kind == "global":
        return re.compile(r"\b" + re.escape(name) + r"\b")
    if kind == "api":
        return re.compile(re.escape(name))
    return None


def cmd_verify(args):
    # `--tests` may be repeated and each may hold a comma-separated list: a second `--tests`
    # once replaced the first, and its suite silently never ran.
    args.tests = ",".join(args.tests) if args.tests else None
    ledger, item = find_item(args.item)
    if item["status"] != "in_progress":
        die(f"{args.item} is {item['status']}; only the item in progress is verified")
    if item["class"] == "bridge-gap" and not args.tests:
        die("a bridge fix needs a unit test that asserts the oracle's value: --tests 'yuedu appTests/Class'")
    round_ = current_round()
    attempt = len(item["attempts"]) + 1
    tag = re.sub(r"[^\w.-]+", "_", args.item)[:60] + f"-v{attempt}"
    fp = fingerprint()
    details = []
    gate = "PASS"
    if args.tests:
        names = [t.strip() for t in args.tests.split(",") if t.strip()]
        ok, verdict = xctest(os.path.join(workdir(), f"verify-{tag}-unit.log"), names, 1800)
        details.append(f"unit tests: {verdict or 'no verdict'}")
        if not ok:
            gate = "FAIL"
    if gate == "PASS":
        gate, more = verify_by_audit(item, round_, tag)
        details += more
    detail = "; ".join(details)
    with state_lock():
        ledger, item = find_item(args.item)
        item["attempts"].append({"n": attempt, "at": now(), "gate": gate, "fingerprint": fp,
                                 "tests": args.tests or "", "detail": detail})
        if gate == "FAIL" and len([a for a in item["attempts"] if a["gate"] == "FAIL"]) >= MAX_ATTEMPTS:
            item["status"] = "blocked"
            item["notes"].append(f"{now()} blocked after {MAX_ATTEMPTS} failed verifications")
        save(ledger_path(), ledger)
    print(f"\nGATE {gate}: {detail}")
    if gate == "PASS":
        print(f"next: lc.py done {args.item}   (do not edit code before it, or the fingerprint changes)")
    elif item["status"] == "blocked":
        print("BLOCKED. If the unit tests and every item source passed and only controls failed, diag "
              "those controls on this code (lc.py diag TAG PACK#INDEX): when each passes, or fails on "
              "what the site answers, lc.py unblock ITEM --diag TAG --reason '…' (with --proof and "
              "--legado for one that fails). Otherwise revert only your own hunks by hand (Edit), "
              "report to the user, then lc.py next.")
    else:
        print(f"fix it and verify again ({MAX_ATTEMPTS - attempt} attempt(s) left before it blocks)")


def verify_by_audit(item, round_, tag):
    """Re-audit the item's sources and passing sources that use the same API (controls)."""
    classified = load(classified_path(round_))
    history = load(os.path.join(STATE, "history.json"), {"rounds": []})["rounds"]
    last = next((r for r in reversed(history) if r["round"] == round_), None)
    targets = {ref["url"]: ref for ref in item["sources"]}
    controls = {}
    pattern = control_pattern(item)
    # Controls `unblock` excused for this item: a diag on the code showed them failing at the site.
    excused = {(e["pack"], e["index"]) for e in item.get("excusedControls", [])}
    # By (pack, index): one URL can be two definitions in two packs (1330#109 and 1331's 晋江
    # share https://m.jjwxc.net/channel/). Keyed by URL, the first pack's copy was audited as
    # the control that passed in another pack — 1330#109 and #128, which never passed, came
    # back as regressions (11-08).
    pool = {}
    for pack in packs():
        sources = listed_sources(pack_path(pack))
        passing = set((last or {}).get("packs", {}).get(pack, {}).get("passed", []))
        for index, source in enumerate(sources):
            url = source["bookSourceUrl"]
            pool[(pack, index)] = source
            if pattern and url in passing and url not in targets and url not in controls \
                    and (pack, index) not in excused \
                    and len(controls) < CONTROL_LIMIT and pattern.search(json.dumps(source, ensure_ascii=False)):
                controls[url] = (pack, index)
    target_refs = {url: (ref["pack"], ref["index"]) for url, ref in targets.items()}
    mini = [pool[target_refs[url]] for url in targets if target_refs[url] in pool] \
        + [pool[controls[url]] for url in controls]
    mini_pack = os.path.join(workdir(), f"verify-{tag}-sources.json")
    save(mini_pack, mini)
    report = os.path.join(workdir(), f"verify-{tag}.json")
    log = os.path.join(workdir(), f"verify-{tag}.log")
    print(f"auditing {len(targets)} item source(s) and {len(controls)} control(s) …")
    data = run_audit(mini_pack, report, log, 3600)
    rule_set = rules()
    rejected = set()
    exceptions = exceptions_by_source(log, mini)
    results = {row["sourceIdentifier"]: row for row in data["results"]}
    noise = re.compile(rule_set["patterns"]["network"], re.I)
    details, gate = [], "PASS"
    still = [url for url in targets
             if item.get("signature") and any(signature(m, rule_set, rejected) == item["signature"]
                                               for m in exceptions.get(url, []))]
    # An item that aligns how a source fails (`add --expect`) is met when the source fails
    # with Legado's own error: 棉花糖's `java.webView` page never finishes loading, and the fix
    # is that it raises Legado's timeout instead of handing the script an empty page.
    expect = re.compile(item["expectFailure"]) if item.get("expectFailure") else None

    def target_met(url):
        row = results.get(url, {})
        if row.get("passed"):
            return True
        stage = first_failure(row)
        return bool(expect and expect.search(stage.get("summary", "") + " " + row.get("apiError", "")))

    passed_targets = [url for url in targets if target_met(url)]
    details.append(f"item sources {'passing or failing as Legado does' if expect else 'passing'} "
                   f"{len(passed_targets)}/{len(targets)}")
    if item.get("signature"):
        details.append(f"still raising {item['signature']}: {len(still)}")
        if still:
            gate = "FAIL"
    elif len(passed_targets) < len(targets):
        gate = "FAIL"
    broke, noisy = [], []
    for url in controls:
        row = results.get(url, {})
        if row.get("passed"):
            continue
        stage = first_failure(row)
        text = stage.get("summary", "") + " " + row.get("apiError", "")
        (noisy if noise.search(text) else broke).append(
            f"{controls[url][0]}#{controls[url][1]} {stage.get('stage', '?')}: {stage.get('summary', '')[:80]}")
    details.append(f"controls passing {len(controls) - len(broke) - len(noisy)}/{len(controls)}")
    if excused:
        details.append("excused by unblock (not audited): "
                       + ", ".join(f"{pack}#{index}" for pack, index in sorted(excused)))
    if noisy:
        details.append("network noise (not counted): " + " | ".join(noisy))
    if broke:
        gate = "FAIL"
        details.append("REGRESSED: " + " | ".join(broke))
    return gate, details


def cmd_done(args):
    with state_lock():
        ledger, item = find_item(args.item)
        last = item["attempts"][-1] if item["attempts"] else None
        if not last or last["gate"] != "PASS":
            die(f"{args.item} has no passing verification; run lc.py verify {args.item}")
        if item["class"] == "bridge-gap" and not last.get("tests"):
            die("the passing verification ran no unit test; verify again with --tests")
        if last["fingerprint"] != fingerprint():
            die("the code changed after the passing verification; verify again")
        item["status"] = "done"
        item["doneAt"] = now()
        save(ledger_path(), ledger)
    print(f"done {args.item}. Nothing is committed: commit only when the user asks. next: lc.py next")


# ── evidence ────────────────────────────────────────────────────────────────────────────

EVIDENCE_KINDS = {
    "site": "the site answers our request (the same request Legado sends) with an error or no data",
    "source": "the source's rules no longer match what the site serves",
    "antibot": "an anti-bot or verification wall the source has no login or check for",
    "login": "the content needs an account the audit does not have",
}


def diag_meta_path(tag, pack):
    # Beside the dump directory, not in it: `diag_rows` reads every JSON file in there as a row.
    return os.path.join(workdir(), f"diag-{pack}-{tag}.meta.json")


def diag_rows(tag, pack):
    directory = os.path.join(workdir(), f"diag-{pack}-{tag}")
    rows = {}
    for path in glob.glob(os.path.join(directory, "*.json")):
        row = load(path)
        rows[row.get("sourceIdentifier")] = row
    return directory, rows


def observed(row):
    """What the diagnostic dump saw, in a few lines: errors and non-2xx answers first, then the
    first responses (the search page, where most failures start)."""
    failures, others = [], []
    for event in row.get("network", []):
        if event["type"] == "response":
            title = re.search(r"<title[^>]*>(.*?)</title>", event.get("body") or "", re.I | re.S)
            line = (f"← {event['message']} {event['url'][:120]}"
                    + (f" title={title.group(1).strip()[:60]!r}" if title else ""))
            # A headless WebView's answer ("WebView · N B") is a page, not an error status.
            ok = re.search(r"HTTP 2\d\d|^WebView ·", event["message"])
            (others if ok else failures).append(line)
        elif event["type"] == "error":
            failures.append(f"! {event['message'][:160]} {event.get('url', '')[:100]}")
    return (failures + others)[:6]


def cmd_evidence(args):
    path = os.path.join(STATE, "evidence.json")
    if args.action == "list":
        for entry in load(path, {"entries": []})["entries"]:
            if args.pack in (None, entry["pack"]) and entry.get("status", "active") == "active":
                print(f"{entry['pack']}#{entry['index']}  {entry['kind']:8s} {entry['name']}  — {entry['proof'][:90]}")
        return
    pack, index = parse_ref(args.ref)
    round_ = current_round()
    row = next((r for r in load(classified_path(round_))["packs"].get(pack, {}).get("failures", [])
                if r["index"] == index), None)
    if row is None:
        die(f"{pack}#{index} is not failing in round {round_}: evidence is only for failing sources")
    if args.kind not in EVIDENCE_KINDS:
        die("--kind is one of: " + ", ".join(f"{k} ({v})" for k, v in EVIDENCE_KINDS.items()))
    if len(args.legado.strip()) < 15:
        die("--legado must say why Legado fails on the same input (which code path, what it gets)")
    directory, rows = diag_rows(args.diag, pack)
    dump = rows.get(row["url"])
    if dump is None:
        die(f"no dump for {pack}#{index} in {directory}; run: lc.py diag {args.diag} {pack} {index}")
    seen = observed(dump)
    if not seen and args.kind == "login":
        # A source that wants its login before it sends anything throws in its own script, so
        # the dump has no request: the exception is what it saw (微信读书's wrCredentials()).
        stage = first_failure(dump)
        if stage.get("summary"):
            seen = [f"✗ {stage.get('stage', '?')}: {stage['summary'][:160]}"]
    if not seen:
        die("the dump recorded no response or error to point at; that is not evidence")
    entry = {"pack": pack, "index": index, "url": row["url"], "name": row["name"], "kind": args.kind,
             "proof": args.proof, "legado": args.legado, "observed": seen, "diag": directory,
             "round": round_, "addedAt": now(), "status": "active"}
    with state_lock():
        data = load(path, {"entries": []})
        data["entries"] = [e for e in data["entries"]
                           if not (e["pack"] == pack and e["url"] == row["url"] and e.get("status", "active") == "active")]
        data["entries"].append(entry)
        save(path, data)
        ledger = load(ledger_path(), {"items": {}})
        for item in ledger["items"].values():
            if len(item["sources"]) == 1 and item["sources"][0]["url"] == row["url"] \
                    and item["status"] in ("todo", "in_progress"):
                item["status"] = "resolved"
                item["closedAt"] = now()
                item["notes"].append(f"{now()} evidence added ({args.kind})")
        save(ledger_path(), ledger)
    print(f"evidence added for {pack}#{index}:")
    for line in seen:
        print("   " + line)
    print("It counts at the next classify. next: lc.py next")


# ── audit, diag, src, oracle ────────────────────────────────────────────────────────────

def cmd_audit(args):
    chosen = args.packs.split(",") if args.packs else packs()
    for pack in chosen:
        if not os.path.exists(pack_path(pack)):
            die(f"missing {pack_path(pack)}; download the pack first (see SKILL.md, 'Packs')")
        if os.path.exists(report_path(pack, args.round)) and not args.force:
            die(f"{report_path(pack, args.round)} exists; pick a new round name or pass --force")
    meta = {"round": args.round, "startedAt": now(), "fingerprint": fingerprint(),
            "head": git("rev-parse", "--short", "HEAD").strip(), "packs": chosen}
    save(os.path.join(workdir(), f"round-{args.round}.json"), meta)
    timeout = config().get("auditTimeoutSeconds", 11000)
    for pack in chosen:
        print(f"=== audit {pack} round {args.round} ({time.strftime('%H:%M:%S')})")
        run_audit(pack_path(pack), report_path(pack, args.round), log_path(pack, args.round), timeout)
    meta["finishedAt"] = now()
    save(os.path.join(workdir(), f"round-{args.round}.json"), meta)
    print(f"next: lc.py probe {args.round}")


def cmd_recheck(args):
    """A classified round's network failures, audited once more on the round's own code.

    A measurement re-run, not a retry in the product: an audit runs hundreds of sources against
    sites that time out at random, and a source that times out once has not been shown to fail.
    It is run once per round, on the code the round measured (the fingerprint must match), and
    `score` says how many passed this way. Anything that fails again keeps its class.
    """
    if not os.path.exists(classified_path(args.round)):
        die(f"round {args.round} is not classified; run: lc.py classify {args.round}")
    meta = load(os.path.join(workdir(), f"round-{args.round}.json"), {})
    if meta.get("fingerprint") != fingerprint():
        die(f"the code changed since round {args.round} was audited; a recheck measures that "
            f"round's code, so audit a new round instead")
    result = load(classified_path(args.round))
    chosen = args.packs.split(",") if args.packs else list(result["packs"])
    timeout = config().get("auditTimeoutSeconds", 11000)
    for pack in chosen:
        failures = result["packs"].get(pack, {}).get("failures", [])
        indices = [f["index"] for f in failures if f["class"] == "network" and not f.get("rechecked")]
        if not indices:
            print(f"=== {pack}: no network failures to recheck")
            continue
        if os.path.exists(recheck_report_path(pack, args.round)) and not args.force:
            die(f"{pack} round {args.round} was rechecked already; one recheck per round "
                f"(--force only to redo a recheck that stopped early)")
        print(f"=== recheck {pack} round {args.round}: {len(indices)} network failures "
              f"({time.strftime('%H:%M:%S')})")
        run_audit(pack_path(pack), recheck_report_path(pack, args.round),
                  recheck_log_path(pack, args.round), timeout, indices=indices)
    print(f"next: lc.py classify {args.round}")


def parse_refs(text):
    refs = [parse_ref(part) for part in text.split(",") if part.strip()]
    if len({pack for pack, _ in refs}) != 1:
        die("one diag run covers one pack: give PACK#INDEX[,PACK#INDEX…] of the same pack")
    return refs[0][0], [index for _, index in refs]


def cmd_diag(args):
    args.pack, indices = parse_refs(args.refs)
    directory = os.path.join(workdir(), f"diag-{args.pack}-{args.tag}")
    os.makedirs(directory, exist_ok=True)
    sources = load(pack_path(args.pack))
    stamp = int(time.time() * 1000)
    for source in sources:
        source["lastUpdateTime"] = stamp
    stamped = os.path.join(workdir(), f"pack-{args.pack}-diag-{args.tag}.json")
    save(stamped, sources)
    # Which code the diag ran on: `unblock` only takes a diag on the code that failed the gate.
    save(diag_meta_path(args.tag, args.pack), {"fingerprint": fingerprint(), "startedAt": now()})
    with test_config(DIAG_CONFIG, {"pack": stamped, "indices": indices, "outDir": directory}):
        ok, verdict = xctest(os.path.join(workdir(), f"diag-{args.pack}-{args.tag}.log"), [DIAG_TEST], 3600)
    print(f"[{verdict}]")
    print_diag(directory, {str(i) for i in indices})


def print_diag(directory, wanted):
    for path in sorted(glob.glob(os.path.join(directory, "*.json")), key=lambda p: int(os.path.basename(p)[:-5])):
        if wanted and os.path.basename(path)[:-5] not in wanted:
            continue
        row = load(path)
        print("=" * 100)
        print(f"[{row['index']}] {row['sourceName']}  {row['sourceIdentifier']}  passed={row['passed']} "
              f"cat={row['failureCategory']}")
        if row.get("apiError"):
            print("  api:", row["apiError"][:200])
        for stage in row["stages"]:
            if stage["status"] != "skipped":
                print(f"  {stage['stage']}: {stage['status']} {stage['summary'][:160]}")
        for event in row["network"]:
            if event["type"] == "request":
                print(f"  → {event['message']} {event['url'][:200]}")
            elif event["type"] == "response":
                body = re.sub(r"\s+", " ", event.get("body") or "")
                title = re.search(r"<title[^>]*>(.*?)</title>", event.get("body") or "", re.I | re.S)
                print(f"  ← {event['message']} {event['url'][:120]} title={(title.group(1).strip()[:80] if title else '')!r}")
                print(f"      {body[:240]}")
            elif event["type"] in ("error", "info"):
                print(f"  ! {event['type']} {event['message'][:200]} {event.get('url', '')[:120]}")
        for line in row.get("rules", [])[:40]:
            print("    " + line.replace("\n", " ")[:220])


def cmd_src(args):
    pack, index = parse_ref(args.ref)
    source = listed_sources(pack_path(pack))[index]
    fields = args.fields or ["bookSourceName", "bookSourceUrl", "bookSourceType", "header", "loginUrl",
                             "loginCheckJs", "jsLib", "searchUrl", "ruleSearch", "exploreUrl",
                             "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent"]
    for field in fields:
        value = source.get(field)
        if value in (None, "", {}):
            continue
        text = json.dumps(value, ensure_ascii=False, indent=1) if isinstance(value, (dict, list)) else str(value)
        print(f"## {field}:\n{text[:args.width]}")


def oracle_jars():
    pins = load(os.path.join(HERE, "oracle", "jars.json"))
    paths = []
    for jar in pins["jars"]:
        candidates = glob.glob(os.path.expanduser(jar["glob"]))
        found = None
        for candidate in candidates:
            with open(candidate, "rb") as f:
                if hashlib.sha256(f.read()).hexdigest() == jar["sha256"]:
                    found = candidate
                    break
        if not found:
            die(f"{jar['name']} with sha256 {jar['sha256']} not found at {jar['glob']}. "
                f"Download it from {jar['url']} into that folder (ask the user first).")
        paths.append(found)
    return paths


def cmd_oracle(args):
    jars = oracle_jars()
    source = os.path.join(HERE, "oracle", "Oracle.java")
    with open(source, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()[:12]
    classes = os.path.join(workdir(), f"oracle-classes-{digest}")
    if not os.path.exists(os.path.join(classes, "Oracle.class")):
        os.makedirs(classes, exist_ok=True)
        subprocess.run(["javac", "-cp", ":".join(jars), "-d", classes, source], check=True)
    subprocess.run(["java", "-cp", ":".join(jars + [classes]), "Oracle", os.path.abspath(args.cases)], check=True)


# ── status and self-check ───────────────────────────────────────────────────────────────

def cmd_status(args):
    cfg = config()
    print(f"workdir {workdir()}")
    for pack in packs():
        exists = os.path.exists(pack_path(pack))
        print(f"  pack {pack}: {'present' if exists else 'MISSING'}  target {target(pack)}")
    history = load(os.path.join(STATE, "history.json"), {"rounds": []})["rounds"]
    latest = history[-1]["round"] if history else None
    print("rounds: " + (", ".join(r["round"] for r in history) or "none"))
    busy = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0
    print("another xcodebuild is running" if busy else "no xcodebuild running")
    ledger = load(ledger_path(), {"items": {}})
    counts = collections.Counter(i["status"] for i in ledger["items"].values())
    print("items: " + (", ".join(f"{k} {v}" for k, v in counts.items()) or "none"))
    in_progress = [i for i in ledger["items"].values() if i["status"] == "in_progress"]
    if latest and os.path.exists(classified_path(latest)):
        print_score(load(classified_path(latest)))
    fp = fingerprint()
    print(f"code fingerprint {fp}" + (f" (round {latest} ran on {history[-1].get('fingerprint') or '?'})" if latest else ""))
    print("\nNEXT:")
    if any(not os.path.exists(pack_path(p)) for p in packs()):
        print("  download the missing pack(s) (SKILL.md, 'Packs')")
    elif not latest:
        print("  python3 -I scripts/legado-compat/lc.py audit r1")
    elif in_progress:
        print(f"  continue {in_progress[0]['id']}:  lc.py show {in_progress[0]['id']}")
    elif not os.path.exists(probe_path(latest, "remote")):
        print(f"  lc.py probe {latest}")
    elif not os.path.exists(classified_path(latest)) or ledger.get("round") != latest:
        print(f"  lc.py classify {latest}")
    elif counts.get("todo"):
        print("  lc.py next")
    else:
        print("  every item is done, blocked or resolved: run a new round (lc.py audit rN)")
    _ = cfg


def cmd_check(args):
    """The workflow's own CI: run it after editing anything under scripts/legado-compat or the skill."""
    problems = []
    a = os.path.join(ROOT, ".claude/skills/legado-compat")
    b = os.path.join(ROOT, ".agents/skills/legado-compat")
    for dirpath, _, files in os.walk(a):
        for name in files:
            left = os.path.join(dirpath, name)
            right = os.path.join(b, os.path.relpath(left, a))
            if not os.path.exists(right) or open(left, "rb").read() != open(right, "rb").read():
                problems.append(f"skill copies differ: {os.path.relpath(left, ROOT)}")
    for dirpath, _, files in os.walk(b):
        for name in files:
            if not os.path.exists(os.path.join(a, os.path.relpath(os.path.join(dirpath, name), b))):
                problems.append(f"only in .agents: {name}")
    rule_set = rules()
    for key in ("methods", "globals", "patterns", "deadVerdicts", "workCards"):
        if key not in rule_set:
            problems.append(f"rules.json lacks {key}")
    for key, pattern in rule_set.get("patterns", {}).items():
        try:
            re.compile(pattern)
        except re.error as error:
            problems.append(f"rules.json pattern {key}: {error}")
    for cls in PRIORITY:
        if cls not in rule_set.get("workCards", {}):
            problems.append(f"rules.json has no work card for {cls}")
    samples = {
        "TypeError: result.select('.a b').hasClass is not a function. (In 'x', 'y' is undefined)": "method:hasClass",
        "TypeError: null is not an object (evaluating 'a.b')": None,
        "Error: UnsupportedLegadoAPIError: Packages.io.legado.app.model.analyzeRule.AnalyzeRule at javascript": "api:Packages.io.legado.app.model.analyzeRule.AnalyzeRule",
        "TypeError: run(\"data\").map is not a function.": None,
    }
    for message, expected in samples.items():
        got = signature(message, rule_set, set())
        if got != expected:
            problems.append(f"signature({message[:50]}…) = {got}, expected {expected}")
    for name in ("config.json", "ledger.json", "evidence.json", "history.json"):
        path = os.path.join(STATE, name)
        if os.path.exists(path):
            try:
                load(path)
            except ValueError as error:
                problems.append(f"state/{name}: {error}")
    try:
        oracle_jars()
    except SystemExit:
        problems.append("oracle jars missing or changed")
    print("\n".join("✗ " + p for p in problems) if problems else "✓ workflow check passed")
    sys.exit(1 if problems else 0)


def cmd_rules(args):
    """Regenerate the method and global lists from jsoup, java.lang.String and Legado's sources."""
    rule_set = rules()
    methods = set()
    jars = oracle_jars()
    jsoup = next(j for j in jars if "jsoup" in j)
    for classes, cp in ((["org.jsoup.nodes.Element", "org.jsoup.select.Elements", "org.jsoup.nodes.Node",
                          "org.jsoup.nodes.Document", "org.jsoup.nodes.TextNode", "org.jsoup.nodes.Attributes"], jsoup),
                        (["java.lang.String"], None)):
        command = ["javap", "-public"] + (["-cp", cp] if cp else []) + classes
        out = subprocess.run(command, capture_output=True, text=True, check=True).stdout
        methods |= set(re.findall(r" ([A-Za-z_]\w*)\(", out))
    legado = os.path.join(ROOT, rule_set["legadoCheckout"])
    for relative in rule_set["legadoBridgeFiles"]:
        with open(os.path.join(legado, relative), encoding="utf-8") as f:
            methods |= set(re.findall(r"\bfun\s+(?:[\w.<>?]+\.)?([A-Za-z_]\w*)\s*\(", f.read()))
    methods |= set(rule_set["okhttpMethods"])
    methods -= set(rule_set["notBridgeMethods"])
    rule_set["methods"] = sorted(m for m in methods if not m.startswith("lambda"))
    with open(RULES_PATH, "w", encoding="utf-8") as f:
        json.dump(rule_set, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"rules.json: {len(rule_set['methods'])} methods, {len(rule_set['globals'])} globals")


def main():
    parser = argparse.ArgumentParser(prog="lc.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="where things stand and the next command").set_defaults(func=cmd_status)
    p = sub.add_parser("audit", help="audit every pack (hours); run in the background")
    p.add_argument("round"); p.add_argument("--packs"); p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_audit)
    p = sub.add_parser("recheck", help="audit a classified round's network failures once more")
    p.add_argument("round"); p.add_argument("--packs"); p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_recheck)
    p = sub.add_parser("probe", help="reachability of failing origins, here and on the remote host")
    p.add_argument("round"); p.set_defaults(func=cmd_probe)
    p = sub.add_parser("classify", help="one class per failing source; updates the ledger")
    p.add_argument("round"); p.set_defaults(func=cmd_classify)
    p = sub.add_parser("score", help="usable = passed + dead + evidence, against the targets")
    p.add_argument("round"); p.set_defaults(func=cmd_score)
    p = sub.add_parser("record", help="add a round's passing sources to history (classify does this)")
    p.add_argument("round"); p.set_defaults(func=cmd_record)
    p = sub.add_parser("items", help="list ledger items in priority order")
    p.add_argument("--status"); p.add_argument("--limit", type=int, default=40); p.set_defaults(func=cmd_items)
    p = sub.add_parser("next", help="take the next item (one at a time)")
    p.add_argument("--owner", default=os.environ.get("USER", "agent")); p.set_defaults(func=cmd_next)
    p = sub.add_parser("show", help="an item, its sources and what to do")
    p.add_argument("item"); p.add_argument("--all", action="store_true"); p.set_defaults(func=cmd_show)
    p = sub.add_parser("verify", help="unit tests + targeted audit of the item and its controls")
    p.add_argument("item"); p.add_argument("--tests", action="append"); p.set_defaults(func=cmd_verify)
    p = sub.add_parser("done", help="close an item whose last verification passed on this code")
    p.add_argument("item"); p.set_defaults(func=cmd_done)
    p = sub.add_parser("block", help="stop working on an item and say why")
    p.add_argument("item"); p.add_argument("--reason", required=True); p.set_defaults(func=cmd_block)
    p = sub.add_parser("release", help="put the item in progress back in line (it was taken by mistake)")
    p.add_argument("item"); p.add_argument("--reason", required=True); p.set_defaults(func=cmd_release)
    p = sub.add_parser("expect", help="the item in progress is met when its sources fail as Legado does")
    p.add_argument("item"); p.add_argument("--regex", required=True); p.add_argument("--legado", required=True)
    p.set_defaults(func=cmd_expect)
    p = sub.add_parser("unblock", help="a blocked item whose only failures are controls a diag shows failing at the site")
    p.add_argument("item"); p.add_argument("--diag", required=True); p.add_argument("--reason", required=True)
    p.add_argument("--proof"); p.add_argument("--legado"); p.set_defaults(func=cmd_unblock)
    p = sub.add_parser("take", help="take one named todo item whose fix is already written")
    p.add_argument("item"); p.add_argument("--owner", default=os.environ.get("USER", "agent"))
    p.set_defaults(func=cmd_take)
    p = sub.add_parser("skip", help="network noise: closed for this round, reopens if it fails again")
    p.add_argument("item"); p.add_argument("--reason", required=True)
    p.add_argument("--diag", help="for a regression: a diag on this code in which its sources pass")
    p.set_defaults(func=cmd_skip)
    p = sub.add_parser("reject", help="a bridge cluster that Legado fails the same way")
    p.add_argument("item"); p.add_argument("--legado", required=True); p.set_defaults(func=cmd_reject)
    p = sub.add_parser("add", help="a bridge gap found while investigating a source")
    p.add_argument("item"); p.add_argument("--sources", required=True)
    p.add_argument("--controls", required=True, help="regex that finds sources using the same API")
    p.add_argument("--expect", help="regex of the error Legado raises for these sources: the item is "
                                    "met when they fail with it (a fix that makes a failure Legado's)")
    p.add_argument("--why", required=True); p.set_defaults(func=cmd_add)
    p = sub.add_parser("evidence", help="evidence that a site or source is broken for Legado too")
    p.add_argument("action", choices=["add", "list"]); p.add_argument("ref", nargs="?")
    p.add_argument("--pack"); p.add_argument("--kind"); p.add_argument("--diag")
    p.add_argument("--proof"); p.add_argument("--legado"); p.set_defaults(func=cmd_evidence)
    p = sub.add_parser("diag", help="dump every request, response and rule step of some sources")
    p.add_argument("tag"); p.add_argument("refs", help="PACK#INDEX[,PACK#INDEX…], one pack")
    p.set_defaults(func=cmd_diag)
    p = sub.add_parser("src", help="print a source's rules")
    p.add_argument("ref", help="PACK#INDEX"); p.add_argument("fields", nargs="*")
    p.add_argument("--width", type=int, default=2500); p.set_defaults(func=cmd_src)
    p = sub.add_parser("oracle", help="what Legado's Rhino + jsoup return for JS cases")
    p.add_argument("cases"); p.set_defaults(func=cmd_oracle)
    sub.add_parser("check", help="the workflow's own consistency check").set_defaults(func=cmd_check)
    sub.add_parser("rules", help="regenerate rules.json method lists").set_defaults(func=cmd_rules)
    args = parser.parse_args()
    if args.command == "evidence" and args.action == "add":
        missing = [k for k in ("ref", "kind", "diag", "proof", "legado") if not getattr(args, k)]
        if missing:
            die("evidence add needs: PACK#INDEX --kind --diag --proof --legado (missing: " + ", ".join(missing) + ")")
    args.func(args)


if __name__ == "__main__":
    main()
