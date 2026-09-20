#!/bin/bash
# tailscale.sh must be re-runnable, guard its state dir, and print the Immich URL.
set -u
cd "$(dirname "$0")/.."
S=docs/tailscale.sh
fail=0
[ -f "$S" ] || { echo "FAIL: docs/tailscale.sh missing"; exit 1; }
bash -n "$S" || { echo "FAIL: tailscale.sh does not parse"; exit 1; }

grep -q 'TS_AUTHKEY' "$S"            || { echo "FAIL: no auth-key support"; fail=1; }
grep -q 'STATE_DIR' "$S"             || { echo "FAIL: no persistent state dir"; fail=1; }
grep -qE 'case "\$STATE_DIR"' "$S"   || { echo "FAIL: state dir not guarded"; fail=1; }
grep -q -- '--net=host' "$S"         || { echo "FAIL: not host-networked (Immich port would not be reachable on 100.x)"; fail=1; }
grep -q '/dev/net/tun' "$S"          || { echo "FAIL: does not check for /dev/net/tun"; fail=1; }
grep -q 'api' "$S"                   || { echo "FAIL: does not print the Immich API endpoint"; fail=1; }

# re-running with no key on a joined box must succeed, not demand a key
python3 - <<'PY'
src = open("docs/tailscale.sh").read()
# the "not installed AND no key" failure must be gated on the container being absent
i_absent = src.find("grep -qx tailscale")
i_keyfail = src.find("no auth key was given")
i_logged = src.find("ts_logged_in; then")
if min(i_absent, i_keyfail, i_logged) < 0:
    print("FAIL: re-run path missing"); raise SystemExit(1)
if not (i_absent < i_keyfail < i_logged):
    print("FAIL: key demand is not gated on an absent container, or runs before the already-joined check")
    raise SystemExit(1)
print("ok   re-runnable without a key")
PY
[ $? -eq 0 ] || fail=1

# key must never be echoed back
grep -E 'echo.*(TS_AUTHKEY|\$KEY)"?$' "$S" | grep -v '^#' | grep -q . && { echo "FAIL: auth key may be echoed"; fail=1; }

[ $fail = 0 ] && echo "PASS: tailscale.sh"
exit $fail
