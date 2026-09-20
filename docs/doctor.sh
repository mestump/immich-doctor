#!/usr/bin/env bash
# Immich doctor v4 — diagnose + AI-repair loop for an Immich stack on Unraid.
# Usage (as root in the Unraid web terminal) — no key needed, it self-fetches:
#   curl -fsSL https://mestump.github.io/immich-doctor/doctor.sh | bash
# Or pass a key explicitly:  ... | bash -s -- sk-...
# Optional: prefix PUBLIC_URL=http://<tailscale-ip-or-host>:2283 to also verify
# the URL you actually use (e.g. over Tailscale). Without it, only local checks run.
#
# Loop: gather -> Spark assesses -> apply safe fixes -> re-verify. Repeats up to
# MAX_ROUNDS (default 3) with fresh evidence each round, until Immich answers or
# the remaining fix genuinely needs a human hand (Unraid GUI edit).

API_KEY="${1:-}"
API_URL="${API_URL:-https://llm.plexivision.tv/v1/chat/completions}"
MODEL="${MODEL:-spark-prod}"
PUBLIC_URL="${PUBLIC_URL:-}"      # e.g. http://100.x.y.z:2283 — verified only if set
MAX_ROUNDS="${MAX_ROUNDS:-3}"
HEAL_WAIT="${HEAL_WAIT:-120}"     # seconds to wait for Immich to come up after fixes

# Self-fetch the key when not passed as an argument (Pages ships doctor-key.txt).
if [ -z "${API_KEY:-}" ]; then
  for cand in "$(dirname "${BASH_SOURCE[0]:-$0}")/doctor-key.txt" ./doctor-key.txt /tmp/doctor-key.txt; do
    if [ -f "$cand" ]; then API_KEY="$(tr -d '[:space:]' < "$cand")"; break; fi
  done
  if [ -z "${API_KEY:-}" ]; then
    API_KEY="$(curl -fsSL -m 15 "${DOCTOR_BASE:-https://mestump.github.io/immich-doctor}/doctor-key.txt" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
fi
if [ -z "${API_KEY:-}" ]; then echo "no API key (arg, doctor-key.txt, or download). ask Mike." >&2; exit 2; fi

say() { printf '\033[1;34m[doctor]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
TMP="$(mktemp -d /tmp/immich-doctor.XXXX)"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ probing
probe_local() {
  # echoes the HTTP code of the Immich web UI (or 000)
  local p c
  for p in 2283 8080; do
    c=$(curl -s -m 6 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${p}/" 2>/dev/null); c=${c:-000}
    echo "$c" | grep -qE '^(200|302|307|401)$' && { echo "$c"; return; }
  done
  for p in $(ss -lnt | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' | sort -un); do
    c=$(curl -s -m 4 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${p}/" 2>/dev/null); c=${c:-000}
    if echo "$c" | grep -qE '^(200|302|307|401)$'; then
      curl -s -m 4 "http://127.0.0.1:${p}/" | grep -qi immich && { echo "$c"; return; }
    fi
  done
  echo 000
}

wait_healthy() { # $1 = seconds to wait
  local deadline=$((SECONDS + ${1:-30})) code
  while :; do
    code=$(probe_local)
    echo "$code" | grep -qE '^(200|302|307|401)$' && { LAST_CODE="$code"; return 0; }
    [ $SECONDS -ge $deadline ] && { LAST_CODE="$code"; return 1; }
    sleep 6
  done
}

# ------------------------------------------------- deterministic safe fixes
fix_restart_policy() {
  # immich containers with restart='no' never come back after a crash/reboot
  local c rp
  for c in $(docker ps -a --format '{{.Names}}' | grep -i immich); do
    rp=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
    if [ "$rp" = "no" ] || [ "$rp" = "none" ]; then
      say "setting restart policy 'unless-stopped' on $c (was: $rp)"
      docker update --restart unless-stopped "$c" >/dev/null 2>&1 && ok "$c will now auto-start after crashes/reboots"
    fi
  done
}

# ------------------------------------------------------------------ gather
gather() { # $1 = bundle path
  local B="$1"
  : >"$B"
  { printf '===== host =====\n'; hostname; cat /etc/unraid-version 2>/dev/null || uname -a; uptime; } >>"$B" 2>&1
  cap() { local label="$1"; shift; { printf '\n===== %s =====\n' "$label"; "$@" 2>&1 | head -c 2500; printf '\n'; } >>"$B"; }
  cap "docker ps (immich)" docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  cap "docker disk usage" df -h /mnt/user /var/lib/docker 2>/dev/null || true
  cap "free mem" free -m
  cap "listeners" ss -lntp
  cap "local probes" bash -c 'for p in 2283 8080 3001; do
    printf "port %s: " "$p"
    curl -s -m 4 -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:${p}/" 2>/dev/null || echo fail
  done; if [ -n "$1" ]; then curl -s -m 8 -o /dev/null -w "user URL %s\n" "%{http_code}" "$1"; fi' _ "$PUBLIC_URL"
  local c
  for c in $(docker ps -a --format '{{.Names}}' | grep -i immich); do
    cap "inspect $c" docker inspect -f 'restart={{.HostConfig.RestartPolicy.Name}} status={{.State.Status}} started={{.State.StartedAt}} OOM={{.State.OOMKilled}} exitcode={{.State.ExitCode}} network={{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}} env={{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null \
      | sed -E 's/(PASSWORD|SECRET|_KEY)=[^ ]*/\1=<redacted>/g'
    cap "logs $c (tail60)" docker logs --tail 60 "$c"
  done
}

# ---------------------------------------------------------------- main loop
if wait_healthy 20; then
  ok "Immich is already answering (HTTP $LAST_CODE)"
  fix_restart_policy
else
  bad "Immich not answering — starting repair loop (max $MAX_ROUNDS rounds)"
fi

HISTORY="(this is the first diagnosis; no fixes applied yet)"
NEEDS_HUMAN=false; HUMAN=""
ROUND=1
for ROUND in $(seq 1 "$MAX_ROUNDS"); do
  if [ "$ROUND" -gt 1 ]; then
    # a previous round's fix may just need longer to land
    wait_healthy "$HEAL_WAIT" && break
  fi

  BUNDLE="$TMP/bundle.$ROUND.txt"
  say "round $ROUND: collecting diagnostics..."
  gather "$BUNDLE"

  say "asking Spark to assess..."
  PAYLOAD="$TMP/payload.$ROUND.json"
  jq -n --arg b "$(cat "$BUNDLE")" --arg h "$HISTORY" --arg m "$MODEL" '{
    model: $m, temperature: 0.2, max_tokens: 1200,
    chat_template_kwargs: {thinking: false},
    messages: [
      {role:"system", content: "You are an Immich-on-Unraid repair agent working in up to 3 rounds. You receive a fresh diagnostic bundle plus the history of what previous rounds tried and whether it worked. Reply with ONLY a JSON object: {\"summary\": one plain-English sentence for a non-technical owner, \"severity\": \"ok|minor|major\", \"fix_commands\": [shell commands a root shell can run right now, non-destructive only: docker start/restart/unpause/update, docker compose up/restart, systemctl restart docker], \"needs_human\": true|false, \"human_note\": exact click-by-click Unraid webGUI instructions if needs_human}. Common Unraid pitfall: a variable was edited in the container TEMPLATE but the container was never recreated, so the RUNNING container still has the old env — that needs needs_human (Docker tab > immich > Edit > Apply > Re-Authorize; data/volumes are not lost). Do NOT repeat a fix_command that history shows already ran without fixing it — change the diagnosis or escalate with needs_human=true."},
      {role:"user", content: ("PREVIOUS ROUNDS:\n" + $h + "\n\nFRESH BUNDLE:\n" + $b)}
    ]}' >"$PAYLOAD"

  REPLY=$(curl -sS -m 240 --retry 2 --retry-delay 5 "$API_URL" -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" --data @"$PAYLOAD")
  echo "$REPLY" >"$TMP/reply.$ROUND.json"
  CONTENT=$(echo "$REPLY" | jq -r '(.choices[0].message.content // .choices[0].message.reasoning) // empty' 2>/dev/null)
  if [ -z "${CONTENT:-}" ]; then
    bad "API call failed:"; echo "$REPLY" | head -c 400; echo
    bad "bundle saved for a human at /tmp/immich-doctor-bundle.txt"
    cp "$BUNDLE" /tmp/immich-doctor-bundle.txt; exit 2
  fi
  CONTENT=$(printf '%s' "$CONTENT" | sed -e 's/^```[a-z]*//' -e 's/```$//')

  SUMMARY=$(printf '%s' "$CONTENT" | jq -r '.summary // "?"')
  SEV=$(printf '%s' "$CONTENT" | jq -r '.severity // "major"')
  HUMAN=$(printf '%s' "$CONTENT" | jq -r '.human_note // ""')
  NEEDS_HUMAN=$(printf '%s' "$CONTENT" | jq -r '.needs_human // false')
  [ "$ROUND" = 1 ] && printf '\n\033[1;36mSPARK SAYS:\033[0m %s\n' "$SUMMARY" || say "round $ROUND assessment: $SUMMARY"

  APPLIED=""
  if [ "$SEV" != "ok" ]; then
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      if printf '%s %s' "$APPLIED" "$HISTORY" | grep -qF "$cmd"; then continue; fi
      if printf '%s' "$cmd" | grep -qE '^\s*(docker (start|restart|unpause|update|compose (up|restart)|container restart)|docker-compose up|systemctl restart docker|/etc/rc\.d/rc\.docker restart)\b'; then
        say "applying: $cmd"
        timeout 120 bash -c "$cmd" >>"$TMP/fix.log" 2>&1 && ok "done" || bad "command failed (see /tmp/immich-doctor-fix.log)"
        APPLIED="${APPLIED};$cmd"
      else
        bad "refused unsafe command from model: $cmd"
      fi
    done < <(printf '%s' "$CONTENT" | jq -r '.fix_commands[]? // empty')
  fi
  fix_restart_policy
  [ -n "$APPLIED" ] && cp "$TMP/fix.log" /tmp/immich-doctor-fix.log
  HISTORY="round $ROUND: summary=[$SUMMARY] applied=[${APPLIED:-none}] needs_human=$NEEDS_HUMAN"

  if [ "$NEEDS_HUMAN" = "true" ]; then
    # one last grace wait in case the safe fixes alone were enough
    if wait_healthy 30; then break; fi
    say "remaining fix needs a human — stopping the loop instead of spinning"
    break
  fi
done

# ------------------------------------------------------------------ verify
if wait_healthy "$HEAL_WAIT"; then
  ok "Immich responds locally (HTTP $LAST_CODE)"
  PCODE=""
  [ -n "$PUBLIC_URL" ] && PCODE=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "$PUBLIC_URL" 2>/dev/null); PCODE=${PCODE:-}
  if [ -z "$PCODE" ]; then
    ok "you are done — open the Immich app"
  elif echo "$PCODE" | grep -qE '^(200|302|307)$'; then
    ok "your Immich URL works (HTTP $PCODE) — you are done, open the Immich app"
  else
    bad "server is up but your URL returned HTTP $PCODE — check Tailscale is connected, then ask Mike"
    cp "$TMP/bundle.$ROUND.txt" /tmp/immich-doctor-bundle.txt; exit 1
  fi
else
  bad "Immich still not answering (HTTP ${LAST_CODE:-000})"
  [ -n "$HUMAN" ] && printf '\033[1;33mA human needs to help:\033[0m %s\n' "$HUMAN"
  cp "$TMP/bundle.$ROUND.txt" /tmp/immich-doctor-bundle.txt 2>/dev/null || cp "$TMP"/bundle.*.txt /tmp/immich-doctor-bundle.txt
  say "bundle saved to /tmp/immich-doctor-bundle.txt — send it to Mike"
  exit 1
fi
