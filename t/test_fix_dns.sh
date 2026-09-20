#!/bin/bash
# ponytail: one check — fix_dns must alias the real container names to the names
# immich's env actually asks for. Run: bash t/test_fix_dns.sh
set -u
cd "$(dirname "$0")/.."
export FAKE_LOG=$(mktemp) PATH="$PWD/t:$PATH" API_KEY=test DOCTOR_LIB=1
hash -r
: >"$FAKE_LOG"
curl() { echo 200; }   # stub: web answers after the fix
export -f curl 2>/dev/null || true
source docs/doctor.sh >/dev/null 2>&1
PATH="$PWD/t:$PATH"; hash -r   # doctor.sh:21 re-prepends the system dirs

fail=0
chk() { if grep -qF "$1" "$FAKE_LOG"; then echo "  ok   $1"; else echo "  FAIL missing: $1"; fail=1; fi; }

echo "== t_fix_dns on a default-bridge, compose-managed stack =="
out=$(t_fix_dns 2>&1)
echo "$out" | sed 's/^/  | /'

chk "network create immich-net"
# DB_HOSTNAME=immich-postgres, but the container is named PostgreSQL_Immich
chk "network connect --alias immich-postgres immich-net PostgreSQL_Immich"
# no REDIS_HOSTNAME in the env at all -> immich's built-in default is 'redis'
chk "network connect --alias redis immich-net immich-redis"
chk "network connect immich-net immich"
chk "restart immich"

echo "== idempotence: a second run must not re-connect =="
: >"$FAKE_LOG"; echo "network create immich-net" >>"$FAKE_LOG"
echo "network connect --alias immich-postgres immich-net PostgreSQL_Immich" >>"$FAKE_LOG"
echo "network connect --alias redis immich-net immich-redis" >>"$FAKE_LOG"
echo "network connect immich-net immich" >>"$FAKE_LOG"
before=$(wc -l <"$FAKE_LOG")
t_fix_dns >/dev/null 2>&1
if grep -c '^network connect' "$FAKE_LOG" | grep -qx 3; then echo "  ok   no duplicate connects"; else echo "  FAIL reconnected"; fail=1; fi

rm -f "$FAKE_LOG"
[ $fail = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }

echo "== t_fix_env: corrupt template Target + missing env =="
TPL=$(mktemp -d); cat > "$TPL/my-immich.xml" <<'X'
<?xml version="1.0"?>
<Container version="2">
  <Name>immich</Name>
  <Config Name="DB_PORT" Target="DB_PORT" Type="Variable">5432</Config>
  <Config Name="REDIS_HOSTNAME" Target="localhost.br" Type="Variable">immich-redis</Config>
  <Config Name="Photos Storage" Target="/photos" Type="Path">/mnt/user/photos</Config>
</Container>
X
TPLDIR="$TPL" DRYRUN=1 t_fix_env immich 2>&1 | sed 's/^/  | /'
grep -q 'Name="REDIS_HOSTNAME" Target="REDIS_HOSTNAME"' "$TPL/my-immich.xml" \
  && echo "  ok   template Target repaired" || { echo "  FAIL template Target"; exit 1; }
grep -q 'Name="Photos Storage" Target="/photos"' "$TPL/my-immich.xml" \
  && echo "  ok   friendly Path label untouched" || { echo "  FAIL clobbered a Path label"; exit 1; }
TPLDIR="$TPL" DRYRUN=1 t_fix_env immich 2>&1 | grep -q 'REDIS_HOSTNAME=immich-redis' \
  && echo "  ok   set_env would set REDIS_HOSTNAME=immich-redis" || { echo "  FAIL set_env value"; exit 1; }
rm -rf "$TPL"
echo "PASS"
