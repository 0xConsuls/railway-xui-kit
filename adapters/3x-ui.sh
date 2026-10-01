#!/usr/bin/env bash
# =============================================================================
# adapters/3x-ui.sh — adapter for MHSanaei/3x-ui (Xray-core).
#
# Adapter contract (every adapter must define these):
#   Variables : DATA_DIR  PANEL_DB  PANEL_PORT  DEFAULT_SUB_PORT
#   Functions : adapter_label            -> human-readable name/version
#               adapter_live_panel_path  -> panel base path from the panel DB
#               adapter_live_panel_port  -> panel port from the panel DB
#               adapter_sub_port         -> internal subscription-server port
#               adapter_sub_paths        -> candidate subscription paths, one per line
#               adapter_prepare          -> apply settings before start
#               adapter_start            -> start the panel in background, set PANEL_PID
#               adapter_post_start       -> optional sidecars
#               adapter_diagnostics      -> optional extra boot log hints
# =============================================================================

XUI_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
DATA_DIR="${XUI_DB_FOLDER:-/etc/x-ui}"
PANEL_DB="$DATA_DIR/x-ui.db"
PANEL_PORT="${PANEL_INTERNAL_PORT:-2053}"
DEFAULT_SUB_PORT=2096

_xui() { ( cd "$XUI_DIR" && ./x-ui "$@" ); }

adapter_label() {
  printf '3x-ui %s' "$(_xui -v 2>/dev/null | head -1 || echo '?')"
}

adapter_live_panel_path() { db_get "$PANEL_DB" webBasePath; }
adapter_live_panel_port() { db_get "$PANEL_DB" webPort; }

adapter_sub_port() {
  local p; p="$(db_get "$PANEL_DB" subPort)"
  if is_port "$p"; then printf '%s' "$p"; else printf '%s' "$DEFAULT_SUB_PORT"; fi
}

# The sub server may be reachable under several paths depending on which
# settings the user filled in. Serving all candidates means a subscription
# link never 404s: the path inside Subscription URI, Subscription Path and
# the default /sub/ (plus JSON / Clash variants when enabled).
adapter_sub_paths() {
  [[ "$(db_get "$PANEL_DB" subEnable)" == "false" ]] && return 0
  uri_path "$(db_get "$PANEL_DB" subURI)"; echo
  db_get "$PANEL_DB" subPath; echo
  echo "/sub/"
  if [[ "$(db_get "$PANEL_DB" subJsonEnable)" == "true" ]]; then
    uri_path "$(db_get "$PANEL_DB" subJsonURI)"; echo
    db_get "$PANEL_DB" subJsonPath; echo
    echo "/json/"
  fi
  if [[ "$(db_get "$PANEL_DB" subClashEnable)" == "true" ]]; then
    uri_path "$(db_get "$PANEL_DB" subClashURI)"; echo
    db_get "$PANEL_DB" subClashPath; echo
    echo "/clash/"
  fi
}

adapter_prepare() {
  local fresh=0 host sp pw
  [[ -f "$PANEL_DB" ]] || fresh=1
  mkdir -p "$DATA_DIR" "${XUI_LOG_FOLDER:-/var/log/x-ui}"

  # Port + base path through the official CLI (this also creates a fresh DB).
  _xui setting -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" >/dev/null 2>&1 ||
    warn "x-ui setting -port/-webBasePath failed"

  # --- Credentials -------------------------------------------------------------
  # Never ship admin/admin to the public internet: explicit env credentials
  # win; otherwise a fresh database gets a random password printed once.
  if [[ -n "${ADMIN_USERNAME:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    _xui setting -username "$ADMIN_USERNAME" -password "$ADMIN_PASSWORD" >/dev/null 2>&1 &&
      log "admin credentials applied from ADMIN_USERNAME / ADMIN_PASSWORD" ||
      warn "could not apply admin credentials"
  elif (( fresh )); then
    pw="$(rand_password)"
    if _xui setting -username admin -password "$pw" >/dev/null 2>&1; then
      log "================= INITIAL ADMIN CREDENTIALS ================="
      log "  username: admin"
      log "  password: $pw"
      log "  Change them in the panel, or set ADMIN_USERNAME/ADMIN_PASSWORD."
      log "  (Anyone with access to these deploy logs can read this line.)"
      log "============================================================="
    fi
  fi

  # --- Bind internal servers to loopback ----------------------------------------
  # Only nginx should reach the panel and the sub server. This also stops a
  # Railway TCP proxy from accidentally exposing the panel unencrypted.
  db_set "$PANEL_DB" webListen 127.0.0.1 || warn "could not set webListen"
  db_set "$PANEL_DB" subListen 127.0.0.1 || warn "could not set subListen"

  # SUB_PATH variable -> write it into the panel, so panel and nginx agree.
  if [[ -n "${SUB_PATH:-}" ]]; then
    sp="$(norm_dir_path "$SUB_PATH")"
    if safe_path "$sp"; then db_set "$PANEL_DB" subPath "$sp"; else warn "SUB_PATH '$SUB_PATH' ignored (bad characters)"; fi
  fi

  # --- Subscription URI ------------------------------------------------------------
  # The panel builds sub links as http://SubDomain:SubPort/SubPath unless
  # Subscription URI is set — on Railway that yields http://host:2096/...,
  # which nobody can open. Pre-fill it once (never overwrite a user value).
  host="$(public_host || true)"
  if is_true "${AUTO_SUB_URI:-true}" && [[ -n "$host" ]]; then
    sp="$(norm_dir_path "$(db_get "$PANEL_DB" subPath)")"; [[ -n "$sp" ]] || sp="/sub/"
    db_set_if_empty "$PANEL_DB" subURI "https://${host}${sp}" &&
      log "subscription URI: $(db_get "$PANEL_DB" subURI)"
  fi

  _xui_setup_fail2ban
}

# 3x-ui only enables the per-client "IP Limit" field when fail2ban-client is
# present; otherwise it silently resets limitIp to 0. Railway containers have
# no iptables permission, so bans are not enforced — but excess connections
# are still dropped by the panel and the setting is preserved.
_xui_setup_fail2ban() {
  is_true "${XUI_ENABLE_FAIL2BAN:-true}" || return 0
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  local logdir="${XUI_LOG_FOLDER:-/var/log/x-ui}"
  mkdir -p "$logdir" /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d /var/run/fail2ban
  touch "$logdir/3xipl.log" "$logdir/3xipl-banned.log"

  cat >/etc/fail2ban/jail.d/3x-ipl.conf <<EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=$logdir/3xipl.log
maxretry=1
findtime=32
bantime=30m
EOF

  cat >/etc/fail2ban/filter.d/3x-ipl.conf <<'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

  # The panel and nginx ports are exempt so you can never lock yourself out.
  cat >/etc/fail2ban/action.d/3x-ipl.conf <<EOF
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>
actionstop  = <iptables> -D <chain> -j f2b-<name>
              <actionflush>
              <iptables> -X f2b-<name>
actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'
actionban   = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $logdir/3xipl-banned.log
actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> $logdir/3xipl-banned.log

[Init]
name = default
chain = INPUT
exemptports = ${PANEL_PORT},${HTTP_PORT}
EOF

  if fail2ban-client -x start >/dev/null 2>&1; then
    log "fail2ban started (IP limit enforced where iptables is permitted)"
  else
    log "fail2ban could not start (no iptables permission) — IP Limit stays editable, bans are not enforced"
  fi
}

adapter_start() {
  cd "$XUI_DIR" || die "missing $XUI_DIR"
  ./x-ui &
  PANEL_PID=$!
  cd - >/dev/null || true
}

adapter_post_start() {
  # Auto-fix inbound sockopt (real client IP) + optional external proxy.
  if is_true "${XUI_AUTO_SOCKOPT:-true}"; then
    "$KIT_DIR/adapters/3x-ui-sockopt.sh" &
    _children+=("$!")
  fi
}

adapter_diagnostics() {
  local uri; uri="$(db_get "$PANEL_DB" subURI)"
  if [[ -z "$uri" ]]; then
    warn "Subscription URI is empty — the panel will show http://<host>:2096/... links that do not work here."
    warn "Set it in: Settings → Subscription → Subscription URI = https://<your-domain>/sub/"
  elif [[ "$uri" == http://* || "$uri" == *":2096"* ]]; then
    warn "Subscription URI '$uri' points at http or the internal port 2096 — use https://<your-domain>/<sub-path>/"
  fi
  local sd; sd="$(db_get "$PANEL_DB" subDomain)"
  [[ -n "$sd" ]] && warn "Sub Domain is set to '$sd' — the sub server will reject any other Host (clear it if links 404)"
  return 0
}
