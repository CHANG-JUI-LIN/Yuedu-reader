#!/bin/bash
# Opt-in acceptance against a locally installed Calibre Content server.
# Supply credentials via environment; they are never printed to the build log.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${YUEDU_LIVE_CALIBRE_URL:?Set YUEDU_LIVE_CALIBRE_URL to the test server OPDS URL}"
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
CALIBRE_TEST_DEST="$(bash scripts/sim.sh dest)"
CALIBRE_TEST_LOG="${YUEDU_CALIBRE_TEST_LOG_PREFIX:-/tmp/yuedu-live-calibre}"
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$CALIBRE_TEST_DEST" \
  -parallel-testing-enabled NO build-for-testing > "$CALIBRE_TEST_LOG-build.log" 2>&1
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$CALIBRE_TEST_DEST" \
  -showBuildSettings -json > "$CALIBRE_TEST_LOG-settings.json" 2>/dev/null
export YUEDU_CALIBRE_SETTINGS_FILE="$CALIBRE_TEST_LOG-settings.json"
CALIBRE_TEST_RUN="$(python3 - <<'PY'
import glob, json, os, plistlib
settings=json.load(open(os.environ['YUEDU_CALIBRE_SETTINGS_FILE']))
build_dir=next(x['buildSettings']['BUILD_DIR'] for x in settings if x['target']=='yuedu app')
paths=[p for p in glob.glob(build_dir+'/*.xctestrun') if not p.endswith('Yuedu-LiveCalibre.xctestrun')]
p=max(paths,key=os.path.getmtime)
d=plistlib.load(open(p,'rb'))
keys=['YUEDU_LIVE_CALIBRE_URL','YUEDU_LIVE_CALIBRE_USER','YUEDU_LIVE_CALIBRE_PASSWORD',
      'YUEDU_LIVE_CALIBRE_READONLY_USER','YUEDU_LIVE_CALIBRE_READONLY_PASSWORD',
      'YUEDU_LIVE_CALIBRE_WIRELESS_HOST','YUEDU_LIVE_CALIBRE_WIRELESS_PORT',
      'YUEDU_LIVE_CALIBRE_WIRELESS_PASSWORD','YUEDU_LIVE_CALIBRE_WIRELESS_EXPECTED_TITLE']
def configure(t):
 env=t.setdefault('EnvironmentVariables',{})
 for key in keys:
  if key in os.environ:env[key]=os.environ[key]
  else:env.pop(key,None)
for key,t in d.items():
 if isinstance(t,dict) and 'TestBundlePath' in t:configure(t)
for c in d.get('TestConfigurations',[]):
 for t in c['TestTargets']:configure(t)
out=build_dir+'/Yuedu-LiveCalibre.xctestrun'
with open(out,'wb') as f:plistlib.dump(d,f)
os.chmod(out,0o600)
print(out)
PY
)"
trap 'rm -f "$CALIBRE_TEST_RUN"' EXIT
if (($# == 0)); then set -- LiveCalibreIntegrationTests; fi
for CALIBRE_TEST_CLASS in "$@"; do
  xcodebuild test-without-building -xctestrun "$CALIBRE_TEST_RUN" -destination "$CALIBRE_TEST_DEST" \
    -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:"yuedu appTests/$CALIBRE_TEST_CLASS" \
    -resultBundlePath "$CALIBRE_TEST_LOG-$CALIBRE_TEST_CLASS.xcresult" \
    > "$CALIBRE_TEST_LOG-$CALIBRE_TEST_CLASS.log" 2>&1
  rg 'Test run with|TEST EXECUTE SUCCEEDED|LiveCalibre' "$CALIBRE_TEST_LOG-$CALIBRE_TEST_CLASS.log"
done
