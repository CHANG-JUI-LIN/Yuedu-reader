#!/usr/bin/env python3
"""Exercise the real wrapper with a fake CLI; no Xcode, simulator, or network work."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="yuedu-xctest-wrapper-") as temporary:
    directory = Path(temporary)
    fake = directory / "xcodebuild"
    fake.write_text('''#!/bin/bash
case "$YUEDU_WRAPPER_FIXTURE" in
  success)
    echo "Background service failed to fetch account"
    echo "Test run with 6 tests in 1 suite passed"
    echo "** TEST SUCCEEDED **"
    exec sleep 30 ;;
  failure)
    echo "Test run with 2 tests in 1 suite failed"
    echo "** TEST FAILED **"
    exec sleep 30 ;;
  missing) echo "Exited without a verdict"; exit 0 ;;
  timeout) exec sleep 30 ;;
esac
''')
    fake.chmod(0o755)
    sentinel = subprocess.Popen(["bash", "-c", "exec -a 'xcodebuild test unrelated-fixture' sleep 120"])
    try:
        for case, expected in [("success", 0), ("failure", 1), ("missing", 1), ("timeout", 1)]:
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       DEVELOPER_DIR="fixture", YUEDU_DEST="fixture",
                       YUEDU_WRAPPER_FIXTURE=case)
            result = subprocess.run(["bash", str(ROOT / "scripts/xctest.sh"), "-l", str(directory / (case + ".log")),
                                     "-t", "1" if case == "timeout" else "30"],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40)
            assert result.returncode == expected, (case, result.returncode, result.stdout)
            assert sentinel.poll() is None, "Wrapper terminated another test process"
            print(f"PASS {case}: exit={expected}; unrelated process preserved")
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=5)
