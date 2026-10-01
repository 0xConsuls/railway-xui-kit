#!/usr/bin/env bash
# =============================================================================
# core/nginx-gen.sh — builds /etc/nginx/nginx.conf from the template.
#
# Sourced by entrypoint.sh. Depends on lib.sh and on the adapter functions:
#   adapter_live_panel_path, adapter_live_panel_port,
#   adapter_sub_port, adapter_sub_paths
#
# Globals consumed (set by entrypoint.sh):
#   KIT_DIR HTTP_PORT NGINX_WORKERS NGINX_ACCESS_LOG ROOT_REDIRECT
#   DEFAULT_INBOUND_PORT ROUTE_PATHS[] ROUTE_PORTS[]
#   PANEL_PATH PANEL_PORT             (boot-time values, used as fallback)
#   EVENTS_ACTIVE EV_BASE EV_SEP EV_HOST EV_RESOLVERS
#   SUB_FALLBACK_ONLY                 (1 = serve only /sub/, used by the safety net)
#
# Globals produced by collect_state:
#   CUR_PANEL_PATH CUR_PANEL_PORT CUR_SUB_PORT CUR_SUB_PATHS[]
# =============================================================================

NGINX_TEMPLATE="${KIT_DIR}/core/nginx.conf.template"
PROXY_SNIPPET="/etc/nginx/snippets/proxy-common.conf"

# Prefixes that nothing else may overlap: health check and internal event hooks.
STATIC_RESERVED=(/healthz /_kit_ev)

# ---------------------------------------------------------------------------
# Reserved-path checks
# ---------------------------------------------------------------------------

# True when $1 overlaps a static reserved prefix or any inbound route prefix.
overlaps_reserved() {
  local p="$1" r
  for r in "${STATIC_RESERVED[@]}" "${ROUTE_PATHS[@]}"; do
    paths_overlap "$p" "$r" && return 0
  done
  return 1
}

# Usable panel path: safe characters, not "/", no overlap with reserved prefixes.
panel_path_usable() {
  local p="$1"
  [[ -n "$p" && "$p" != "/" ]] && safe_path "$p" && ! overlaps_reserved "$p"
}

# ---------------------------------------------------------------------------
# Runtime state (re-read every watcher tick, so panel-side changes are
# picked up without a redeploy)
# ---------------------------------------------------------------------------
_add_sub_path() {   # _add_sub_path <raw path> <quiet>
  local p x
  p="$(norm_dir_path "$1")"
  [[ -z "$p" || "$p" == "/" ]] && return 0
  if ! safe_path "$p" || overlaps_reserved "$p" || paths_overlap "$p" "$CUR_PANEL_PATH"; then
    [[ "$2" == 1 ]] || warn "subscription path '$p' is unusable (bad characters or overlaps panel/inbound/reserved paths) — skipped"
    return 0
  fi
  for x in "${CUR_SUB_PATHS[@]}"; do [[ "$x" == "$p" ]] && return 0; done
  CUR_SUB_PATHS+=("$p")
}

collect_state() {   # collect_state <quiet: 0|1>
  local quiet="${1:-0}" lp lport sport raw

  # Panel path / port: follow the panel's live settings when they are valid,
  # so changing them in the panel UI does not lock you out.
  lp="$(norm_dir_path "$(adapter_live_panel_path)")"
  if panel_path_usable "$lp"; then CUR_PANEL_PATH="$lp"; else CUR_PANEL_PATH="$PANEL_PATH"; fi

  lport="$(adapter_live_panel_port)"
  if is_port "$lport"; then CUR_PANEL_PORT="$lport"; else CUR_PANEL_PORT="$PANEL_PORT"; fi

  sport="$(adapter_sub_port)"
  if is_port "$sport"; then CUR_SUB_PORT="$sport"; else CUR_SUB_PORT=2096; fi

  CUR_SUB_PATHS=()
  if [[ "${SUB_FALLBACK_ONLY:-0}" == 1 ]]; then
    _add_sub_path "/sub/" "$quiet"
  else
    while IFS= read -r raw; do
      _add_sub_path "$raw" "$quiet"
    done < <(adapter_sub_paths)
  fi
}

# ---------------------------------------------------------------------------
# Optional connection events (open / close webhooks)
#
# nginx `mirror` fires a sub-request when a tunnel opens and `post_action`
# fires one when it closes. The receiver (e.g. a Telegram bot) learns which
# client IP is on which inbound path. Disabled unless EVENT_WEBHOOK_URL is set.
# `post_action` is undocumented but has been stable in nginx for years.
# ---------------------------------------------------------------------------
setup_events() {
  EVENTS_ACTIVE=0
  local url="${EVENT_WEBHOOK_URL:-}"
  case "${url,,}" in ""|off|none|false|0) log "connection events: off"; return 0 ;; esac

  # Strict validation: the URL is pasted into nginx.conf, so anything that
  # could break out of the directive (spaces, quotes, ; { }) is rejected.
  if [[ ! "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+-]*)?(\?[A-Za-z0-9._~%\&=+-]*)?$ ]]; then
    warn "EVENT_WEBHOOK_URL is not a plain http(s) URL — connection events disabled"
    return 0
  fi

  EV_BASE="$url"
  if [[ "$url" == *\?* ]]; then EV_SEP="&"; else EV_SEP="?"; fi
  EV_HOST="${url#*://}"; EV_HOST="${EV_HOST%%/*}"; EV_HOST="${EV_HOST%%\?*}"; EV_HOST="${EV_HOST%%:*}"

  # nginx needs an explicit resolver because proxy_pass contains variables.
  # IPv6 nameservers MUST be bracketed ("[fd12::10]"); an unbracketed one
  # makes nginx reject the whole config ("invalid port in resolver").
  local ns list=""
  _add_ns() {
    local a="$1"
    [[ -z "$a" ]] && return 0
    if [[ "$a" == *:* ]]; then
      [[ "$a" =~ ^[0-9A-Fa-f:.]+$ ]] || return 0
      a="[$a]"
    else
      [[ "$a" =~ ^[0-9.]+$ ]] || return 0
    fi
    [[ " $list " == *" $a "* ]] || list="${list:+$list }$a"
  }
  while read -r ns; do _add_ns "$ns"; done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null)
  _add_ns 1.1.1.1
  _add_ns 8.8.8.8
  EV_RESOLVERS="$list"

  EVENTS_ACTIVE=1
  log "connection events: on (target host: $EV_HOST)"

  # Optional self-test so a wrong key shows up in the boot log, not hours later.
  if command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${EV_BASE}${EV_SEP}selftest=1" 2>/dev/null || true)"
    case "$code" in
      2??) log "connection events: self-test OK ($code)" ;;
      000|"") log "connection events: self-test skipped (no outbound network yet)" ;;
      *) warn "connection events: self-test returned HTTP $code — check EVENT_WEBHOOK_URL" ;;
    esac
  fi
}

_event_location() {   # _event_location <open|close>
  local out
  printf -v out '        location = /_kit_ev_%s {\n            internal;\n            resolver %s valid=300s ipv6=off;\n            proxy_method GET;\n            proxy_pass %s%sev=%s&u=$ev_path&ip=$client_real_ip&h=$host;\n            # Forward nothing from the client: WebSocket headers would make the\n            # receiver (or Cloudflare in front of it) treat this as an upgrade.\n            proxy_pass_request_headers off;\n            proxy_pass_request_body    off;\n            proxy_set_header Content-Length "";\n            proxy_set_header Connection "";\n            proxy_http_version 1.1;\n            proxy_ssl_server_name on;\n            proxy_ssl_name %s;\n            proxy_connect_timeout 2s;\n            proxy_send_timeout    3s;\n            proxy_read_timeout    6s;\n        }\n' \
    "$1" "$EV_RESOLVERS" "$EV_BASE" "$EV_SEP" "$1" "$EV_HOST"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
_inbound_location() {   # _inbound_location <nginx location spec> <port> <events 0|1>
  local out ev=""
  [[ "$3" == 1 ]] && ev=$'            mirror /_kit_ev_open;\n            post_action /_kit_ev_close;\n'
  printf -v out '        location %s {\n%s            proxy_pass http://127.0.0.1:%s;\n            include %s;\n        }\n' \
    "$1" "$ev" "$2" "$PROXY_SNIPPET"
  printf '%s' "$out"
}

render_nginx_conf() {   # render_nginx_conf <output file>
  local out_file="$1" tpl blk i p
  local listen ev_locs="" panel_locs sub_locs="" root_loc="" in_locs="" access_log
  local ev="${EVENTS_ACTIVE:-0}"

  [[ -r "$NGINX_TEMPLATE" ]] || { warn "template missing: $NGINX_TEMPLATE"; return 1; }
  tpl="$(<"$NGINX_TEMPLATE")"

  # Listen on IPv4, plus IPv6 when the kernel supports it (Railway private
  # networking is IPv6-only; binding [::] on a host without IPv6 would fail).
  printf -v listen '        listen %s default_server;\n' "$HTTP_PORT"
  if [[ -e /proc/net/if_inet6 ]]; then
    printf -v blk '        listen [::]:%s default_server;\n' "$HTTP_PORT"; listen+="$blk"
  fi

  if is_true "${NGINX_ACCESS_LOG:-false}"; then
    access_log='access_log /dev/stdout;'
  else
    access_log='access_log off;'
  fi

  if [[ "$ev" == 1 ]]; then
    ev_locs="        # ---- Internal connection-event hooks (EVENT_WEBHOOK_URL) --------------"$'\n'
    ev_locs+="$(_event_location open)"$'\n'
    ev_locs+="$(_event_location close)"$'\n'
  fi

  # Panel: "/path" -> "/path/" redirect, then pass the full URI through (the
  # panel itself is configured with the same base path, so no rewrite needed).
  printf -v panel_locs '        location = %s {\n            return 302 %s;\n        }\n        location %s {\n            proxy_pass http://127.0.0.1:%s;\n            include %s;\n        }\n' \
    "${CUR_PANEL_PATH%/}" "$CUR_PANEL_PATH" "$CUR_PANEL_PATH" "$CUR_PANEL_PORT" "$PROXY_SNIPPET"

  # Subscription paths all go to the panel's internal subscription server.
  for p in "${CUR_SUB_PATHS[@]}"; do
    printf -v blk '        location %s {\n            proxy_pass http://127.0.0.1:%s;\n            include %s;\n        }\n' \
      "$p" "$CUR_SUB_PORT" "$PROXY_SNIPPET"
    sub_locs+="$blk"
  done
  [[ -z "$sub_locs" ]] && sub_locs="        # (subscription disabled in the panel)"$'\n'

  # Optional: bare domain -> panel. Only plain browser requests are redirected;
  # upgrade requests on "/" still reach the default inbound.
  if is_true "${ROOT_REDIRECT:-false}" && [[ "${DEFAULT_INBOUND_PORT}" != "off" ]]; then
    local evl=""
    [[ "$ev" == 1 ]] && evl=$'            mirror /_kit_ev_open;\n            post_action /_kit_ev_close;\n'
    printf -v root_loc '        location = / {\n            if ($http_upgrade = "") {\n                return 302 %s;\n            }\n%s            proxy_pass http://127.0.0.1:%s;\n            include %s;\n        }\n' \
      "$CUR_PANEL_PATH" "$evl" "$DEFAULT_INBOUND_PORT" "$PROXY_SNIPPET"
  elif is_true "${ROOT_REDIRECT:-false}"; then
    printf -v root_loc '        location = / {\n            return 302 %s;\n        }\n' "$CUR_PANEL_PATH"
  else
    root_loc="        # (ROOT_REDIRECT=false: the bare domain does not reveal the panel)"$'\n'
  fi

  # Extra inbounds: one prefix per internal port.
  for i in "${!ROUTE_PATHS[@]}"; do
    in_locs+="$(_inbound_location "${ROUTE_PATHS[$i]}" "${ROUTE_PORTS[$i]}" "$ev")"$'\n'
  done
  # Catch-all: every other path goes to the default inbound (any path you like).
  if [[ "${DEFAULT_INBOUND_PORT}" == "off" ]]; then
    in_locs+=$'        location / {\n            return 404;\n        }\n'
  else
    in_locs+="$(_inbound_location "/" "$DEFAULT_INBOUND_PORT" "$ev")"$'\n'
  fi

  tpl=${tpl//@@WORKERS@@/"${NGINX_WORKERS:-1}"}
  tpl=${tpl//@@ACCESS_LOG@@/"$access_log"}
  tpl=${tpl//@@LISTEN@@/"${listen%$'\n'}"}
  tpl=${tpl//@@HTTP_PORT@@/"$HTTP_PORT"}
  tpl=${tpl//@@EVENT_LOCATIONS@@/"${ev_locs%$'\n'}"}
  tpl=${tpl//@@PANEL_LOCATIONS@@/"${panel_locs%$'\n'}"}
  tpl=${tpl//@@SUB_LOCATIONS@@/"${sub_locs%$'\n'}"}
  tpl=${tpl//@@ROOT_LOCATION@@/"${root_loc%$'\n'}"}
  tpl=${tpl//@@INBOUND_LOCATIONS@@/"${in_locs%$'\n'}"}

  printf '%s\n' "$tpl" >"$out_file"
}

# ---------------------------------------------------------------------------
# Watcher: keeps nginx in sync with the panel's subscription / panel settings.
# The panel restarts its own sub server when you save settings, but nginx
# only knows the paths it was rendered with — this loop closes that gap.
# An invalid candidate config is never applied.
# ---------------------------------------------------------------------------
sub_watch_loop() {
  set +e   # a transient error must never kill the watcher
  local interval="${SUB_WATCH_INTERVAL:-15}" fails=0
  local cur=/etc/nginx/nginx.conf next=/etc/nginx/nginx.conf.next
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 5 )) || interval=15

  while true; do
    if (( fails > 0 )); then sleep 60; else sleep "$interval"; fi

    collect_state 1
    if ! render_nginx_conf "$next"; then fails=1; continue; fi

    if cmp -s "$next" "$cur"; then
      rm -f "$next"; fails=0; continue
    fi

    if ! nginx -t -q -c "$next" >/tmp/kit-watch-test.log 2>&1; then
      warn "watcher: regenerated config is invalid — keeping the current one"
      head -3 /tmp/kit-watch-test.log | sed 's/^/    /' >&2
      rm -f "$next"; fails=1; continue
    fi

    mv -f "$next" "$cur"
    if nginx -s reload >/tmp/kit-watch-reload.log 2>&1; then
      log "watcher: panel settings changed -> nginx reloaded (panel ${CUR_PANEL_PATH} -> :${CUR_PANEL_PORT}; sub ${CUR_SUB_PATHS[*]:-none} -> :${CUR_SUB_PORT})"
      fails=0
    else
      warn "watcher: nginx reload failed"
      head -3 /tmp/kit-watch-reload.log | sed 's/^/    /' >&2
      fails=1
    fi
  done
}
