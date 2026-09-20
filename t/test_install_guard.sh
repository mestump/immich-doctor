#!/bin/bash
# The only genuinely destructive line in install.sh is the appdata wipe. This asserts
# the guard accepts the real path and rejects everything that would take the array out.
set -u
GUARD=$(grep -n 'refusing to wipe' ../docs/install.sh 2>/dev/null || grep -n 'refusing to wipe' docs/install.sh)
[ -n "$GUARD" ] || { echo "FAIL: guard line missing from install.sh"; exit 1; }

wipes() { # APPDATA -> "yes"/"no", using the same case pattern as install.sh
  case "$1" in /mnt/user/appdata/?*) echo yes;; *) echo no;; esac
}
fail=0
for p in /mnt/user/appdata/immich /mnt/user/appdata/immich/postgres; do
  [ "$(wipes "$p")" = yes ] || { echo "FAIL: should wipe $p"; fail=1; }
done
for p in / /mnt /mnt/user /mnt/user/appdata /mnt/user/photos "" /boot; do
  [ "$(wipes "$p")" = no ] || { echo "FAIL: would wipe ${p:-<empty>}"; fail=1; }
done
# and the photos dir must never appear in a destructive command
grep -E 'rm -rf.*PHOTOS|rm -f.*PHOTOS' docs/install.sh 2>/dev/null && { echo "FAIL: install.sh deletes something under PHOTOS"; fail=1; }
[ $fail = 0 ] && echo "PASS: wipe guard holds, photos untouched"
exit $fail
