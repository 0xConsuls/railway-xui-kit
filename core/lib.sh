#!/usr/bin/env bash
# =============================================================================
# core/lib.sh — shared helpers. Sourced by entrypoint.sh and the adapters;
# never executed directly.
# =============================================================================

# Bash 5.2 turns on "patsub_replacement" by default, which makes an unquoted
# '&' inside ${var//pattern/replacement} expand to the matched text. Webhook
# URLs contain '&', so switch it off to keep template substitution literal.
shopt -u patsub_replacement 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '%s [kit] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '%s [kit] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '%s [kit] FATAL: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Small predicates
# ---------------------------------------------------------------------------
is_true() {
  case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

is_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# A path is "safe" when it can be pasted into an nginx `location` directive
# without quoting and without any risk of config injection.
safe_path() {
  [[ "${1:-}" =~ ^/[A-Za-z0-9/_.-]*$ ]] && (( ${#1} <= 64 )) && [[ "$1" != *//* ]]
}

# Two prefixes "overlap" when one is a prefix of the other. nginx picks the
# longest matching prefix, so overlapping prefixes silently steal traffic
# from each other (e.g. /in1 would swallow /in1panel/).
paths_overlap() {
  local a="$1" b="$2"
  [[ "$a" == "$b" || "$a" == "$b"* || "$b" == "$a"* ]]
}

# ---------------------------------------------------------------------------
# Path normalisation
# ---------------------------------------------------------------------------

# "sub" -> "/sub/", "/sub" -> "/sub/". Empty in -> empty out.
norm_dir_path() {
  local p="${1:-}"
  p="${p//$'\r'/}"; p="${p//$'\n'/}"
  [[ -z "$p" ]] && return 0
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="$p/"
  printf '%s' "$p"
}

# Extract the path of a URI: "https://host/sub/" -> "/sub/".
# Returns nothing for an empty URI or a bare "/".
uri_path() {
  local u="${1:-}" rest
  u="${u//$'\r'/}"; u="${u//$'\n'/}"
  [[ -z "$u" ]] && return 0
  case "$u" in
    *://*) rest="${u#*://}"
           if [[ "$rest" == */* ]]; then u="/${rest#*/}"; else u="/"; fi ;;
    /*)    ;;
    *)     u="/$u" ;;
  esac
  u="${u%%\?*}"; u="${u%%#*}"
  [[ "$u" == "/" ]] && return 0
  norm_dir_path "$u"
}

# ---------------------------------------------------------------------------
# Randomness
# ---------------------------------------------------------------------------
rand_hex() {   # rand_hex <bytes>
  od -An -N"${1:-8}" -tx1 /dev/urandom | tr -d ' \n'
}

rand_password() {   # 20 chars, alphanumeric (safe for CLI flags and logs)
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20
}

# ---------------------------------------------------------------------------
# SQLite helpers for panels that keep settings in a key/value table named
# `settings` with columns (id, key, value); 3x-ui uses this
# layout. Keys passed to these helpers are always constants from our own
# code; values are escaped.
# ---------------------------------------------------------------------------
_sql_escape() { printf '%s' "${1//\'/\'\'}"; }

db_ready() {   # db_ready <db>  -> true if the settings table exists
  [[ -f "$1" ]] && command -v sqlite3 >/dev/null 2>&1 &&
    sqlite3 -cmd '.timeout 5000' "$1" 'SELECT key, value FROM settings LIMIT 0;' >/dev/null 2>&1
}

db_get() {     # db_get <db> <key>
  [[ -f "$1" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 -readonly -noheader -cmd '.timeout 3000' "$1" \
    "SELECT value FROM settings WHERE key='$(_sql_escape "$2")' LIMIT 1;" 2>/dev/null | tr -d '\r\n'
}

db_set() {     # db_set <db> <key> <value>   (upsert; no UNIQUE index assumed)
  db_ready "$1" || return 1
  local k v
  k="$(_sql_escape "$2")"; v="$(_sql_escape "$3")"
  sqlite3 -cmd '.timeout 5000' "$1" "
    UPDATE settings SET value='$v' WHERE key='$k';
    INSERT INTO settings(key, value)
      SELECT '$k', '$v' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$k');
  " >/dev/null 2>&1
}

db_set_if_empty() {   # only writes when the key is missing or blank
  local cur
  cur="$(db_get "$1" "$2")"
  [[ -n "$cur" ]] && return 0
  db_set "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

# The public host name users connect to. PUBLIC_HOST wins (use it for a custom
# domain behind Cloudflare); otherwise Railway's generated domain.
public_host() {
  local h="${PUBLIC_HOST:-${RAILWAY_PUBLIC_DOMAIN:-}}"
  h="${h#http://}"; h="${h#https://}"; h="${h%%/*}"
  [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] && printf '%s' "$h"
}

# True when a path is a real mount point (i.e. a persistent volume is attached).
is_mountpoint() {
  grep -qs " ${1%/} " /proc/mounts
}
