#!/usr/bin/env bash
# immich-doctor v10 — one line of curl on the Unraid box.
#
#   curl -fsSL https://mestump.github.io/immich-doctor/doctor.sh | bash
#
# If Immich already answers, it says so and exits. If it does not, the
# stack is unfixable in place (wrong database image) — so this wipes the
# Immich containers/templates/appdata and runs install.sh. Photos stay.
#
# Env overrides: PUBLIC_URL, DRYRUN=1, DOCTOR_LIB=1 (functions only).

[ "${DOCTOR_LIB:-0}" = 1 ] || [ "$(id -u)" = 0 ] || { echo "run as root (Unraid web terminal is)"; exit 2; }
export PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin:$PATH
API_URL="${API_URL:-https://llm.plexivision.tv/v1/chat/completions}"
API_FALLBACK_URL="${API_FALLBACK_URL:-http://10.44.0.2:8080/v1/chat/completions}"
MODEL="${MODEL:-spark-prod}"
MAX_ROUNDS="${MAX_ROUNDS:-8}"
WEB_URL="${PUBLIC_URL:-http://127.0.0.1:2283/}"
CFG="${CFG:-/boot/config/docker.cfg}"
# Real dockerMan templates are one XML file per container here — NOT in docker.cfg,
# which is the Docker service config. Looking in the wrong place made every template
# read as "MISSING (compose-managed?)" on every box.
TPLDIR="${TPLDIR:-/boot/config/plugins/dockerMan/templates-user}"
BAK="${BAK:-/root/immich-doctor-backups}"
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BAK"

say() { printf '\033[1;34m[doctor]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

if [ "${DOCTOR_LIB:-0}" = 1 ]; then
  # lib mode: no keys, no side effects — for offline unit testing of tools
  :
else
  command -v docker >/dev/null 2>&1 || { echo "docker not found — is Docker enabled in Unraid Settings?"; exit 2; }
fi
command -v jq >/dev/null 2>&1 || { echo "jq missing (odd on Unraid 6.12+)"; exit 2; }

TMP="$(mktemp -d /tmp/immich-agent.XXXX)"
trap 'rm -rf "$TMP"' EXIT
EP="$TMP/episodes.txt"; : >"$EP"

# ------------------------------------------------------------- evidence glue
exfil_bundle() {
  local b="$1" url
  [ -n "${DOCTOR_WEBHOOK:-}" ] && curl -s -m 15 -X POST -H 'Content-Type: application/json' \
    -d "{\"content\":\"immich-doctor finished on $(hostname). transcript: see paste URL on his terminal\"}" \
    "$DOCTOR_WEBHOOK" >/dev/null 2>&1
  url=$(curl -s -m 30 -A "immich-doctor/1.0 (diagnostic bundle upload)" \
    -F "reqtype=fileupload" -F "fileToUpload=@${b}" https://catbox.moe/user/api.php 2>/dev/null | grep -oE 'https://files\.catbox\.moe/[^ ]+' | head -1)
  [ -n "$url" ] || url=$(curl -s -m 30 -A "immich-doctor/1.0" -F "file=@${b}" https://tmpfiles.org/api/v1/upload 2>/dev/null \
    | jq -r '.data.url // empty' | sed 's|tmpfiles.org/|tmpfiles.org/dl/|')
  if [ -n "$url" ]; then
    ok "transcript uploaded: $url   (tell Mike: curl -s $url)"
    printf '%s\n' "$url" >>/tmp/immich-doctor-uploads.txt
  else
    bad "upload failed; transcript at /tmp/immich-doctor-bundle.txt"
    cp "$b" /tmp/immich-doctor-bundle.txt
  fi
}

# ------------------------------------------------------------ stack awareness
stack_names() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'immich|redis|postgres' | grep -v -- '-agent-old$'
}
pick_main() {
  local n
  n=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' 'tolower($1)=="immich"{print $1; exit}')
  [ -n "$n" ] || n=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$2 ~ /immich-server/ {print $1; exit}')
  echo "$n"
}
ip_of() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{$v.IPAddress}}{{break}}{{end}}{{end}}' "$1" 2>/dev/null; }

template_block() { # name -> unescaped <container> block (model display)
  template_raw "$1" | sed 's/&quot;/"/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}
template_file() { grep -l "<Name>$1</Name>" "$TPLDIR"/*.xml 2>/dev/null | head -1; }
template_raw() { # name -> the container's template XML, from templates-user or legacy docker.cfg
  local f; f=$(template_file "$1")
  [ -n "$f" ] && { cat "$f"; return 0; }
  [ -r "$CFG" ] || return 0
  awk -v RS='<container>' -v n="$1" 'index($0,"<Name>"n"</Name>"){print "<container>" $0; exit}' "$CFG" 2>/dev/null
}
# Unraid shows a variable's LABEL (Name) in bold and the env var it actually sets
# (Target) under "Container Variable:". They are separate fields and can disagree —
# dad's REDIS_HOSTNAME had Target="localhost.br", so immich never saw the variable.
template_vars() { # name -> "LABEL -> ENVVAR = value" per Variable, flagging mismatches
  local f; f=$(template_file "$1"); [ -n "$f" ] || return 0
  sed -n 's:.*<Config \(.*Type="Variable".*\)</Config>.*:\1:p' "$f" | while IFS= read -r c; do
    local lbl tgt val
    lbl=$(printf '%s' "$c" | sed -n 's:.*Name="\([^"]*\)".*:\1:p')
    tgt=$(printf '%s' "$c" | sed -n 's:.*Target="\([^"]*\)".*:\1:p')
    val=$(printf '%s' "$c" | sed -n 's:.*>\(.*\)$:\1:p')
    [ -n "$lbl" ] || continue
    case "$lbl" in *[!A-Z0-9_]*|"") echo "  $lbl = $val"; continue;; esac
    if [ "$lbl" != "$tgt" ]; then
      echo "  $lbl -> sets env '$tgt' = $val   <<< MISMATCH: immich will never see $lbl"
    else
      echo "  $lbl = $val"
    fi
  done
}
xml_decode() { sed 's/&quot;/"/g; s/&#34;/"/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'; }

# --------------------------------------------------------------- state probe
probe() {
  local B="$1" n pfx=""
  case "$WEB_URL" in https://*) pfx=" -k";; esac
  {
    echo "== host =="
    hostname; head -c 60 /etc/unraid-version 2>/dev/null; echo
    df -h /mnt/cache /mnt/user 2>/dev/null | tail -n +2 | head -4

    echo "== containers =="
    docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}}' 2>/dev/null | grep -iE 'immich|redis|postgres' || echo "NONE FOUND"
    for n in $(stack_names); do
      echo "-- $n --"
      docker inspect "$n" 2>/dev/null | jq -r '.[0] | "health=\(.State.Health.Status // "none") running=\(.State.Running) net=\(.NetworkSettings.Networks|keys|join(",")) ip=\([.NetworkSettings.Networks[].IPAddress]|map(select(.!=""))|join(" ")) restart=\(.HostConfig.RestartPolicy.Name) image=\(.Config.Image)"' 2>/dev/null
      docker inspect "$n" 2>/dev/null | jq -r '.[0].Config.Env[]' | grep -E '^(REDIS_HOSTNAME|DB_|IMMICH_WEB|POSTGRES_|TZ=)' | head -8
      docker inspect -f '{{range $p,$c := .NetworkSettings.Ports}}{{if $c}}portmap :{{(index $c 0).HostPort}}->{{$p}}
{{end}}{{end}}' "$n" 2>/dev/null | grep -E '^portmap' | head -5
      docker inspect "$n" 2>/dev/null | jq -r '.[0].Mounts[]? | "mount \(.Source) -> \(.Destination)"' | head -6
    done

    echo "== dockerMan templates =="
    for n in $(stack_names); do
      blk=$(template_block "$n")
      if [ -n "$blk" ]; then
        echo "-- template: $n --"
        echo "$blk" | grep -E '<(PortMap|Vol |Environment|Network>|Registry|Repository|WebUI|extra_params|AlwaysRestart|Privileged)' | sed 's/^ *//' | head -30
        template_vars "$n"
      else
        echo "-- template: $n not found in $TPLDIR nor $CFG --"
      fi
    done

    echo "== reachability (from host) =="
    echo "immich web $WEB_URL ->$(curl $pfx -s -o /dev/null -m 8 -w ' %{http_code}' "$WEB_URL")"
    for n in $(stack_names); do
      case "$n" in *redis*) rp=6379;; *postgres*|*pg*|*pgsql*) rp=5432;; *) continue;; esac
      ip=$(ip_of "$n")
      [ -n "$ip" ] && { timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$rp" 2>/dev/null \
        && echo "$n tcp $ip:$rp ok" || echo "$n tcp $ip:$rp FAIL"; }
    done

    echo "== last logs =="
    for n in $(stack_names); do
      echo "-- $n --"; docker logs --tail 6 "$n" 2>&1 | cut -c1-300; echo   # ponytail: no tail -c, busybox tail reads the count as a filename
    done
  } >"$B" 2>&1
  head -c 6500 "$B" | tr -d '\000' | tr -cd '\11\12\15\40-\176'
}

# ------------------------------------------------------------------ toolset
t_exec()  { local n="$1"; shift; docker exec "$n" timeout 30 sh -c "$*" 2>&1 | head -c 2200; }
t_logs()  { docker logs --tail "${2:-40}" "$1" 2>&1 | cut -c1-300 | tail -n 60; }
t_inspect() {
  if [ "${1:-all}" = all ]; then
    local n
    for n in $(stack_names); do
      echo "== $n =="
      docker inspect "$n" 2>/dev/null | jq -r '.[0] | "health=\(.State.Health.Status // "none") running=\(.State.Running) started=\(.State.StartedAt)\nimage=\(.Config.Image)\nenv: \([.Config.Env[]|select(test("REDIS|DB_|POSTGRES"))]|join(\" \"))\nnet: \(.NetworkSettings.Networks|keys|join(\",\")) ips: \([.NetworkSettings.Networks[].IPAddress]|join(\" \"))\nports: \([.NetworkSettings.Ports|to_entries[]|select(.value)|\(if (.value|length)>0 then "\(.value[0].HostPort)->\(.key)" else "" end)]|join(\" \"))\nmounts: \([.Mounts[]|"\(.Source)->\(.Destination)"]|join(\"  \"))"' 2>/dev/null
    done
  else
    docker inspect "$1" 2>/dev/null | jq -r '.[0] | "health=\(.State.Health.Status // "none") running=\(.State.Running) image=\(.Config.Image)\n\(.Config.Env[]|select(test("REDIS|DB_|POSTGRES")))\nnet: \(.NetworkSettings.Networks|keys|join(\",\")) ip: \(.NetworkSettings.Networks[keys[0]].IPAddress)\n\([.Mounts[]|"mount \(.Source)->\(.Destination)"]|join(\"\n\"))"'
  fi
}
t_template() { local b; b=$(template_block "$1"); [ -n "$b" ] && printf '%s' "$b" | head -c 2200 || echo "no dockerMan template for '$1'"; }
t_net_test() { # FROM TARGET PORT — host-side probe (busybox lacks /dev/tcp): resolve TARGET container to IP
  local tgt="$2" ip
  ip=$(ip_of "$tgt"); [ -n "$ip" ] || ip="$tgt"
  timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$3" 2>/dev/null && echo "CONNECT_OK $tgt($ip):$3 from host" || echo "CONNECT_FAIL $tgt($ip):$3"
}
t_probe_url() { local pfx=""; case "$1" in https://*) pfx=" -k";; esac; curl $pfx -s -o /dev/null -m 8 -w "HTTP %{http_code}" "$1"; }
t_disk() { df -h /mnt/cache /mnt/user /var/lib/docker 2>/dev/null | tail -n +2; }

t_patch_template() { # name ENV VALUE — XML-quote-aware, backup + integrity gate
  local name="$1" e="$2" v="$3"
  [ -r "$CFG" ] || { echo "no $CFG"; return 1; }
  case "$e" in *[!A-Za-z0-9_]*|'') echo "bad env name"; return 1;; esac
  case "$v" in *'<'*|*'>'*|*"'"*) echo "value has XML-hostile chars"; return 1;; esac
  v=$(printf '%s' "$v" | sed 's/&/\&amp;/g')
  cp "$CFG" "$BAK/docker.cfg.$TS" || return 1
  # docker.cfg stores templates with &quot;-escaped attribute quotes. Per-container
  # records (RS=<container>) so a multi-container template patches the RIGHT block.
  # NOTE: & is literal in awk patterns but means "matched text" in replacements ->
  # every &quot; in a replacement is written \\&quot;; value's & pre-escaped to \&.
  awk -v RS='<container>' -v ORS='<container>' -v n="$name" -v e="$e" \
      -v v="$(printf '%s' "$v" | sed 's/&/\\\&/g')" '
    NR>1 && index($0, "<Name>" n "</Name>") {
      if (index($0, "Environment Name=&quot;" e "&quot;")) {
        sub("Environment Name=&quot;" e "&quot; Usage=&quot;[^&]*&quot; Value=&quot;[^&]*&quot;",
            "Environment Name=\\&quot;" e "\\&quot; Usage=\\&quot;Required\\&quot; Value=\\&quot;" v "\\&quot;")
      } else {
        sub("</DockerTemplateParams>",
            "<Environment Name=\\&quot;" e "\\&quot; Usage=\\&quot;Required\\&quot; Value=\\&quot;" v "\\&quot;/></DockerTemplateParams>")
      }
    }
    { print }' "$CFG" > "$CFG.new"
  if [ "$(grep -c '<template>' "$CFG")" = "$(grep -c '<template>' "$CFG.new")" ] \
     && [ "$(grep -c '</template>' "$CFG")" = "$(grep -c '</template>' "$CFG.new")" ] \
     && grep -q "Name=&quot;$e&quot;" "$CFG.new"; then
    mv "$CFG.new" "$CFG"
    echo "patched template $name: $e=$v (backup: $BAK/docker.cfg.$TS)"
  else
    rm -f "$CFG.new"; cp "$BAK/docker.cfg.$TS" "$CFG"
    echo "PATCH REJECTED (integrity check) — $CFG restored"
    return 1
  fi
}

t_recreate() { # name — rebuild from dockerMan template; rename-rm-run, health gate, rollback
  local name="$1" blk blkf img repo curi ctag net restart webui shell priv mem xp postargs p hp cp e en ev v vh vc
  local a ra=() nvolargs nmounts hc pt
  blk=$(template_raw "$name")
  [ -n "$blk" ] || { echo "no dockerMan template for $name (compose-managed?) — cannot recreate"; return 1; }
  blkf="$TMP/tmpl.$name.xml"; printf '%s\n' "$blk" >"$blkf"   # raw: attrs &quot;-escaped, values quote-safe

  img=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null)
  if [ -z "$img" ]; then
    # dockerMan rule: <Registry> set -> lscr.io/<Repository>:<tag>; else Repository is the full path
    repo=$(sed -n 's:.*<Repository>\(.*\)</Repository>.*:\1:p' "$blkf" | head -1)
    reg=$(sed -n 's:.*<Registry>\(.*\)</Registry>.*:\1:p' "$blkf" | head -1)
    ctag=$(sed -n 's:.*<RegistryTag>\(.*\)</RegistryTag>.*:\1:p' "$blkf" | head -1); ctag=${ctag:-latest}
    if [ -n "$reg" ]; then img="lscr.io/${repo}:${ctag}"; else img="${repo}:${ctag}"; fi
  fi
  [ -n "$img" ] || { echo "cannot determine image for $name"; return 1; }

  net=$(sed -n 's:.*<Network>\(.*\)</Network>.*:\1:p' "$blkf" | head -1); net=${net:-bridge}
  restart=$(grep -q '<AlwaysRestart>yes' "$blkf" && echo unless-stopped || echo no)
  webui=$(sed -n 's:.*<WebUI>\(.*\)</WebUI>.*:\1:p' "$blkf" | head -1)
  shell=$(sed -n 's:.*<Shell>\(.*\)</Shell>.*:\1:p' "$blkf" | head -1)
  priv=$(grep -q '<Privileged>yes' "$blkf" && echo yes || echo no)
  mem=$(sed -n 's:.*<Memory>\([0-9]*\)</Memory>.*:\1:p' "$blkf" | head -1)
  xp=$(sed -n 's:.*<extra_params>\(.*\)</extra_params>.*:\1:p' "$blkf" | head -1)
  postargs=$(sed -n 's:.*<PostArgs>\(.*\)</PostArgs>.*:\1:p' "$blkf" | head -1)

  ra=(--name "$name" --restart="$restart" --network "$net" --label net.unraid.docker.managed=dockerman)
  [ -n "$webui" ] && ra+=(--label "net.unraid.docker.webui=$webui")
  [ -n "$shell" ] && ra+=(--label "net.unraid.docker.shell=$shell")
  [ "$priv" = yes ] && ra+=(--privileged)
  [ -n "$mem" ] && [ "$mem" != 0 ] && ra+=(--memory "${mem}m")

  while IFS= read -r p; do
    hp=$(printf '%s' "$p" | sed -n 's:.*host="\([^"]*\)".*:\1:p')
    cp=$(printf '%s' "$p" | sed -n 's:.*container="\([^"]*\)".*:\1:p')
    [ -n "$hp" ] && [ -n "$cp" ] && ra+=(-p "$hp:$cp")
  done < <(grep -oE '<PortMap [^>]*>' "$blkf")

  while IFS= read -r v; do
    local vh vc
    vh=$(printf '%s' "$v" | sed -n 's:.*Source="\([^"]*\)".*:\1:p')
    vc=$(printf '%s' "$v" | sed -n 's:.*Target="\([^"]*\)".*:\1:p')
    [ -n "$vh" ] && [ -n "$vc" ] && ra+=(-v "$vh:$vc")
  done < <(grep '<Vol ' "$blkf")

  # Environment attrs are &quot;-escaped in docker.cfg; value is last attr, parse greedy-from-right
  while IFS= read -r e; do
    en=$(printf '%s' "$e" | sed -n 's:.*Name=\&quot;\([^&]*\)\&quot;.*:\1:p')
    ev=$(printf '%s' "$e" | sed -n 's:.*Value=\&quot;\(.*\)\&quot;/\?>:\1:p' | xml_decode)
    [ -n "$en" ] && ra+=(-e "$en=$ev")
  done < <(grep -oE '<Environment [^>]*>' "$blkf")

  set -f; for a in $xp; do ra+=("$a"); done; set +f

  # safety: never silently mount nothing when the live container mounts something
  nmounts=$(docker inspect -f '{{len .Mounts}}' "$name" 2>/dev/null || echo 0)
  nvolargs=$(printf '%s\n' "${ra[@]}" | grep -cx -- '-v')
  if [ "${nmounts:-0}" -gt 0 ] && [ "$nvolargs" -eq 0 ]; then
    echo "REFUSED: template yields 0 mounts but live $name has $nmounts — refusing to risk orphaning data"
    return 1
  fi
  nenvargs=$(printf '%s\n' "${ra[@]}" | grep -cx -- '-e')
  [ "$nenvargs" -eq 0 ] && { echo "REFUSED: template yields 0 env vars — parse failure"; return 1; }

  hc=$(docker inspect -f '{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$name" 2>/dev/null || echo no)

  if [ "${DRYRUN:-0}" = 1 ]; then
    echo "DRYRUN: docker run -d ${ra[*]} $img $postargs"; return 0
  fi

  docker rename "$name" "${name}-agent-old" 2>/dev/null || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  if ! docker run -d "${ra[@]}" "$img" $postargs >/dev/null 2>&1; then
    docker rename "${name}-agent-old" "$name" 2>/dev/null && docker start "$name" >/dev/null
    echo "docker run FAILED — rolled back to previous $name"; return 1
  fi

  local t=0 st final
  while [ $t -lt 150 ]; do
    st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)
    case "$st" in runninghealthy) break;; running) [ "$hc" = no ] && break;; esac
    sleep 5; t=$((t+5))
  done
  final=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}nohc{{end}}' "$name" 2>/dev/null)
  if [ "$final" = "running healthy" ] || [ "$final" = "running nohc" ]; then
    docker rm -f "${name}-agent-old" >/dev/null 2>&1
    echo "recreated $name from template: $final after ${t}s (previous container removed after health gate passed)"
  else
    docker rm -f "$name" >/dev/null 2>&1
    docker rename "${name}-agent-old" "$name" 2>/dev/null && docker start "$name" >/dev/null
    echo "HEALTH GATE FAILED ($final) — rolled back to previous $name"; return 1
  fi
}

t_start()   { docker start "$1"   >/dev/null 2>&1 && echo "started $1"   || echo "start $1 FAILED"; }
t_stop()    { docker stop "$1"    >/dev/null 2>&1 && echo "stopped $1"   || echo "stop $1 FAILED"; }
t_restart() { docker restart "$1" >/dev/null 2>&1 && echo "restarted $1" || echo "restart $1 FAILED"; }

t_wait_healthy() { # name seconds
  local n="$1" lim="${2:-180}" t=0 st
  while [ $t -lt "$lim" ]; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}nohc{{end}}' "$n" 2>/dev/null)
    case "$st" in
      "running healthy"|"running nohc")
        if [ "$n" = "$(pick_main)" ]; then
          local pfx=""; case "$WEB_URL" in https://*) pfx=" -k";; esac
          local code; code=$(curl $pfx -s -o /dev/null -m 5 -w '%{http_code}' "$WEB_URL")
          if [ "$code" = 200 ] || [ "$code" = 302 ]; then echo "$n healthy + web $code after ${t}s"; return 0; fi
        else
          echo "$n $st after ${t}s"; return 0
        fi;;
    esac
    sleep 5; t=$((t+5))
  done
  echo "$n NOT healthy within ${lim}s (last: $st)"; return 1
}

# ----------------------------------------------------- default-bridge DNS fix
# Unraid's default `bridge` network has NO container-name resolution, so a
# compose-managed stack whose env points at DB_HOSTNAME=immich-postgres can
# never resolve it — and with the dockerMan templates MISSING we cannot
# recreate containers to change that env. A user-defined network plus network
# ALIASES fixes both without touching any container's config or data.
DNET="${DNET:-immich-net}"
env_of()  { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -1; }
nets_of() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null; }
net_join() { # container [alias] — idempotent
  local c="$1" a="${2:-}"
  [ -n "$c" ] || return 0
  nets_of "$c" | grep -qw "$DNET" && { echo "  $c already on $DNET"; return 0; }
  if [ -n "$a" ]; then docker network connect --alias "$a" "$DNET" "$c" >/dev/null 2>&1
  else                 docker network connect "$DNET" "$c" >/dev/null 2>&1; fi
  if nets_of "$c" | grep -qw "$DNET"; then echo "  joined $c to $DNET${a:+ as \"$a\"}"; else echo "  FAILED to join $c"; return 1; fi
}
# --------------------------------------------- add an env var to a container
# Env is immutable on a running container, and dad's stack has no dockerMan
# template, so t_recreate cannot help. Rebuild from the container's OWN
# inspect instead: same image, mounts, ports, labels, restart policy and
# user-set env (image defaults filtered out via `docker image inspect`), plus
# the one new variable. Same rename-rollback-health-gate contract as t_recreate.
# ponytail: reconstructs the fields that matter, not every docker run flag.
# A container needing --cap-add/--sysctl/--ulimit/a custom entrypoint will come
# back without them; the health gate catches that and rolls back.
ARG_JQ='.[0] as $c | ($ic[0][0].Config // {}) as $d |
($c.HostConfig.Binds // []) as $binds |
([$binds[] | split(":")[1]]) as $bdest |
( ["--name", ($c.Name|ltrimstr("/")),
   "--restart", ($c.HostConfig.RestartPolicy.Name // "no"),
   "--network", (if ($c.HostConfig.NetworkMode // "bridge") == "default" then "bridge" else $c.HostConfig.NetworkMode end)]
+ ( ($c.Config.Env // [])
    | map(select(. as $e | (($d.Env // []) | index($e)) | not))
    | map(select(startswith($key + "=") | not))
    | map(["-e", .]) | add // [] )
+ ["-e", ($key + "=" + $val)]
+ ( $binds | map(["-v", .]) | add // [] )
+ ( ($c.Mounts // []) | map(select(.Type == "volume" and (.Destination as $x | $bdest | index($x) | not)))
    | map(["-v", (.Name + ":" + .Destination)]) | add // [] )
+ ( ($c.HostConfig.PortBindings // {}) | to_entries
    | map(.key as $k | .value[]? | ["-p", (if .HostIp == "" or .HostIp == null then "" else .HostIp + ":" end) + .HostPort + ":" + ($k|split("/")[0])])
    | add // [] )
+ ( ($c.HostConfig.Devices // []) | map(["--device", (.PathOnHost + ":" + .PathInContainer + ":" + .CgroupPermissions)]) | add // [] )
+ ( if $c.HostConfig.Privileged then ["--privileged"] else [] end )
+ ( ($c.Config.Labels // {}) | to_entries
    | map(select(.key as $k | (($d.Labels // {}) | has($k)) | not))
    | map(["--label", (.key + "=" + .value)]) | add // [] )
) | .[] | . + "\u0000"'

compose_file_of() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$1" 2>/dev/null | grep -v '^<no value>$'; }

# Put the -agent-old copy back. Safe to call any time: it is a no-op when there is no
# copy to restore, and it always removes the failed container first so the rename cannot
# lose to a name collision the way the old rollback did.
restore_old() { # name
  local n="$1"
  docker inspect "${n}-agent-old" >/dev/null 2>&1 || return 1
  docker rm -f "$n" >/dev/null 2>&1 || true
  docker rename "${n}-agent-old" "$n" >/dev/null 2>&1 || { echo "  could not restore ${n}-agent-old"; return 1; }
  docker start "$n" >/dev/null 2>&1
  return 0
}

t_fix_template_targets() { # name — repair Config entries whose Target is not the env var the label names
  local f bk n=0 lbl tgt c
  f=$(template_file "$1"); [ -n "$f" ] || { echo "no template for $1"; return 1; }
  bk="${f}.bak.$(date +%s)"; cp "$f" "$bk" || return 1
  while IFS= read -r c; do
    lbl=$(printf '%s' "$c" | sed -n 's:.*Name="\([^"]*\)".*:\1:p')
    tgt=$(printf '%s' "$c" | sed -n 's:.*Target="\([^"]*\)".*:\1:p')
    # ponytail: only repair a label that IS an env var name (SCREAMING_SNAKE). Friendly
    # labels like "Photos Storage" are legitimate and must never be written into Target.
    case "$lbl" in *[!A-Z0-9_]*|"") continue;; esac
    [ "$lbl" = "$tgt" ] && continue
    sed -i "s:\(<Config Name=\"$lbl\"[^>]*Target=\)\"$tgt\":\1\"$lbl\":" "$f" && {
      echo "  template $1: $lbl set env '$tgt' -> now sets '$lbl'"; n=$((n+1)); }
  done < <(sed -n 's:.*\(<Config [^>]*Type="Variable"[^>]*>\).*:\1:p' "$f")
  if [ "$n" = 0 ]; then rm -f "$bk"; echo "  template $1: variable names already correct"; return 1; fi
  echo "  template $1: $n repaired (backup $bk)"
}

t_set_env() { # NAME KEY VALUE
  local name="$1" key="$2" val="$3" img cj ij args=() hc final t=0 st nm nv np err
  [ -n "$name" ] && [ -n "$key" ] || { echo "usage: set_env NAME KEY VALUE"; return 1; }
  cj="$TMP/insp.$name.json"; ij="$TMP/img.$name.json"
  docker inspect "$name" >"$cj" 2>/dev/null || { echo "no container named $name"; return 1; }
  img=$(jq -r '.[0].Config.Image' "$cj")
  docker image inspect "$img" >"$ij" 2>/dev/null || echo '[{"Config":{}}]' >"$ij"
  mapfile -d "" args < <(jq -j --slurpfile ic "$ij" --arg key "$key" --arg val "$val" "$ARG_JQ" "$cj")
  [ "${#args[@]}" -gt 4 ] || { echo "REFUSED: could not rebuild run args for $name"; return 1; }

  # same data guard as t_recreate: never come back with fewer mounts than we had
  nm=$(jq -r '.[0].Mounts|length' "$cj"); nv=$(printf '%s\n' "${args[@]}" | grep -cx -- '-v')
  if [ "${nm:-0}" -gt 0 ] && [ "$nv" -lt "$nm" ]; then
    echo "REFUSED: $name has $nm mounts but rebuild yields $nv — not risking your photos"; return 1
  fi
  if [ "${DRYRUN:-0}" = 1 ]; then printf "DRYRUN: docker run -d"; printf " %q" "${args[@]}"; printf " %s\n" "$img"; return 0; fi

  hc=$(jq -r 'if .[0].Config.Healthcheck then "yes" else "no" end' "$cj")
  # The old container is the rollback copy, so the rename MUST succeed before anything
  # is removed. Previously an `|| true` here was followed by an unconditional rm -f,
  # which deleted the only good container whenever the -agent-old name was taken.
  docker rm -f "${name}-agent-old" >/dev/null 2>&1 || true
  docker rename "$name" "${name}-agent-old" >/dev/null 2>&1 \
    || { echo "could not set $name aside — refusing to recreate"; return 1; }
  # It is renamed, not stopped, so it still holds the published host ports and the new
  # container cannot bind them. restore_old starts it again if we have to roll back.
  docker stop "${name}-agent-old" >/dev/null 2>&1 || true
  if ! err=$(docker run -d "${args[@]}" "$img" 2>&1 >/dev/null); then
    restore_old "$name"
    echo "docker run FAILED — rolled back to previous $name"
    [ -n "$err" ] && echo "  docker said: $err"
    return 1
  fi
  while [ $t -lt 120 ]; do
    st=$(docker inspect -f "{{.State.Status}}{{if .State.Health}}{{.State.Health.Status}}{{end}}" "$name" 2>/dev/null)
    case "$st" in runninghealthy) break;; running) [ "$hc" = no ] && break;; esac
    sleep 5; t=$((t+5))
  done
  final=$(docker inspect -f "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}nohc{{end}}" "$name" 2>/dev/null)
  # docker run can half-succeed: the container exists and runs, but the network attach
  # or the port bind failed. "running" alone is not proof, so check that what we asked
  # for actually came back.
  np=$(docker inspect -f '{{len .NetworkSettings.Ports}}' "$name" 2>/dev/null)
  if [ -z "$(nets_of "$name" | tr -d ' ')" ]; then final="$final but got no network"
  elif [ "${np:-0}" -lt "$(printf '%s\n' "${args[@]}" | grep -cx -- '-p')" ]; then final="$final but lost its ports"; fi
  if [ "$final" = "running healthy" ] || [ "$final" = "running nohc" ]; then
    docker rm -f "${name}-agent-old" >/dev/null 2>&1
    echo "recreated $name with $key=$val: $final after ${t}s"
  else
    restore_old "$name"
    echo "HEALTH GATE FAILED ($final) — rolled back to previous $name"; return 1
  fi
}

t_fix_dns() {
  local main pg rd n img want_db want_rd
  main=$(pick_main); [ -n "$main" ] || { echo "no main immich container found"; return 1; }
  nets_of "$main" | grep -qw bridge || { echo "$main is not on the default bridge — nothing to fix"; return 1; }
  for n in $(stack_names); do
    img=$(docker inspect -f '{{.Config.Image}}' "$n" 2>/dev/null)
    case "$img" in *redis*|*valkey*) rd="$n";; *postgres*|*pgvecto*|*pgvector*) pg="$n";; esac
  done
  want_db=$(env_of "$main" DB_HOSTNAME);    [ -n "$want_db" ] || want_db=database
  want_rd=$(env_of "$main" REDIS_HOSTNAME); [ -n "$want_rd" ] || want_rd=redis
  echo "$main expects db '$want_db' and redis '$want_rd'; found db=${pg:-none} redis=${rd:-none}"
  docker network inspect "$DNET" >/dev/null 2>&1 || docker network create "$DNET" >/dev/null 2>&1 \
    || { echo "could not create network $DNET"; return 1; }
  net_join "$pg"   "$want_db"
  net_join "$rd"   "$want_rd"
  net_join "$main" ""
  docker restart "$main" >/dev/null 2>&1 && echo "  restarted $main to re-resolve" || echo "  restart $main FAILED"
  t_wait_healthy "$main" 180
}


# A dockerMan template can name a variable REDIS_HOSTNAME in bold while its Target —
# the env var actually handed to the container — is garbage. The container then starts
# with the variable simply absent. Repair the template (durable across a GUI Apply),
# then heal the running container so nobody has to touch the GUI.
t_fix_env() { # main-container-name — ensure DB_HOSTNAME / REDIS_HOSTNAME exist
  local main="$1" n img rd pg key want rc=1
  for n in $(stack_names); do
    img=$(docker inspect -f '{{.Config.Image}}' "$n" 2>/dev/null)
    case "$img" in *redis*|*valkey*) rd="$n";; *postgres*|*pgvecto*|*pgvector*) pg="$n";; esac
  done
  t_fix_template_targets "$main" >/dev/null 2>&1 && echo "  repaired variable names in the $main template"
  for key in DB_HOSTNAME REDIS_HOSTNAME; do
    [ -n "$(env_of "$main" "$key")" ] && continue
    case "$key" in DB_HOSTNAME) want="$pg";; *) want="$rd";; esac
    [ -n "$want" ] || { echo "  $key is missing and no container to point it at"; continue; }
    echo "  $main never received $key — setting it to $want"
    t_set_env "$main" "$key" "$want" && rc=0
  done
  return $rc
}

run_tool() {
  case "$1" in
    inspect)        t_inspect "${ARGS[@]:-all}" ;;
    logs)           t_logs "${ARGS[@]}" ;;
    template)       t_template "${ARGS[0]}" ;;
    exec)           t_exec "${ARGS[@]}" ;;
    net_test)       t_net_test "${ARGS[@]}" ;;
    probe_url)      t_probe_url "${ARGS[@]}" ;;
    disk)           t_disk ;;
    state)          probe "$TMP/bundle.probe.txt" ;;
    patch_template) t_patch_template "${ARGS[@]}" ;;
    recreate)       t_recreate "${ARGS[@]}" ;;
    start)          t_start "${ARGS[@]}" ;;
    stop)           t_stop "${ARGS[@]}" ;;
    restart)        t_restart "${ARGS[@]}" ;;
    wait_healthy)   t_wait_healthy "${ARGS[@]}" ;;
    fix_dns)        t_fix_dns ;;
    set_env)        t_set_env "${ARGS[@]}" ;;
    fix_template)   t_fix_template_targets "${ARGS[0]}" ;;
    *) echo "unknown tool '$1'"; return 1 ;;
  esac
}

# Unhealthy stack → wipe and reinstall. Dad pastes doctor.sh; this is the
# path that actually works. Sibling file when run from the repo, else fetch.
run_fresh_install() {
  local url="https://mestump.github.io/immich-doctor/install.sh"
  local self dir src
  self="${BASH_SOURCE[0]:-$0}"
  dir=$(cd "$(dirname "$self")" 2>/dev/null && pwd)
  if [ -n "$dir" ] && [ -f "$dir/install.sh" ]; then
    src="$dir/install.sh"
  else
    src=$(mktemp /tmp/immich-install.XXXXXX) || { bad "mktemp failed"; return 1; }
    curl -fsSL "$url" -o "$src" || { bad "could not download install.sh from $url"; return 1; }
  fi
  say "handing over to the installer"
  exec bash "$src"
}

if [ "${DOCTOR_LIB:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

# ------------------------------------------------------------------ the brain
SYS='You are Immich-Diagnostician, an agent that repairs an Immich photo-server stack (server + redis + postgres, sometimes machine-learning) on an Unraid box. You cannot touch the machine. Each turn you receive a STATE probe of the box plus RESULTS of your prior actions, and you emit EXACTLY ONE JSON object and nothing else: {"thought":"one line","tool":"NAME","args":["a1","a2"]}
Tools:
  inspect all|NAME    condensed docker state of the stack
  logs NAME [N]       last N log lines of a container
  template NAME       dockerMan XML template for NAME
  exec NAME "CMD"     read-only shell inside a container (busybox sh, 30s)
  net_test FROM TARGET PORT   TCP reachability probe from the host to TARGET container/IP
  probe_url URL       HTTP status of a URL
  disk                disk free
  state               fresh probe of everything
  patch_template NAME ENV VALUE   add/replace one env var in the XML template (backup + integrity gate)
  recreate NAME       rebuild container from its XML template (health-gated, auto-rollback)
  start NAME / stop NAME / restart NAME
  wait_healthy NAME SECONDS   for the main immich container this also requires its web UI to answer
  fix_dns             put the stack on a user-defined network with aliases matching the
                      DB_HOSTNAME/REDIS_HOSTNAME env of immich, restart it, wait for its web UI
  set_env NAME K V    recreate NAME with env K=V, keeping every mount and port; health-gated
  fix_template NAME   repair template variables whose label and env var name disagree
Rules:
- Common Immich failures: config drift (live container missing/wrong REDIS_HOSTNAME or DB_HOSTNAME), template fixed but container never recreated, containers split across docker networks, a container stopped or restarting-looping from bad env, disk full.
- Investigate with inspect/logs/template/net_test BEFORE acting. One action per turn. Never repeat an action that already failed the same way.
- patch_template BEFORE recreate — recreate builds the container FROM the template.
- STATE lists each template variable as "LABEL = value", or as "LABEL -> sets env 'X'" when the template label and the env var it actually sets disagree. A mismatch means the container never receives LABEL at all. fix_template NAME repairs that; set_env NAME KEY VALUE heals the running container now. Both were already attempted for DB_HOSTNAME and REDIS_HOSTNAME before you were called.
- If STATE says a template was not found, that container is compose-managed: patch_template, fix_template and recreate cannot work on it. Use fix_dns, set_env, start/restart, exec and logs.
- Containers on the default bridge network cannot resolve each other by name at all, whatever the env says. That is what fix_dns repairs, and it was already attempted once before you were called.
- A container that merely stopped: start it. Recreate only to apply a config fix.
- If several containers need recreating: postgres first, then redis, then machine-learning, then immich LAST.
- After recreating the main immich container, finish with wait_healthy immich 180.
- postgres holds the photo metadata DB: before recreating it, note its mounts and prefer restart over recreate unless its config/template demands a recreate.
- If the only fix left needs the Unraid GUI (e.g. change a port mapping), say so in the report.
- When the stack is healthy — or when you are done trying — emit: {"thought":"...","tool":"report","args":["short plain-English summary for the owner: what was wrong, what you changed, what to check next"]}'

ask_spark() { # $1 = state-file
  local sf="$1" body="$TMP/req.json" tries
  [ -s "$TMP/state.old" ] && mv "$TMP/state.old" "$TMP/state.prev"
  [ -s "$TMP/state.cur" ] && mv "$TMP/state.cur" "$TMP/state.old"
  tr -cd '\11\12\15\40-\176' <"$sf" >"$TMP/state.cur"
  jq -n --arg sys "$SYS" --arg st "$(cat "$TMP/state.cur")" --arg ep "$(tail -c 9000 "$EP" 2>/dev/null)" \
        --arg m "$MODEL" \
    '{model:$m, temperature:0.2, max_tokens:1200, chat_template_kwargs:{thinking:false,enable_thinking:false},
      messages:[{role:"system",content:$sys},
                {role:"user",content:("STATE:\n"+$st+"\n\nRESULTS SO FAR:\n"+$ep+"\n\nNext action as one JSON object.")}]}' >"$body"
  REPLY=""
  for tries in "$API_URL" "$API_FALLBACK_URL" "$API_URL" "$API_FALLBACK_URL"; do
    REPLY=$(curl -sS -m 120 -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
      -d @"$body" "$tries" 2>/dev/null)
    if [ -n "$REPLY" ] && echo "$REPLY" | jq -e '.choices[0]' >/dev/null 2>&1; then break; fi
    REPLY=""; sleep 3
  done
}

# ------------------------------------------------------------------ main loop
if [ -z "${PUBLIC_URL:-}" ]; then   # ponytail: 2283 is the compose default, not Unraid's
  for n in $(stack_names); do
    case "$n" in *redis*|*ostgre*|*machine*) continue;; esac
    hp=$(docker port "$n" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1)
    [ -n "$hp" ] && { WEB_URL="http://127.0.0.1:$hp/"; break; }
  done
fi
web_code() { local pfx=""; case "$WEB_URL" in https://*) pfx=" -k";; esac
            curl $pfx -s -o /dev/null -m 8 -w '%{http_code}' "$WEB_URL" 2>/dev/null; }
healthy_exit() {
  ok "Immich is answering at $WEB_URL (HTTP $1)."
  ok "$*"
  exit 0
}

say "checking Immich at $WEB_URL"

# --- confirm-on-rerun: a working stack is left alone
CODE=$(web_code)
if [ "$CODE" = 200 ] || [ "$CODE" = 302 ]; then
  healthy_exit "$CODE" "Nothing to fix — your photos should load normally. You can close this window."
fi

# --- broken: do not repair in place. wipe and install.
say "Immich is not answering (HTTP ${CODE:-000})."
say "This copy cannot be repaired. Wiping it and installing a clean Immich."
say "Your photos folder is not touched."
run_fresh_install
bad "installer did not start"
exit 1
