#!/bin/bash
# End-to-end test for docs/import.sh against a mock Immich API.
# Run: bash t/test_takeout_import.sh   (from the immich-doctor repo root, or directly)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/takeout-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
SH="$HERE/../docs/import.sh"
PORT=9123
PASS=0; FAIL=0
check(){ if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }
stats(){ curl -s "http://127.0.0.1:$PORT/__stats"; }
wait_port(){ local p=$1 i=0; while curl -s -m 1 "http://127.0.0.1:$p/api/server/ping" >/dev/null 2>&1 && [ $i -lt 50 ]; do fuser -k $p/tcp >/dev/null 2>&1; sleep 0.2; i=$((i+1)); done; }
start_mock(){ local p=$1; kill "$(cat "$T/mock.pid" 2>/dev/null)" 2>/dev/null || true; wait_port "$p"
  MOCK_KEY=test python3 "$HERE/mockimmich.py" "$p" & echo $! > "$T/mock.pid"
  local i=0; until curl -s -m 1 "http://127.0.0.1:$p/api/server/ping" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 30 ] && return 1; sleep 0.2; done; }


rm -rf "$T/state"; mkdir -p "$T/state"
python3 "$HERE/takeout_fixtures.py" "$T/dl" >/dev/null || { echo "fixture generation failed"; exit 1; }

# fresh mock server
start_mock "$PORT" || { echo "mock server didn't start"; exit 1; }

export IG_ALLOW_NONROOT=1 IG_ASSUME_YES=1
export IG_CONF=$T/state/takeout.conf IG_BINDIR=$T/state/bin
export IG_DONE_LIST=$T/state/imported.txt IG_WORK=$T/state/work
export IG_SERVER=http://127.0.0.1:$PORT IG_KEY=test IG_TUI=off IG_MIN_ZIP_MB=0
export IG_EXTRA_DIRS=$T/dl

echo "--- run 1: two takeouts (loose parts + Chrome wrapper), junk zip present"
out=$(bash "$SH" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    | /' | tail -20
check "run 1 exits 0"                  "[ $rc -eq 0 ]"
check "junk zip ignored"               "! printf '%s' \"\$out\" | grep -q some-addon"
check "wrapper detected + unpacked"    "printf '%s' \"\$out\" | grep -q 'unzipping the merged download'"
check "two parts bundled as one run"   "printf '%s' \"\$out\" | grep -q 'other part'"
check "assets uploaded to server"      "stats | grep -qE '\"uploads\": *[1-9]'"
check "album created on server"        "stats | grep -qE '\"albums\": *[1-9]'"
check "both bundles in done-list"      "grep -q 'ts:20240115t101530z' $T/state/imported.txt && grep -q 'f:takeout-february-2024.zip' $T/state/imported.txt"
check "config saved, mode 600"         "grep -q 'IG_KEY=' $T/state/takeout.conf && [ \"\$(stat -c%a $T/state/takeout.conf)\" = 600 ]"
check "immich-go installed + pinned"   "[ -x $T/state/bin/immich-go ] && [ \"\$(cat $T/state/bin/.version)\" = v0.32.0 ]"
check "unpacked temp dirs cleaned"     "! find $T/state/work -name 'unpacked-*' | grep -q ."
check "downloads NOT auto-deleted"     "ls $T/dl/takeout-*  >/dev/null 2>&1"

echo "--- run 2: idempotence (everything already done)"
out2=$(bash "$SH" 2>&1); rc2=$?
check "run 2 exits 0"                  "[ $rc2 -eq 0 ]"
check "run 2 says already imported"    "printf '%s' \"\$out2\" | grep -qi 'already imported'"

echo "--- run 3: a NEW takeout arrives; the finished ones are skipped"
python3 - "$T/dl" <<'EOF'
import sys, zipfile, json
dl = sys.argv[1]
with zipfile.ZipFile(f"{dl}/takeout-20240310T090000Z-1 of 1.zip", "w") as z:
    z.writestr("Photos/2023/NEW1.jpg", b"\xff\xd8\xff\xe0" + b"x"*5000)
    z.writestr("Photos/2023/NEW1.jpg.json", json.dumps({"title":"NEW1.jpg","photoTakenTime":{"timestamp":"1670000000"}}).encode())
EOF
out3=$(bash "$SH" 2>&1); rc3=$?
check "run 3 exits 0"                  "[ $rc3 -eq 0 ]"
check "run 3 imports only the new one" "printf '%s' \"\$out3\" | grep -q 'takeout-20240310T090000Z' && printf '%s' \"\$out3\" | grep -q 'already imported' || printf '%s' \"\$out3\" | grep -q 'Importing takeout-20240310T090000Z'"
check "run 3 leaves finished zips"     "ls $T/dl/Takeout-February-2024.zip >/dev/null 2>&1"
check "done-list now has 3 entries"    "[ \$(grep -c . $T/state/imported.txt) -ge 3 ]"

echo "--- run 4: saved key revoked -> clear error, no hang, no wipe"
export IG_KEY=revoked
out4=$(bash "$SH" 2>&1); rc4=$?
check "run 4 nonzero exit"             "[ $rc4 -ne 0 ]"
check "run 4 explains the bad key"     "printf '%s' \"\$out4\" | grep -qi 'no longer works\|did not accept\|needs an API key'"

echo "--- run 5: archives re-fed against the SAME server; dedupe must skip by checksum"
export IG_KEY=test
before=$(stats | python3 -c 'import json,sys; print(json.load(sys.stdin)["uploads"])')
export IG_FORCE=1                                  # ignore the done-list on purpose
out5=$(bash "$SH" 2>&1); rc5=$?
after=$(stats | python3 -c 'import json,sys; print(json.load(sys.stdin)["uploads"])')
check "run 5 exits 0"                  "[ $rc5 -eq 0 ]"
check "dedupe: no new uploads"         "[ \"$before\" = \"$after\" ]"

echo "--- run 6: server was wiped (fresh mock, 0 assets) but done-list claims done -> re-import"
start_mock "$PORT"
unset IG_FORCE
out6=$(bash "$SH" 2>&1); rc6=$?
check "run 6 exits 0"                  "[ $rc6 -eq 0 ]"
check "run 6 re-imports after wipe"    "stats | grep -qE '\"uploads\": *[1-9]'"
check "run 6 mentions the empty check" "printf '%s' \"\$out6\" | grep -qi 'looks empty\|Importing'"

echo "--- run 7: autodetect — mock answers on 2283, no saved config, IG_SERVER unset"
rm -f "$T/state/takeout.conf"
start_mock 2283
out7=$(bash -c "unset IG_SERVER; bash $SH" 2>&1); rc7=$?
check "run 7 autodetected 2283"        "printf '%s' \"\$out7\" | grep -q 'Immich found at http://127.0.0.1:2283'"

kill "$(cat $T/mock.pid)" 2>/dev/null || true
echo; echo "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
