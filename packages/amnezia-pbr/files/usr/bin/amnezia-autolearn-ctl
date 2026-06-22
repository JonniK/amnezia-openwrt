#!/bin/sh
# amnezia-autolearn-ctl: UI/CLI control for the auto-learning list.
set -u
AL_DIR="${AL_DIR:-/etc/amnezia}"
AUTO_LIST="${AUTO_LIST:-$AL_DIR/force.d/auto.list}"
CAND="$AL_DIR/autolearn/candidates.tsv"
DENY="$AL_DIR/autolearn/deny.list"
MANUAL="$AL_DIR/force-tunnel.list"
# AL_LOCKDIR must match the same default used by the pass script so they
# genuinely mutually-exclude each other.
AL_LOCKDIR="${AL_LOCKDIR:-$AL_DIR/autolearn/.pass.lock}"
AMNEZIA_FORCE_LOAD="${AMNEZIA_FORCE_LOAD:-amnezia-force-load}"
AL_INIT="${AL_INIT:-/etc/init.d/amnezia-autolearn}"
mkdir -p "$AL_DIR/force.d" "$AL_DIR/autolearn"

_je() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t' | tr -d '\000-\037'; }
_reload() { "$AMNEZIA_FORCE_LOAD" >/dev/null 2>&1 || true; }
# Bounded poll-wait (~25s) so a ctl op waits for a running pass but never hangs
# past rpcd's ~30s exec timeout. Proceeds best-effort on timeout.
_lock() {
  mkdir -p "$AL_DIR/autolearn" 2>/dev/null || true
  _i=0
  while ! mkdir "$AL_LOCKDIR" 2>/dev/null; do
    _i=$((_i+1)); [ "$_i" -ge 25 ] && return 0   # ~25s bound -> proceed best-effort
    sleep 1
  done
  trap 'rmdir "$AL_LOCKDIR" 2>/dev/null' EXIT INT TERM
}

cmd="${1:-status}"
case "$cmd" in
  list)
    printf '['; _first=1
    [ -s "$AUTO_LIST" ] && while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      _row=$(awk -F'\t' -v d="$_d" '$1==d{print; exit}' "$CAND" 2>/dev/null)
      _reason=$(printf '%s' "$_row" | cut -f7); _added=$(printf '%s' "$_row" | cut -f5)
      [ "$_first" = 1 ] || printf ','; _first=0
      printf '{"domain":"%s","reason":"%s","added":"%s"}' "$(_je "$_d")" "$(_je "$_reason")" "$(_je "$_added")"
    done < "$AUTO_LIST"
    printf ']\n'
    ;;
  status)
    _en=$(uci -q get amnezia.config.autolearn_enabled 2>/dev/null); _en=${_en:-0}
    # NOT `grep -c . || echo 0`: BusyBox grep -c on an empty file prints 0 AND
    # exits 1, so `|| echo 0` would append a second 0 -> invalid JSON. Use the
    # repo's awk NR idiom (cf. amnezia-force-update.sh).
    _cnt=$(awk 'END{print NR}' "$AUTO_LIST" 2>/dev/null); _cnt=${_cnt:-0}
    printf '{"enabled":%s,"count":%s}\n' "$_en" "$_cnt"
    ;;
  veto)
    _d="${2:?domain}"; _lock
    _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -Fvx "$_d" "$AUTO_LIST" 2>/dev/null > "$_t"; mv "$_t" "$AUTO_LIST"
    grep -Fqx "$_d" "$DENY" 2>/dev/null || printf '%s\n' "$_d" >> "$DENY"
    _reload
    ;;
  promote)
    _d="${2:?domain}"; _lock
    grep -Fqx "$_d" "$MANUAL" 2>/dev/null || printf '%s\n' "$_d" >> "$MANUAL"
    _t=$(mktemp 2>/dev/null || echo "$AUTO_LIST.$$"); grep -Fvx "$_d" "$AUTO_LIST" 2>/dev/null > "$_t"; mv "$_t" "$AUTO_LIST"
    _reload
    ;;
  purge)
    _lock; : > "$AUTO_LIST"; : > "$CAND"; _reload
    ;;
  set-enabled)
    _v="${2:?0|1}"; case "$_v" in 0|1) ;; *) echo '{"error":"invalid"}'; exit 2 ;; esac
    uci set "amnezia.config.autolearn_enabled=$_v"; uci commit amnezia
    if [ "$_v" = 1 ]; then "$AL_INIT" enable >/dev/null 2>&1 || true
    else "$AL_INIT" disable >/dev/null 2>&1 || true; fi
    ;;
  *) echo '{"error":"unknown command"}'; exit 2 ;;
esac
