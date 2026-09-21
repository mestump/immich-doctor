#!/bin/bash
# Import a Google Photos Takeout into Immich on this Unraid box. One command:
#   curl -fsSL https://mestump.github.io/immich-doctor/import.sh | bash
#
# It finds the takeout archives you downloaded, works out whether they are
# loose part-zips, a Chrome-merged wrapper zip, or an already-unzipped folder,
# downloads a matching immich-go binary, and drives the import with immich-go's
# own progress screen. Re-running the same command is safe: files already on
# the server are recognised and skipped, so an interrupted import finishes
# instead of duplicating.
#
# Your downloads are never moved or deleted unless you answer yes at the end.
#
# Portability notes for future edits: Unraid ships busybox variants of several
# coreutils (see the v6 lesson in Immich-Doctor-2026-09-19: `tail -c` broke a
# doctor run there), so this script stays on flags busybox definitely has:
# du -sk not du -sb, no `tail -c`, and no find -size (glob + stat instead).
# No `set -o pipefail`: `unzip -Z1 | head` would "fail" on SIGPIPE for every
# valid big zip; each command that matters is checked on its own instead.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

IG_VERSION="${IG_VERSION:-v0.32.0}"
IG_BINDIR="${IG_BINDIR:-/mnt/user/appdata/immich-doctor/bin}"
IG_CONF="${IG_CONF:-/mnt/user/appdata/immich-doctor/takeout.conf}"
IG_WORK="${IG_WORK:-}"                    # empty = <downloads dir>/.takeout-work
IG_EXTRA_DIRS="${IG_EXTRA_DIRS:-}"        # extra scan dirs, ':'-separated
IG_MIN_ZIP_MB="${IG_MIN_ZIP_MB:-20}"      # size floor for shared folders
IG_ASSUME_YES="${IG_ASSUME_YES:-0}"       # 1 = no confirmations (tests/cron)
IG_FORCE="${IG_FORCE:-0}"                 # 1 = re-import archives marked done
IG_SERVER="${IG_SERVER:-}"                # set to skip autodetect
IG_KEY="${IG_KEY:-}"                      # set to skip the prompt
IG_TUI="${IG_TUI:-auto}"                  # auto|off
IG_DONE_LIST="${IG_DONE_LIST:-$IG_BINDIR/imported.txt}"
IG_ALLOW_NONROOT="${IG_ALLOW_NONROOT:-0}" # test hook
IG_SERVER_ENV="$IG_SERVER"; IG_KEY_ENV="$IG_KEY"   # env wins over saved config

say()  { printf '\033[1;34m[import]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; exit 1; }

# read from the terminal, never from the curl pipe
ask()        { printf '%s' "$1" >&2; local v=""; IFS= read -r v </dev/tty || true; printf '%s' "$v"; }
ask_secret() { printf '%s' "$1" >&2; local v=""; IFS= read -rs v </dev/tty || true; printf '\n' >&2; printf '%s' "$v"; }
confirm() { # confirm "prompt" -> 0 for yes
  [ "$IG_ASSUME_YES" = 1 ] && return 0
  [ -t 1 ] || return 1                      # nobody there to answer: keep files
  local a; a=$(ask "$1 [y/N] ")
  case "$a" in [yY]*) return 0;; *) return 1;; esac
}
confirm_always() { # like confirm but ignores ASSUME_YES (deleting downloads)
  [ -t 1 ] || return 1
  local a; a=$(ask "$1 [y/N] ")
  case "$a" in [yY]*) return 0;; *) return 1;; esac
}

# ---------------------------------------------------------------- archive scan

# first 400 entries of a zip, SIGPIPE-safe (no pipefail above for this reason)
zip_listing() { unzip -Z1 "$1" 2>/dev/null | awk 'NR<=400'; }

# zip_kind FILE -> wrapper | takeout | junk
# wrapper: the zip's entries contain other .zip files — Chrome merges the
# parts of a big takeout into one file like this. immich-go does NOT descend
# into nested zips: it discovers zero assets and exits 0 silently. A wrapper
# must therefore be unpacked one level before importing.
# takeout: a Google Photos archive at any of the layouts Google has shipped:
# 2024+ (Photos/...), older (Takeout/Google Photos/...), or an album-only
# export (GooglePhotos.json + history.json at the root).
zip_kind() {
  local f="$1" listing side
  listing=$(zip_listing "$f")
  [ -z "$listing" ] && { echo junk; return; }
  if printf '%s\n' "$listing" | grep -qiE '\.zip$'; then echo wrapper; return; fi
  if printf '%s\n' "$listing" | grep -qiE '^(Takeout/|Photos/|Google Photos/|GooglePhotos\.json|history\.json)'; then
    echo takeout; return
  fi
  # a pile of per-photo sidecars is a takeout even without a marker folder
  side=$(printf '%s\n' "$listing" | grep -ciE '\.(jpg|jpeg|png|heic|heif|webp|mp4|mov|avi|mkv|mts|m2ts)\.json$' || true)
  if [ "${side:-0}" -ge 3 ]; then echo takeout; return; fi
  echo junk
}

takeout_dir() { # DIR -> takeout | junk
  local d="$1"
  if [ -d "$d/Takeout" ] || [ -d "$d/Photos" ] || [ -d "$d/Google Photos" ] \
     || [ -f "$d/GooglePhotos.json" ] || [ -f "$d/history.json" ]; then
    echo takeout
  else
    echo junk
  fi
}

# bundle_key PATH -> groups the parts of one takeout so a single immich-go
# call sees every part of a split album. Google names the parts
# takeout-<YYYYMMDDTHHMMSSZ>-<n> of <N>.zip; the shared 14-digit timestamp is
# the key. Anything else is its own bundle.
bundle_key() {
  local base; base=$(basename "$1" | tr 'A-Z' 'a-z')
  local ts; ts=$(printf '%s' "$base" | grep -oE '[0-9]{8}t[0-9]{6}z' | head -1)
  if [ -n "$ts" ]; then printf 'ts:%s' "$ts"; else printf 'f:%s' "$base"; fi
}

path_bytes() { # file-or-dir -> bytes
  if [ -d "$1" ]; then
    local k; k=$(du -sk "$1" 2>/dev/null | cut -f1); printf '%s' "$(( ${k:-0} * 1024 ))"
  else
    stat -c%s "$1" 2>/dev/null || echo 0
  fi
}

# scan_dir DIR MIN_MB -> candidate paths: zips at depth 1-2 over the size
# floor, plus plain subdirectories (an unzipped takeout is a folder)
scan_dir() {
  local d="$1" floor="$2" f b
  [ -d "$d" ] || return 0
  for f in "$d"/*.zip "$d"/*/*.zip; do
    [ -f "$f" ] || continue
    case "$(dirname "$f")" in */.*) continue ;; esac
    b=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [ "$b" -ge $((floor * 1024 * 1024)) ] && printf '%s\n' "$f"
  done
  for f in "$d"/*/; do
    [ -d "$f" ] || continue
    case "$(basename "$f")" in .*) continue ;; esac
    printf '%s\n' "${f%/}"
  done
  return 0
}

# ------------------------------------------------------------------- immich-go

IG_BIN=""

ig_install() {
  mkdir -p "$IG_BINDIR" || die "can't write to $IG_BINDIR"
  local bin="$IG_BINDIR/immich-go" verfile="$IG_BINDIR/.version"
  if [ -x "$bin" ] && [ "$(cat "$verfile" 2>/dev/null)" = "$IG_VERSION" ]; then
    ok "immich-go $IG_VERSION is already installed"; IG_BIN="$bin"; return
  fi
  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64)          arch=x86_64 ;;
    aarch64|arm64)   arch=arm64 ;;
    *) die "there is no immich-go build for CPU type $arch" ;;
  esac
  local base="https://github.com/simulot/immich-go/releases/download/$IG_VERSION"
  local tgz="immich-go_Linux_$arch.tar.gz" tmp; tmp=$(mktemp -d)
  say "downloading immich-go $IG_VERSION ..."
  curl -fsSL --retry 3 -o "$tmp/$tgz" "$base/$tgz" || { rm -rf "$tmp"; die "download failed — check that this box has internet access"; }
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/checksums.txt" || { rm -rf "$tmp"; die "download failed (checksums)"; }
  local want; want=$(awk -v f="$tgz" '$2==f{print $1}' "$tmp/checksums.txt")
  [ -n "$want" ] || { rm -rf "$tmp"; die "$tgz is not in release $IG_VERSION"; }
  local got; got=$(sha256sum "$tmp/$tgz" | cut -d' ' -f1)
  [ "$want" = "$got" ] || { rm -rf "$tmp"; die "checksum mismatch for $tgz — refusing to run it"; }
  tar -xzf "$tmp/$tgz" -C "$tmp" immich-go || { rm -rf "$tmp"; die "can't unpack $tgz"; }
  mv "$tmp/immich-go" "$bin" && chmod 755 "$bin" && printf '%s' "$IG_VERSION" > "$verfile"
  rm -rf "$tmp"
  ok "immich-go $IG_VERSION installed"
  IG_BIN="$bin"
}

ig_url_probe() { curl -fsS -m 5 "$1/" 2>/dev/null | grep -qi immich; }   # URL -> 0 when Immich answers

ig_detect_server() {
  local port
  port=$(docker port immich 8080/tcp 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  [ -z "$port" ] && port=$(docker port immich 2283/tcp 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  if [ -n "$port" ] && ig_url_probe "http://127.0.0.1:$port"; then
    printf 'http://127.0.0.1:%s' "$port"; return 0
  fi
  local p
  for p in 2283 8082; do
    ig_url_probe "http://127.0.0.1:$p" && { printf 'http://127.0.0.1:%s' "$p"; return 0; }
  done
  return 1
}

ig_admin()     { curl -fsS -m 10 -H "x-api-key: $2" "$1/api/users/me" 2>/dev/null | grep -q '"isAdmin":[[:space:]]*true'; }   # URL KEY

ig_key_valid() { curl -fsS -m 10 -H "x-api-key: $2" "$1/api/users/me" >/dev/null 2>&1; }   # URL KEY
# ig_server_total URL KEY -> number of assets this user has on the server
ig_server_total() { curl -fsS -m 10 -H "x-api-key: $2" "$1/api/assets/statistics" 2>/dev/null | grep -oE '"total": *[0-9]+' | head -1 | cut -d: -f2; }

# ------------------------------------------------------------ import execution

IG_SERVER=""; IG_KEY=""; IG_IS_ADMIN=0; WORK=""

# one_bundle KEY LABEL PATH... -> import one takeout bundle; 0 on success
one_bundle() {
  local key="$1" label="$2"; shift 2
  local log
  log="$WORK/immich-go-$(printf '%s' "$key" | tr ':/' '__').log"
  local args=(upload from-google-photos --server "$IG_SERVER" --api-key "$IG_KEY"
              --log-file "$log" --log-level INFO --on-errors continue)
  if [ "$IG_IS_ADMIN" = 1 ]; then
    args+=(--admin-api-key "$IG_KEY")          # lets immich-go pause background jobs during the upload
  else
    args+=(--pause-immich-jobs=false)          # pausing jobs needs an admin key; without it immich-go refuses to start
  fi

  echo
  say "Importing $label ($# archive$( [ $# -gt 1 ] && echo s))"
  say "progress below; every step is also written to $log"
  local rc=0
  if [ "$IG_TUI" = auto ] && [ -t 1 ]; then
    "$IG_BIN" "${args[@]}" "$@" </dev/tty || rc=$?     # tview needs a terminal; curl|bash owns stdin
  else
    "$IG_BIN" "${args[@]}" --no-ui "$@" || rc=$?
  fi
  if [ $rc -eq 0 ]; then
    ok "$label finished"
    mkdir -p "$(dirname "$IG_DONE_LIST")"
    printf '%s\t%s\n' "$key" "$(date -u +%FT%TZ)" >> "$IG_DONE_LIST"
  else
    warn "$label stopped with an error (code $rc) — nothing of yours was deleted."
    warn "Run the same command again to pick up where it stopped. Last lines of the log:"
    tail -n 6 "$log" 2>/dev/null | sed 's/^/      /'
  fi
  return $rc
}

# ------------------------------------------------------------------------ main

main() {
  if [ "$(id -u)" != 0 ] && [ "$IG_ALLOW_NONROOT" != 1 ]; then
    die "please run this as root (the Unraid web terminal is root by default)"
  fi
  for t in curl tar unzip sha256sum awk grep sed df stat du; do
    command -v "$t" >/dev/null || die "this box is missing '$t', which is needed to unpack the archives"
  done

  if [ -f "$IG_CONF" ]; then . "$IG_CONF"; fi
  IG_SERVER="${IG_SERVER_ENV:-$IG_SERVER}"; IG_KEY="${IG_KEY_ENV:-$IG_KEY}"

  # 1. the Immich server
  if [ -z "$IG_SERVER" ]; then
    say "looking for Immich on this box ..."
    IG_SERVER=$(ig_detect_server) || true
  fi
  [ -n "$IG_SERVER" ] || IG_SERVER=$(ask "I could not find Immich on this box. Type its address, like http://192.168.1.10:2283 : ")
  ig_url_probe "$IG_SERVER" || die "no Immich page at $IG_SERVER — start Immich, then run this again"
  ok "Immich found at $IG_SERVER"

  # 2. the API key
  if [ -n "$IG_KEY" ] && ! ig_key_valid "$IG_SERVER" "$IG_KEY"; then
    warn "the saved API key no longer works"
    IG_KEY=""
  fi
  while [ -z "$IG_KEY" ]; do
    [ -t 1 ] || die "Immich needs an API key: run this in a terminal, or set IG_KEY=... (Immich > My Account > App Keys)"
    echo "In Immich: click your picture (top right) > My Account > App Keys > New Key," >&2
    echo "type a name like 'import', press COPY on the key, then paste it here." >&2
    IG_KEY=$(ask_secret "API key: ")
    ig_key_valid "$IG_SERVER" "$IG_KEY" || { warn "Immich did not accept that key"; IG_KEY=""; }
  done
  mkdir -p "$(dirname "$IG_CONF")"
  printf 'IG_SERVER=%q\nIG_KEY=%q\n' "$IG_SERVER" "$IG_KEY" > "$IG_CONF" && chmod 600 "$IG_CONF"
  IG_IS_ADMIN=0; ig_admin "$IG_SERVER" "$IG_KEY" && IG_IS_ADMIN=1

  # 3. the archives. root's own Downloads is where a browser on the box puts
  # files, so it is trusted fully; shared folders get the size floor so
  # unrelated app zips aren't chased.
  local -a dirs=(/root/Downloads /root/download /mnt/user/downloads /mnt/user/Downloads /mnt/user/data)
  local -a floors=(0 0 "$IG_MIN_ZIP_MB" "$IG_MIN_ZIP_MB" "$IG_MIN_ZIP_MB")
  if [ -n "$IG_EXTRA_DIRS" ]; then
    local d oldIFS=$IFS; IFS=':'
    for d in $IG_EXTRA_DIRS; do dirs+=("$d"); floors+=("$IG_MIN_ZIP_MB"); done
    IFS=$oldIFS
  fi
  local -a cand=()
  while :; do
    cand=()
    local i line
    for i in "${!dirs[@]}"; do
      while IFS= read -r line; do cand+=("$line"); done < <(scan_dir "${dirs[$i]}" "${floors[$i]}")
    done
    [ ${#cand[@]} -gt 0 ] && break
    local more; more=$(ask "No takeout archive found in: ${dirs[*]}. Type the folder it is in, or press Enter to stop: ")
    [ -z "$more" ] && die "nothing to import — put the downloaded takeout zip file(s) in a folder and run this again"
    [ -d "$more" ] || { warn "$more is not a folder"; continue; }
    dirs+=("$more"); floors+=("$IG_MIN_ZIP_MB")
  done

  # classify + group into bundles (values are newline-separated: paths may hold spaces)
  declare -A BUNDLE=()
  local n_found=0 c kind key p
  for c in "${cand[@]}"; do
    if [ -d "$c" ]; then kind=$(takeout_dir "$c"); else kind=$(zip_kind "$c"); fi
    [ "$kind" = junk ] && continue
    n_found=$((n_found + 1))
    key=$(bundle_key "$c")
    if [ -n "${BUNDLE[$key]:-}" ]; then
      BUNDLE[$key]="${BUNDLE[$key]}"$'\n'"$kind:$c"
    else
      BUNDLE[$key]="$kind:$c"
    fi
  done
  [ $n_found -gt 0 ] || die "the folders I searched contain zip files, but none of them look like a Google Photos takeout"

  # skip bundles recorded as finished on an earlier run. But if the server
  # looks empty anyway (a re-install wiped its database while this done-list
  # survived), those records are stale — ask before trusting them.
  if [ "$IG_FORCE" != 1 ] && [ -s "$IG_DONE_LIST" ]; then
    local on_server; on_server=$(ig_server_total "$IG_SERVER" "$IG_KEY")
    if [ "${on_server:-x}" = "0" ] && confirm "Immich looks empty, though an earlier run says photos were imported. Import everything again?"; then
      IG_FORCE=1
    fi
  fi
  if [ "$IG_FORCE" != 1 ] && [ -s "$IG_DONE_LIST" ]; then
    for key in "${!BUNDLE[@]}"; do
      awk -F'\t' -v k="$key" '$1==k{f=1} END{exit !f}' "$IG_DONE_LIST" && unset "BUNDLE[$key]"
    done
    [ ${#BUNDLE[@]} -eq 0 ] && { ok "everything I found was already imported — run this again after your next download"; exit 0; }
  fi

  echo
  say "found:"
  for key in "${!BUNDLE[@]}"; do
    local sz=0 first_entry
    while IFS= read -r p; do sz=$((sz + $(path_bytes "${p#*:}"))); done <<< "${BUNDLE[$key]}"
    first_entry=$(printf '%s\n' "${BUNDLE[$key]}" | head -1 | cut -d: -f2-)
    printf '   %6d MB   %s\n' $((sz/1024/1024)) "$(basename "$first_entry")"
  done
  confirm "Start the import?" || die "noted — run the same command again whenever you are ready"

  # 4. working space on the same share as the downloads (Unraid's /tmp is RAM)
  local -a bkeys=("${!BUNDLE[@]}")
  local first; first=$(printf '%s\n' "${BUNDLE[${bkeys[0]}]}" | head -1 | cut -d: -f2-)
  WORK="${IG_WORK:-$(dirname "$first")/.takeout-work}"
  mkdir -p "$WORK" || die "can't create the working folder $WORK"
  local need=0
  for key in "${!BUNDLE[@]}"; do
    while IFS= read -r p; do
      case "$p" in wrapper:*) need=$((need + $(path_bytes "${p#*:}"))) ;; esac
    done <<< "${BUNDLE[$key]}"
  done
  local avail; avail=$(( $(df -Pk "$WORK" | awk 'NR==2{print $4}') * 1024 ))
  [ $need -le $avail ] || \
    die "unzipping the merged download needs $((need/1024/1024)) MB free, and that share has $((avail/1024/1024)) MB free — free some space and run this again"

  ig_install

  # 5. import, one takeout bundle at a time
  local fails=0
  for key in "${!BUNDLE[@]}"; do
    local -a parts=()
    local wdir=""
    while IFS= read -r p; do
      case "$p" in
        wrapper:*)
          local f="${p#*:}"
          wdir="$WORK/unpacked-$(printf '%s' "$key" | tr ':/' '__')"
          mkdir -p "$wdir"
          say "unzipping the merged download $(basename "$f") ..."
          # -j flattens: Chrome nests the parts under a folder inside the wrapper
          ( cd "$wdir" && unzip -oqj "$f" '*.zip' ) || { warn "could not unpack $f"; fails=$((fails+1)); continue; }
          local z
          for z in "$wdir"/*.zip; do
            [ -e "$z" ] || continue
            case "$(zip_kind "$z")" in
              takeout) parts+=("$z") ;;
              *) warn "ignoring unexpected file inside $(basename "$f"): $(basename "$z")" ;;
            esac
          done
          ;;
        takeout:*) parts+=("${p#*:}") ;;
      esac
    done <<< "${BUNDLE[$key]}"
    [ ${#parts[@]} -eq 0 ] && { [ -n "$wdir" ] && rm -rf "$wdir"; continue; }
    local label; label="$(basename "${parts[0]}")"
    [ ${#parts[@]} -gt 1 ] && label="$label (and $((${#parts[@]}-1)) other part(s) of the same takeout)"
    one_bundle "$key" "$label" "${parts[@]}" || fails=$((fails+1))
    [ -n "$wdir" ] && rm -rf "$wdir"
  done

  # 6. report
  echo
  if [ $fails -eq 0 ]; then
    ok "All done — your photos are in Immich: $IG_SERVER"
    local tot=0 p2
    local -a keep=()
    for key in "${!BUNDLE[@]}"; do
      while IFS= read -r p2; do
        [ -e "${p2#*:}" ] && tot=$((tot + $(path_bytes "${p2#*:}"))) && keep+=("${p2#*:}")
      done <<< "${BUNDLE[$key]}"
    done
    # deleting downloads always asks, even with ASSUME_YES (unattended runs keep files)
    if [ ${#keep[@]} -gt 0 ] && confirm_always "Delete the download(s) now to free about $((tot/1024/1024)) MB?"; then
      for p2 in "${keep[@]}"; do
        [ -f "$p2" ] && rm -f "$p2"
        [ -d "$p2" ] && confirm_always "Also delete the folder $p2?" && rm -rf "$p2"
      done
      ok "downloads deleted"
    fi
    rmdir "$WORK" 2>/dev/null || true
  else
    warn "$fails takeout(s) did not finish. Nothing of yours was deleted."
    warn "Run the same command again — finished archives are skipped automatically."
    exit 1
  fi
}

if [ -z "${IG_LIB_ONLY:-}" ]; then main "$@"; fi
