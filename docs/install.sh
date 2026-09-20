#!/bin/bash
# Wipe a broken Immich stack on Unraid and rebuild it from the images upstream
# actually ships today.  One command:
#   curl -fsSL https://mestump.github.io/immich-doctor/install.sh | bash
#
# doctor.sh calls this when Immich is not answering. Same effect either way.
#
# It removes the Immich containers, their dockerMan templates and their appdata.
# It does NOT touch your photos directory.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

say() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

PHOTOS="${PHOTOS:-/mnt/user/photos}"
APPDATA="${APPDATA:-/mnt/user/appdata/immich}"
PORT="${PORT:-2283}"
NET="${NET:-immich-net}"
DBPASS="${DBPASS:-immich}"
TPLDIR="${TPLDIR:-/boot/config/plugins/dockerMan/templates-user}"
COUNTDOWN="${COUNTDOWN:-15}"

# Versions come from the current upstream release compose. The database image is the
# whole reason for this script: Immich needs the VectorChord extension, and the old
# tensorchord/pgvecto-rs image cannot provide it at any configuration.
IMG_SRV=ghcr.io/immich-app/immich-server:release
IMG_ML=ghcr.io/immich-app/immich-machine-learning:release
IMG_DB=ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
IMG_RD=docker.io/valkey/valkey:9

command -v docker >/dev/null || { bad "docker not found — run this in the Unraid terminal"; exit 1; }

wipe_appdata() { # only ever under /mnt/user/appdata/<something>
  case "$1" in
    /mnt/user/appdata/?*) rm -rf "${1:?}" && echo "  wiped $1";;
    *) warn "refusing to wipe $1";;
  esac
}

start_ctr() { # name, then docker-run args (image last). Prints docker's error. Requires Running=true.
  local name="$1" err st; shift
  err=$(mktemp)
  if ! docker run -d --name "$name" "$@" >"$err" 2>&1; then
    bad "$name failed to start"
    cat "$err"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  sleep 1
  st=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)
  if [ "$st" != "true" ]; then
    bad "$name is not running"
    docker logs --tail 40 "$name" 2>&1 | cut -c1-300
    return 1
  fi
  echo "  started $name"
}

# Anything whose name looks like part of an Immich stack, plus our own leftovers.
OLD=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'immich|pgvecto' || true)

say "This will DELETE and rebuild Immich on this server:"
for c in $OLD; do echo "    container   $c"; done
[ -d "$APPDATA" ] && echo "    appdata     $APPDATA  (database + config)"
[ -d /mnt/user/appdata/PostgreSQL_Immich ] && echo "    appdata     /mnt/user/appdata/PostgreSQL_Immich  (old database)"
for c in $OLD; do
  f=$(grep -l "<Name>$c</Name>" "$TPLDIR"/*.xml 2>/dev/null | head -1)
  [ -n "$f" ] && echo "    template    $f"
done
echo "    KEEPS       $PHOTOS  (your photos are not touched)"
echo
if [ "${COUNTDOWN:-15}" -gt 0 ] 2>/dev/null; then
  say "Starting in ${COUNTDOWN} seconds. Press Ctrl-C now to cancel."
  sleep "$COUNTDOWN"
fi

say "removing the old stack"
for c in $OLD; do docker rm -f "$c" && echo "  removed container $c"; done
for c in $OLD; do
  f=$(grep -l "<Name>$c</Name>" "$TPLDIR"/*.xml 2>/dev/null | head -1)
  [ -n "$f" ] && rm -f "$f" && echo "  removed template $f"
done
wipe_appdata "$APPDATA"
for d in /mnt/user/appdata/PostgreSQL_Immich /mnt/user/appdata/immich-postgres; do
  [ -d "$d" ] && wipe_appdata "$d"
done
mkdir -p "$APPDATA/postgres" "$PHOTOS" || { bad "could not create $APPDATA"; exit 1; }

say "pulling current images (a few minutes on a slow line)"
for i in "$IMG_DB" "$IMG_RD" "$IMG_SRV" "$IMG_ML"; do
  docker pull "$i" && echo "  pulled $i" || { bad "could not pull $i"; exit 1; }
done

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" || { bad "could not create network $NET"; exit 1; }
docker volume create immich-model-cache >/dev/null 2>&1 || true

say "starting the database"
start_ctr immich_postgres --network "$NET" --restart unless-stopped \
  --shm-size 128m \
  -e POSTGRES_PASSWORD="$DBPASS" -e POSTGRES_USER=postgres -e POSTGRES_DB=immich \
  -e POSTGRES_INITDB_ARGS=--data-checksums \
  -v "$APPDATA/postgres":/var/lib/postgresql/data \
  "$IMG_DB" || exit 1

say "waiting for the database to accept connections"
t=0
while [ $t -lt 120 ]; do
  if docker exec immich_postgres pg_isready -U postgres >/dev/null 2>&1; then
    ok "database ready after ${t}s"
    break
  fi
  st=$(docker inspect -f '{{.State.Running}}' immich_postgres 2>/dev/null || echo false)
  if [ "$st" != "true" ]; then
    bad "database container stopped"
    docker logs --tail 40 immich_postgres 2>&1 | cut -c1-300
    exit 1
  fi
  sleep 2; t=$((t+2))
done
if [ $t -ge 120 ]; then
  bad "database did not become ready in 120s"
  docker logs --tail 40 immich_postgres 2>&1 | cut -c1-300
  exit 1
fi

say "starting the cache"
start_ctr immich_redis --network "$NET" --restart unless-stopped "$IMG_RD" || exit 1

say "starting machine learning"
start_ctr immich_machine_learning --network "$NET" --restart unless-stopped \
  -v immich-model-cache:/cache "$IMG_ML" || warn "machine learning failed to start (search by face/object will be off)"

say "starting Immich"
start_ctr immich_server --network "$NET" --restart unless-stopped \
  -p "$PORT":2283 \
  -e DB_HOSTNAME=immich_postgres -e DB_PORT=5432 \
  -e DB_USERNAME=postgres -e DB_PASSWORD="$DBPASS" -e DB_DATABASE_NAME=immich \
  -e REDIS_HOSTNAME=immich_redis \
  -e "TZ=$(cat /etc/timezone 2>/dev/null || echo America/New_York)" \
  -v "$PHOTOS":/data -v /etc/localtime:/etc/localtime:ro \
  "$IMG_SRV" || exit 1

IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
URL="http://${IP:-127.0.0.1}:$PORT/"

say "waiting for Immich to finish setting up its database (up to 5 minutes)"
t=0
code=000
while [ $t -lt 300 ]; do
  st=$(docker inspect -f '{{.State.Running}}' immich_server 2>/dev/null || echo false)
  if [ "$st" != "true" ]; then
    bad "Immich container stopped after ${t}s"
    echo "-- immich_server --"; docker logs --tail 40 immich_server 2>&1 | cut -c1-300
    echo "-- immich_postgres --"; docker logs --tail 20 immich_postgres 2>&1 | cut -c1-300
    warn "Screenshot the lines above for Mike."
    exit 1
  fi
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
  case "$code" in 200|302) ok "Immich is up after ${t}s."; ok "Open it at: $URL"; ok "Click 'Getting Started' and make your admin account."; exit 0;; esac
  sleep 10; t=$((t+10))
done

bad "Immich did not answer within 5 minutes (last HTTP ${code:-000})."
echo "-- immich_server --"; docker logs --tail 30 immich_server 2>&1 | cut -c1-300
echo "-- immich_postgres --"; docker logs --tail 15 immich_postgres 2>&1 | cut -c1-300
warn "Screenshot the lines above for Mike."
exit 1
