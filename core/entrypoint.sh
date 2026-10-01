#!/usr/bin/env bash
# =============================================================================
# core/entrypoint.sh — panel-agnostic orchestrator for single-port PaaS hosts
# (Railway, Render, Koyeb, Fly.io's HTTP service, ...).
#
# Boot sequence
#   1. load helpers + the panel adapter selected by $PANEL_ADAPTER
#   2. validate configuration (ports, inbound routes)
#   3. resolve the panel base path (env > panel DB > random)
#   4. adapter_prepare  : apply port/path/credentials/listen settings
#   5. render nginx.conf with a layered safety net
#   6. start the panel, adapter sidecars, the settings watcher and nginx
#   7. supervise: if the panel or nginx dies, exit non-zero so the platform
#      restarts the container (instead of silently serving 502s forever)
# =============================================================================
set -Eeo pipefail

KIT_DIR="${KIT_DIR:-/opt/kit}"
# shellcheck source=core/lib.sh
source "$KIT_DIR/core/lib.sh"
# shellcheck source=core/nginx-gen.sh
source "$KIT_DIR/core/nginx-gen.sh"

[[ -n "${PANEL_ADAPTER:-}" ]] || die "PANEL_ADAPTER is not set (the Dockerfile must set it)"
[[ -r "$KIT_DIR/adapters/${PANEL_ADAPTER}.sh" ]] || die "unknown adapter: $PANEL_ADAPTER"
# shellcheck disable=SC1090
source "$KIT_DIR/adapters/${PANEL_ADAPTER}.sh"

# ---------------------------------------------------------------------------
# 1. Configuration (all overridable via Railway → Variables)
# ---------------------------------------------------------------------------
# NOTE: we deliberately do NOT use $PORT. Railway often injects PORT=8080,
# which collides with the default inbound port. Point the Railway domain's
# "Target Port" at HTTP_PORT instead.
HTTP_PORT="${HTTP_PORT:-3000}"
DEFAULT_INBOUND_PORT="${DEFAULT_INBOUND_PORT:-8080}"
INBOUND_ROUTES="${INBOUND_ROUTES:-/in1:8081,/in2:8082,/in3:8083,/in4:8084,/in5:8085,/in6:8086,/in7:8087,/in8:8088,/in9:8089}"
ROOT_REDIRECT="${ROOT_REDIRECT:-false}"
NGINX_WORKERS="${NGINX_WORKERS:-1}"
NGINX_ACCESS_LOG="${NGINX_ACCESS_LOG:-false}"
SUB_WATCH="${SUB_WATCH:-true}"
AUTO_SUB_URI="${AUTO_SUB_URI:-true}"

log "starting railway-panel-kit (adapter: $(adapter_label))"

# ---------------------------------------------------------------------------
# 2. Validation
# ---------------------------------------------------------------------------
is_port "$HTTP_PORT" || die "HTTP_PORT='$HTTP_PORT' is not a valid port"
[[ "$NGINX_WORKERS" =~ ^([1-9][0-9]?|auto)$ ]] || NGINX_WORKERS=1
if [[ "$DEFAULT_INBOUND_PORT" != "off" ]]; then
  is_port "$DEFAULT_INBOUND_PORT" || die "DEFAULT_INBOUND_PORT='$DEFAULT_INBOUND_PORT' is not a port (or 'off')"
fi

ROUTE_PATHS=(); ROUTE_PORTS=()
declare -A _seen_ports=()
_seen_ports["$HTTP_PORT"]="HTTP_PORT"
_seen_ports["$PANEL_PORT"]="panel"
_seen_ports["$DEFAULT_SUB_PORT"]="subscription server"
[[ "$DEFAULT_INBOUND_PORT" != "off" ]] && {
  [[ -n "${_seen_ports[$DEFAULT_INBOUND_PORT]:-}" ]] &&
    die "DEFAULT_INBOUND_PORT $DEFAULT_INBOUND_PORT collides with ${_seen_ports[$DEFAULT_INBOUND_PORT]}"
  _seen_ports["$DEFAULT_INBOUND_PORT"]="default inbound"
}

IFS=',' read -r -a _routes <<<"${INBOUND_ROUTES// /}"
for _r in "${_routes[@]}"; do
  [[ -z "$_r" ]] && continue
  _p="${_r%%:*}"; _port="${_r##*:}"
  if [[ ! "$_p" =~ ^/[A-Za-z0-9_.-][A-Za-z0-9/_.-]*$ ]] || (( ${#_p} > 64 )); then
    die "INBOUND_ROUTES: bad path in '$_r' (expected /name:port)"
  fi
  is_port "$_port" || die "INBOUND_ROUTES: bad port in '$_r'"
  [[ -n "${_seen_ports[$_port]:-}" ]] && die "INBOUND_ROUTES: port $_port in '$_r' collides with ${_seen_ports[$_port]}"
  for _q in "${ROUTE_PATHS[@]}" /healthz /_kit_ev; do
    paths_overlap "$_p" "$_q" && die "INBOUND_ROUTES: '$_p' overlaps '$_q' (one is a prefix of the other)"
  done
  _seen_ports["$_port"]="route $_p"
  ROUTE_PATHS+=("$_p"); ROUTE_PORTS+=("$_port")
done
unset _routes _r _p _port _q

# ---------------------------------------------------------------------------
# Persistence check — the #1 cause of "all my users disappeared".
# ---------------------------------------------------------------------------
if is_mountpoint "$DATA_DIR"; then
  log "persistent volume detected at $DATA_DIR"
elif [[ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]]; then
  warn "a volume is mounted at $RAILWAY_VOLUME_MOUNT_PATH but the panel stores data in $DATA_DIR — change the volume mount path to $DATA_DIR"
else
  warn "NO persistent volume at $DATA_DIR — every redeploy will wipe inbounds, clients and settings."
  warn "Railway → service → Settings → Volumes → mount path: $DATA_DIR"
fi

# ---------------------------------------------------------------------------
# 3. Panel base path: PANEL_PATH env > current panel DB value > random.
#    Using the DB value means a path you chose in the panel UI survives
#    redeploys; the random default keeps the panel off obvious URLs.
# ---------------------------------------------------------------------------
_path_src=""
if [[ -n "${PANEL_PATH:-}" ]]; then
  PANEL_PATH="$(norm_dir_path "$PANEL_PATH")"; _path_src="PANEL_PATH variable"
else
  PANEL_PATH="$(norm_dir_path "$(adapter_live_panel_path)")"; _path_src="panel database"
fi
if ! panel_path_usable "$PANEL_PATH"; then
  [[ -n "$PANEL_PATH" && "$PANEL_PATH" != "/" ]] &&
    warn "panel path '$PANEL_PATH' ($_path_src) is unusable — generating a random one"
  PANEL_PATH="/$(rand_hex 8)/"; _path_src="generated"
fi
log "panel path: $PANEL_PATH ($_path_src)"
export PANEL_PATH

# ---------------------------------------------------------------------------
# 4. Adapter: apply settings before the panel starts
# ---------------------------------------------------------------------------
adapter_prepare

# ---------------------------------------------------------------------------
# 5. Render nginx.conf with a layered safety net: an optional feature must
#    never take the panel down with it.
# ---------------------------------------------------------------------------
setup_events
SUB_FALLBACK_ONLY=0

_try_nginx() {
  collect_state "${1:-0}"
  render_nginx_conf /etc/nginx/nginx.conf && nginx -t -q >/tmp/kit-nginx-test.log 2>&1
}

if ! _try_nginx 0; then
  warn "nginx config test failed:"; head -5 /tmp/kit-nginx-test.log | sed 's/^/    /' >&2
  _ok=0
  if [[ "$EVENTS_ACTIVE" == 1 ]]; then
    EVENTS_ACTIVE=0
    _try_nginx 1 && { _ok=1; warn "-> connection events disabled to keep the panel reachable (fix EVENT_WEBHOOK_URL)"; }
  fi
  if [[ "$_ok" == 0 ]]; then
    SUB_FALLBACK_ONLY=1
    _try_nginx 1 && { _ok=1; warn "-> custom subscription paths dropped; serving /sub/ only"; }
  fi
  if [[ "$_ok" == 0 ]]; then
    head -10 /tmp/kit-nginx-test.log | sed 's/^/    /' >&2
    die "nginx config is invalid even with safe defaults"
  fi
fi

# ---------------------------------------------------------------------------
# Diagnostics: tell the user exactly which URLs to use.
# ---------------------------------------------------------------------------
_host="$(public_host || true)"
log "---------------------------------------------------------------------"
if [[ -n "$_host" ]]; then
  log "panel        : https://${_host}${CUR_PANEL_PATH}"
  (( ${#CUR_SUB_PATHS[@]} )) && log "subscription : https://${_host}${CUR_SUB_PATHS[0]}<subId>"
else
  log "panel        : https://<your-domain>${CUR_PANEL_PATH}   (Settings → Networking → Generate Domain, target port ${HTTP_PORT})"
fi
log "domain target port must be ${HTTP_PORT}"
log "inbounds     : any path -> ${DEFAULT_INBOUND_PORT}; $(for i in "${!ROUTE_PATHS[@]}"; do printf '%s->%s ' "${ROUTE_PATHS[$i]}" "${ROUTE_PORTS[$i]}"; done)"
if [[ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ]]; then
  log "TCP proxy    : ${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT:-?} -> container port ${RAILWAY_TCP_APPLICATION_PORT:-?}"
  log "               create a raw-TCP inbound (e.g. VLESS/Trojan over tcp) on port ${RAILWAY_TCP_APPLICATION_PORT:-?}"
  log "               and put ${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT:-?} in the client link"
fi
adapter_diagnostics || true
log "---------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 6. Start everything
# ---------------------------------------------------------------------------
_children=()
shutdown() {
  log "shutting down…"
  local pid
  for pid in "${_children[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  exit "${1:-0}"
}
trap 'shutdown 0' TERM INT

adapter_start                      # must set PANEL_PID
[[ -n "${PANEL_PID:-}" ]] || die "adapter_start did not set PANEL_PID"
export PANEL_PID
_children+=("$PANEL_PID")
log "panel started (pid $PANEL_PID)"

adapter_post_start || warn "adapter_post_start reported an error (non-fatal)"

if is_true "$SUB_WATCH"; then
  sub_watch_loop &
  _children+=("$!")
fi

sleep 2
nginx -g 'daemon off;' &
NGINX_PID=$!
_children+=("$NGINX_PID")
log "nginx listening on :$HTTP_PORT (pid $NGINX_PID)"

# ---------------------------------------------------------------------------
# 7. Supervise the two critical processes
# ---------------------------------------------------------------------------
_rc=0
wait -n "$PANEL_PID" "$NGINX_PID" || _rc=$?
if ! kill -0 "$PANEL_PID" 2>/dev/null; then
  warn "panel process exited (rc=$_rc) — stopping container so the platform restarts it"
else
  warn "nginx exited (rc=$_rc) — stopping container so the platform restarts it"
fi
shutdown 1
