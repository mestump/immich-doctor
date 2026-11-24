#!/bin/bash
# Pop's Migrator — TUI that imports Google Photos Takeouts into Immich, with an
# AI helper that answers questions and investigates failures.
#
# One command (Unraid web terminal, root):
#   curl -fsSL https://mestump.github.io/immich-doctor/migrate.sh | bash
#
# Also fine to run directly after the first time:  /mnt/user/appdata/immich-doctor/bin/migrate.sh
# Extras:  migrate.sh update      refresh the app from the repo
#          migrate.sh scan DIR    show what would be imported, no UI
#
# Nothing is deleted without asking. Finished parts are skipped on re-runs.
# Portability: same busybox rules as import.sh — no pipefail, no GNU-only flags.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

MIG_HOME="${MIG_HOME:-/mnt/user/appdata/immich-doctor}"
MIG_BIN="$MIG_HOME/bin"
MIG_URL="${MIG_URL:-https://mestump.github.io/immich-doctor/migrate.py}"
SCRIPT="$MIG_BIN/migrate.py"
PY="${MIG_PYTHON:-3.12}"

say()  { printf '\033[1;34m[migrate]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; exit 1; }

if [ "$(id -u)" != 0 ] && [ "${MIG_ALLOW_NONROOT:-0}" != 1 ]; then
  die "please run as root (the Unraid web terminal is root by default), or set MIG_ALLOW_NONROOT=1"
fi

if [ "${1:-}" = update ]; then
  REFRESH=1
else
  REFRESH=0
fi

mkdir -p "$MIG_BIN" || die "cannot create $MIG_BIN"

# --- 1. the app -------------------------------------------------------------
fetch_app() {
  local tmp="$SCRIPT.new"
  curl -fsSL --retry 2 -o "$tmp" "$MIG_URL" || return 1
  mv "$tmp" "$SCRIPT"
  return 0
}
if [ "$REFRESH" = 1 ] || [ ! -f "$SCRIPT" ]; then
  say "fetching the migrator (${MIG_URL}) ..."
  if fetch_app; then
    ok "app updated"
  elif [ -f "$SCRIPT" ]; then
    warn "could not download an update; using the copy from last time"
  else
    die "could not download $MIG_URL — check this box has internet access"
  fi
fi

# --- 2. uv (runs the app with its own python; nothing else to install) ------
UV=""
if [ -x "$MIG_BIN/uv" ]; then
  UV="$MIG_BIN/uv"
elif command -v uv >/dev/null 2>&1; then
  UV="$(command -v uv)"
else
  say "installing uv into $MIG_BIN (one-time, about 20 MB) ..."
  tmp="$(mktemp)"
  curl -fsSL --retry 2 -o "$tmp" https://astral.sh/uv/install.sh || die "could not download the uv installer"
  UV_UNMANAGED_INSTALL="$MIG_BIN" sh "$tmp" >/dev/null || die "uv install failed"
  rm -f "$tmp"
  [ -x "$MIG_BIN/uv" ] || die "uv installer ran but $MIG_BIN/uv is missing"
  UV="$MIG_BIN/uv"
  ok "uv installed"
fi

# keep python + caches on the array so they survive reboots (Unraid /root is tmpfs)
export UV_PYTHON_INSTALL_DIR="$MIG_HOME/python"
export UV_CACHE_DIR="$MIG_HOME/uv-cache"

# --- 3. run -----------------------------------------------------------------
if [ "$REFRESH" = 1 ]; then
  ok "updated. run again without 'update' to start the migrator."
  exit 0
fi
exec "$UV" run --no-project --python "$PY" "$SCRIPT" "$@"
