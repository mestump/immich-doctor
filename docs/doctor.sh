#!/usr/bin/env bash
# Immich doctor — one-shot diagnose + AI-fix for an Immich stack on Unraid.
# Usage (as root in the Unraid web terminal):
#   curl -fsSL https://mestump.github.io/immich-doctor/doctor.sh | bash -s -- <API_KEY>
#
# Collects a diagnostic bundle, sends it to the Spark model behind
# llm.plexivision.tv, applies vetted fix commands, re-verifies, reports.
set -u

API_KEY="${1:-}"
API_URL="${API_URL:-https://llm.plexivision.tv/v1/chat/completions}"
MODEL="${MODEL:-spark-prod}"
SELF_URL="${SELF_URL:-https://immich.plexivision.tv/api}"

say() { printf '\033[1;34m[doctor]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }

[ "$(id -u)" = "0" ] || say "warning: not root; docker/logs may be incomplete"

TMP="$(mktemp -d /tmp/immich-doctor.XXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- gather
say "collecting diagnostics..."
BUNDLE="$TMP/bundle.txt"
cap() { # cap LABEL CMD...  -> run cmd, keep first 4000 chars
  local label="$1"; shift
  { printf '\n===== %s =====\n' "$label"; "$@" 2>&1 | head -c 4000; printf '\n'; } >>"$BUNDLE"
}
: >"$BUNDLE"
printf '===== host =====\n' >>"$BUNDLE"
{ hostname; cat /etc/unraid-version 2>/dev/null || uname -a; uptime; } >>"$BUNDLE" 2>&1

cap "docker ps (immich)" docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
cap "docker disk usage" df -h /mnt/user /var/lib/docker 2>/dev/null || true
cap "free mem" free -m
cap "listeners 2283/8080/3001" ss -lntp
cap "local probes" bash -c 'for p in 2283 8080 3001; do
  printf "port %s: " "$p"
  curl -s -m 4 -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:${p}/api" 2>/dev/null || echo fail
done; curl -s -m 8 -o /dev/null -w "public %s\n" "%{http_code}" '"$SELF_URL"''

for c in immich immich-server immich_postgres immich-postgres immich_redis immich-redis immich-machine-learning; do
  if docker inspect "$c" >/dev/null 2>&1; then
    cap "inspect $c" docker inspect -f 'restart={{.HostConfig.RestartPolicy.Name}} status={{.State.Status}} started={{.State.StartedAt}} OOM={{.State.OOMKilled}} exitcode={{.State.ExitCode}} ports={{json .NetworkSettings.Ports}}' "$c"
    cap "logs $c (tail60)" docker logs --tail 60 "$c"
  fi
done

# ---------------------------------------------------------------- ask Spark
say "asking Spark to assess ($API_URL)..."
PAYLOAD="$TMP/payload.json"
jq -n --arg b "$(cat "$BUNDLE")" --arg m "$MODEL" '{
  model: $m, temperature: 0.2, max_tokens: 1500,
  messages: [
    {role:"system", content: "You are an Immich-on-Unraid repair agent. You receive a diagnostic bundle from the server. Known traps: Unraid webUI owns port 8080 (an Immich template using host port 8080 never binds); imagegenius template needs separate postgres+redis; official stack uses 2283; restart policy no/never means a crash or reboot keeps it down; unhealthy postgres/redis keeps the web UI down. Reply with STRICT JSON only, no prose, no markdown fences: {\"summary\": \"one or two sentences for a non-expert\", \"severity\": \"ok|minor|major\", \"fix_commands\": [\"shell commands, max 4, safe non-destructive only: docker start/restart/update, docker-compose/docker compose up -d, systemctl restart docker, nothing else\"], \"needs_human\": true|false, \"human_note\": \"what a human must do by hand, empty string if none\"}. If everything is healthy: severity ok, empty fix_commands, needs_human false."},
    {role:"user", content: $b}
  ]}' >"$PAYLOAD"

REPLY=$(curl -sS -m 90 "$API_URL" -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" --data @"$PAYLOAD")
echo "$REPLY" >"$TMP/reply.json"

CONTENT=$(echo "$REPLY" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
if [ -z "${CONTENT:-}" ]; then
  bad "API call failed:"; echo "$REPLY" | head -c 400; echo
  bad "bundle saved for a human at /tmp/immich-doctor-bundle.txt"
  cp "$BUNDLE" /tmp/immich-doctor-bundle.txt
  exit 2
fi
# strip possible markdown fences
CONTENT=$(printf '%s' "$CONTENT" | sed -e 's/^```[a-z]*//' -e 's/```$//')

SUMMARY=$(printf '%s' "$CONTENT" | jq -r '.summary // "?"')
SEV=$(printf '%s' "$CONTENT" | jq -r '.severity // "major"')
HUMAN=$(printf '%s' "$CONTENT" | jq -r '.human_note // ""')
NEEDS_HUMAN=$(printf '%s' "$CONTENT" | jq -r '.needs_human // false')

printf '\n\033[1;36mSPARK SAYS:\033[0m %s\n' "$SUMMARY"

# ---------------------------------------------------------------- apply fixes
APPLIED=0
if [ "$SEV" != "ok" ]; then
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    # guardrail: only non-destructive service commands
    if printf '%s' "$cmd" | grep -qE '^\s*(docker (start|restart|unpause|update|compose (up|restart)|container restart)|docker-compose up|systemctl restart docker|/etc/rc\.d/rc\.docker restart)\b'; then
      say "applying: $cmd"
      timeout 120 bash -c "$cmd" >>"$TMP/fix.log" 2>&1 && ok "done" || bad "command failed (see /tmp/immich-doctor-fix.log)"
      APPLIED=1
    else
      bad "refused unsafe command from model: $cmd"
    fi
  done < <(printf '%s' "$CONTENT" | jq -r '.fix_commands[]? // empty')
fi
[ "$APPLIED" = 1 ] && cp "$TMP/fix.log" /tmp/immich-doctor-fix.log

# ---------------------------------------------------------------- re-verify
say "re-verifying..."
sleep 8
CODE=$(curl -s -m 8 -o /dev/null -w "%{http_code}" http://127.0.0.1:2283/api 2>/dev/null || echo 000)
[ "$CODE" = "000" ] && CODE=$(curl -s -m 8 -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api 2>/dev/null || echo 000)
PCODE=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "$SELF_URL" 2>/dev/null || echo 000)
if echo "$CODE" | grep -qE '200|302|307|401'; then
  ok "Immich API responds locally (HTTP $CODE)"
  if [ "$PCODE" = "200" ] || [ "$PCODE" = "302" ]; then ok "public URL works (HTTP $PCODE) — you are done, open the Immich app"; exit 0
  else bad "local is up but public URL returned HTTP $PCODE — ask Mike to check the router/tunnel"; exit 1; fi
else
  bad "Immich still not answering (HTTP $CODE)"
  [ -n "$HUMAN" ] || [ "$NEEDS_HUMAN" = true ] && printf '\033[1;33mA human needs to help:\033[0m %s\n' "$HUMAN"
  cp "$BUNDLE" /tmp/immich-doctor-bundle.txt
  say "bundle saved to /tmp/immich-doctor-bundle.txt — send it to Mike"
  exit 1
fi
