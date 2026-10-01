#!/usr/bin/env bash
# =============================================================================
# adapters/3x-ui-sockopt.sh — background fixer for 3x-ui inbounds that sit
# behind nginx (network = ws | xhttp | httpupgrade).
#
# 1) sockopt.trustedXForwardedFor = ["X-Forwarded-For"]
#    Behind nginx, Xray sees every client as 127.0.0.1. With this option it
#    takes the first address of the named header instead, so the panel's IP
#    table and IP Limit work.
#    !! The value is a HEADER NAME, not an IP address. Setting it to
#       ["127.0.0.1"] makes Xray ignore the header -> empty IP table.
#       Such legacy values are repaired automatically.
#
# 2) externalProxy (optional, AUTO_EXTERNAL_PROXY=true)
#    The inbound listens on plain http inside the container, but clients must
#    connect to https://<public-host>:443. externalProxy makes the panel put
#    the public host, port 443 and TLS into generated share links / subs.
#    Only written when the inbound has no externalProxy yet.
#
# After a change the running Xray is reloaded with SIGUSR1 sent to the x-ui
# process (SIGHUP only restarts the web servers, not Xray).
# =============================================================================
set -u
KIT_DIR="${KIT_DIR:-/opt/kit}"
# shellcheck source=../core/lib.sh
source "$KIT_DIR/core/lib.sh"

DB="${XUI_DB_FOLDER:-/etc/x-ui}/x-ui.db"
TRUSTED="${XUI_TRUSTED_XFF:-X-Forwarded-For}"
INTERVAL="${XUI_SOCKOPT_INTERVAL:-20}"
AUTO_EXT="${AUTO_EXTERNAL_PROXY:-true}"
HOST="$(public_host || true)"

[[ "$TRUSTED" =~ ^[A-Za-z0-9-]+$ ]] || TRUSTED="X-Forwarded-For"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && (( INTERVAL >= 5 )) || INTERVAL=20

SQL=(sqlite3 -cmd '.timeout 5000')
PROXIED="json_extract(stream_settings,'\$.network') IN ('ws','xhttp','httpupgrade')"

log "sockopt fixer: watching $DB every ${INTERVAL}s (trustedXForwardedFor=$TRUSTED, externalProxy=${AUTO_EXT}${HOST:+ -> $HOST:443})"

for _ in $(seq 1 60); do db_ready "$DB" && break; sleep 2; done
db_ready "$DB" || { warn "sockopt fixer: database not ready, exiting"; exit 0; }

fix_trusted_xff() {
  local ids id changed=1
  ids="$("${SQL[@]}" "$DB" "
    SELECT id FROM inbounds
    WHERE json_valid(stream_settings) AND $PROXIED AND (
      json_extract(stream_settings,'\$.sockopt.trustedXForwardedFor') IS NULL
      OR json_array_length(json_extract(stream_settings,'\$.sockopt.trustedXForwardedFor')) = 0
      OR json_extract(stream_settings,'\$.sockopt.trustedXForwardedFor[0]') = '127.0.0.1'
    );" 2>/dev/null)"
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if "${SQL[@]}" "$DB" "
        UPDATE inbounds SET stream_settings = json_set(stream_settings,
          '\$.sockopt.trustedXForwardedFor', json_array('$TRUSTED'))
        WHERE id = $id;" 2>/dev/null; then
      log "sockopt fixer: inbound $id -> trustedXForwardedFor=[$TRUSTED]"
      changed=0
    fi
  done
  return $changed
}

fix_external_proxy() {
  is_true "$AUTO_EXT" && [[ -n "$HOST" ]] || return 1
  local ids id changed=1
  ids="$("${SQL[@]}" "$DB" "
    SELECT id FROM inbounds
    WHERE json_valid(stream_settings) AND $PROXIED
      AND COALESCE(json_extract(stream_settings,'\$.security'),'none') = 'none'
      AND (json_extract(stream_settings,'\$.externalProxy') IS NULL
           OR json_array_length(json_extract(stream_settings,'\$.externalProxy')) = 0);" 2>/dev/null)"
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if "${SQL[@]}" "$DB" "
        UPDATE inbounds SET stream_settings = json_set(stream_settings,
          '\$.externalProxy',
          json_array(json_object('forceTls','tls','dest','$HOST','port',443,'remark','')))
        WHERE id = $id;" 2>/dev/null; then
      log "sockopt fixer: inbound $id -> externalProxy $HOST:443 (tls)"
      changed=0
    fi
  done
  return $changed
}

# Find the x-ui process: prefer the PID exported by entrypoint.sh, fall back
# to scanning /proc for an argv token that is exactly "x-ui" or ".../x-ui"
# (pgrep patterns miss "./x-ui" started from its own directory).
xui_pids() {
  if [[ -n "${PANEL_PID:-}" && -r "/proc/$PANEL_PID/cmdline" ]]; then echo "$PANEL_PID"; return; fi
  local d tok
  for d in /proc/[0-9]*; do
    [[ "${d#/proc/}" == "$$" ]] && continue
    while IFS= read -r -d '' tok; do
      case "$tok" in x-ui|*/x-ui) echo "${d#/proc/}"; break ;; esac
    done <"$d/cmdline" 2>/dev/null
  done
}

reload_xray() {
  local pid sent=0
  for pid in $(xui_pids | sort -u); do
    kill -USR1 "$pid" 2>/dev/null && { sent=1; log "sockopt fixer: Xray reload requested (USR1 -> $pid)"; }
  done
  (( sent )) || warn "sockopt fixer: x-ui process not found — restart Xray from the panel to apply"
}

while true; do
  touched=0
  fix_trusted_xff && touched=1
  fix_external_proxy && touched=1
  (( touched )) && reload_xray
  sleep "$INTERVAL"
done
