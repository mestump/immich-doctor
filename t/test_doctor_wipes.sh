#!/bin/bash
# Unhealthy doctor must wipe-and-install, not spend 8 rounds on CREATE EXTENSION.
set -u
cd "$(dirname "$0")/.."
fail=0

grep -q 'run_fresh_install()' docs/doctor.sh || { echo "FAIL: no run_fresh_install()"; fail=1; }
grep -q 'immich-doctor/install.sh' docs/doctor.sh || { echo "FAIL: doctor does not fetch install.sh"; fail=1; }

python3 - <<'PY'
src = open("docs/doctor.sh").read()
idx = src.rfind('if [ "${DOCTOR_LIB:-0}" = 1 ]; then return')
main = src[idx:]
if "run_fresh_install" not in main:
    print("FAIL: main does not call run_fresh_install"); raise SystemExit(1)
healthy = main.find("healthy_exit")
install = main.find("run_fresh_install")
if install < 0 or healthy < 0 or install < healthy:
    print("FAIL: run_fresh_install is not after the healthy check"); raise SystemExit(1)
if "for ROUND" in main:
    print("FAIL: spark loop still in main"); raise SystemExit(1)
if "FIXOUT=$(t_fix_dns" in main or "ENVOUT=$(t_fix_env" in main:
    print("FAIL: in-place repair floor still runs before install"); raise SystemExit(1)
print("ok   main hands off to install after unhealthy")
PY
[ $? -eq 0 ] || fail=1

# install.sh must wait for postgres and must not hide pull errors
grep -q 'pg_isready' docs/install.sh || { echo "FAIL: install.sh does not wait for postgres"; fail=1; }
grep -E 'docker pull .*>/dev/null' docs/install.sh && { echo "FAIL: install.sh still swallows pull output"; fail=1; }
grep -q 'wipe_appdata' docs/install.sh || { echo "FAIL: no wipe_appdata helper"; fail=1; }
grep -q '/mnt/user/appdata/PostgreSQL_Immich' docs/install.sh || { echo "FAIL: leftover imagegenius postgres appdata not wiped"; fail=1; }

[ $fail = 0 ] && echo "PASS: doctor wipes instead of repairing"
exit $fail
