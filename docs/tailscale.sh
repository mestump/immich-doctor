#!/bin/bash
# Join an Unraid box to a Tailscale tailnet so Immich is reachable from anywhere.
#
#   curl -fsSL https://mestump.github.io/immich-doctor/tailscale.sh | bash -s -- tskey-auth-XXXX
#
# Run this in the Unraid web terminal (it is root). Needs an auth key from
# https://login.tailscale.com/admin/settings/keys — Generate auth key, leave
# everything at its defaults, then copy the long tskey-auth-... string.
#
# With no key it just reports status, so re-running the same line is safe.
#
# Env overrides: STATE_DIR (default /mnt/user/appdata/tailscale),
#                IMMICH_PORT (default 2283), HOSTNAME_ADVERTISE.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

say() { printf '\033[1;34m[tailscale]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

KEY="${1:-${TS_AUTHKEY:-}}"
STATE_DIR="${STATE_DIR:-/mnt/user/appdata/tailscale}"
IMMICH_PORT="${IMMICH_PORT:-2283}"
IMG="tailscale/tailscale:latest"

command -v docker >/dev/null || { bad "docker not found — run this in the Unraid terminal"; exit 1; }

ts_ip() { docker exec tailscale tailscale ip -4 2>/dev/null | head -1; }
ts_logged_in() { docker exec tailscale tailscale status >/dev/null 2>&1; }

report() {
  local ip host
  ip=$(ts_ip)
  host=$(docker exec tailscale tailscale status --peers=false 2>/dev/null | head -1 | awk '{print $2}')
  [ -n "$ip" ] || return 1
  ok "this box is on the tailnet as ${host:-$(hostname)} at $ip"
  echo
  say "Immich from any device on your Tailscale account:"
  echo "    http://$ip:$IMMICH_PORT/api"
  echo
  say "Phone: install Tailscale, sign in to the SAME account, switch it ON,"
  say "then open the Immich app and enter the URL above as the server endpoint."
  return 0
}

if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx tailscale; then
  [ -n "$KEY" ] || { bad "Tailscale is not installed here yet and no auth key was given.
Get one at https://login.tailscale.com/admin/settings/keys (Generate auth key),
then paste the command again with the key at the end:
  curl -fsSL https://mestump.github.io/immich-doctor/tailscale.sh | bash -s -- tskey-auth-XXXX"; exit 1; }
fi

# Already joined? Nothing to do.
if ts_logged_in; then
  say "Tailscale is already running here."
  report && exit 0
fi

# A tailscale interface needs /dev/net/tun. Unraid ships the module but does not
# always load it, and without it the container starts and never gets an address.
if [ ! -c /dev/net/tun ]; then
  say "loading the tun module"
  modprobe tun >/dev/null 2>&1 || warn "could not load tun — Tailscale may not get an address"
fi
[ -c /dev/net/tun ] || { bad "/dev/net/tun is missing. Reboot the box and run this again."; exit 1; }

# Guard the state dir the same way install.sh guards the appdata wipe.
case "$STATE_DIR" in
  /mnt/user/appdata/?*) ;;
  *) bad "refusing to keep Tailscale state in $STATE_DIR (must be under /mnt/user/appdata/...)"; exit 1;;
esac
mkdir -p "$STATE_DIR" || { bad "could not create $STATE_DIR"; exit 1; }

HN="${HOSTNAME_ADVERTISE:-$(hostname)}"

say "installing Tailscale"
docker rm -f tailscale >/dev/null 2>&1
# --net=host puts the 100.x address on the Unraid host itself, so Immich's
# published port is reachable at http://<tailscale-ip>:<port> with no subnet
# routes or port forwarding.
docker run -d --name tailscale --restart unless-stopped \
  --net=host --cap-add NET_ADMIN --cap-add NET_RAW \
  --device /dev/net/tun \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=false \
  -e TS_HOSTNAME="$HN" \
  ${KEY:+-e TS_AUTHKEY="$KEY"} \
  -v "$STATE_DIR":/var/lib/tailscale \
  "$IMG" || { bad "could not start the Tailscale container"; exit 1; }

say "waiting for Tailscale to register (up to 60s)"
t=0
while [ $t -lt 60 ]; do
  if report; then
    [ -n "$KEY" ] && warn "Delete that auth key in the Tailscale admin console now — it is only needed once."
    exit 0
  fi
  sleep 5; t=$((t+5))
done

bad "Tailscale did not get an address within 60s"
docker logs --tail 30 tailscale 2>&1 | cut -c1-300
warn "Screenshot this for Mike."
exit 1
