#!/bin/sh
# amnezia-dns-ctl: encrypted-DNS state machine. POSIX sh.
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
for _l in amnezia-common.sh amnezia-dns-lib.sh; do
  # shellcheck disable=SC1091
  if [ -f "$AMNEZIA_LIB/$_l" ]; then . "$AMNEZIA_LIB/$_l"; else . "$(dirname "$0")/lib/$_l"; fi
done

_has_bin() {
  [ -n "${AMNEZIA_HAS_BIN:-}" ] && { [ "$AMNEZIA_HAS_BIN" = 1 ]; return; }
  command -v stubby >/dev/null 2>&1 && command -v https-dns-proxy >/dev/null 2>&1
}

cmd_apply() {
  _prov=$(uci -q get amnezia.config.dns_provider || echo quad9)
  dnsmasq_lock
  if ! _has_bin; then
    amz_log "dns: stubby/https-dns-proxy missing -> plain provider DNS"
    dns_dnsmasq_restore; dns_dnsmasq_add_plain
    uci set amnezia.config.dns_active_tier=plaintext; uci commit amnezia
    dns_dnsmasq_reload || true; dnsmasq_unlock; return 0
  fi
  if ! dns_profile "$_prov"; then amz_log "dns: bad profile $_prov"; dnsmasq_unlock; return 1; fi
  dns_render_stubby; dns_render_doh
  dns_dnsmasq_encrypted
  # HIGH leak fix: drop any plaintext servers that may be ahead of the encrypted
  # listeners (e.g. watchdog entered plaintext between applies). Then re-append
  # them AFTER encrypted listeners so the order is always [5453, 5454, WAN...]
  # under strict-order — never plaintext-first.
  dns_dnsmasq_del_plain
  [ "$(uci -q get amnezia.config.dns_active_tier)" = plaintext ] && dns_dnsmasq_add_plain
  dns_iprule_flush   # clear any stale pref-30900 rule (revert-path leak fix)
  dns_iprule_set "$DNS_DOT_IP"
  if dns_dnsmasq_reload; then dnsmasq_unlock; return 0; fi
  amz_log "dns: dnsmasq --test failed"; dnsmasq_unlock; return 1
}

AMNEZIA_NSLOOKUP="${AMNEZIA_NSLOOKUP:-nslookup}"
AMNEZIA_DNS_INIT="${AMNEZIA_DNS_INIT:-/etc/init.d/amnezia-dns}"

_probe_listener() {                    # $1 = 127.0.0.1#<port>
  case "$1" in
    *"#$DOT_PORT") [ -n "${AMNEZIA_VERIFY_DOT:-}" ] && { [ "$AMNEZIA_VERIFY_DOT" = pass ]; return; } ;;
    *"#$DOH_PORT") [ -n "${AMNEZIA_VERIFY_DOH:-}" ] && { [ "$AMNEZIA_VERIFY_DOH" = pass ]; return; } ;;
  esac
  # L1/L4: honor _PROBE_TIMEOUT override (status path sets 1s; default 3s).
  "$AMNEZIA_NSLOOKUP" "-timeout=${_PROBE_TIMEOUT:-3}" openwrt.org "$1" >/dev/null 2>&1
}
_verify_encrypted() { _probe_listener "127.0.0.1#$DOT_PORT" || _probe_listener "127.0.0.1#$DOH_PORT"; }

cmd_disable() {
  # Capture whether DoT was actually enabled before we change anything (L8).
  _was_enabled=$(uci -q get amnezia.config.dot_enabled 2>/dev/null || echo 0)
  # H1: guard against re-entry from stop_service (sentinel prevents recursion).
  # M3: stop the watchdog (amnezia-dns stop) FIRST, before tearing down the
  #     daemons it monitors, so it can't race and flip us back to plaintext.
  [ -n "${AMNEZIA_DNS_STOPPING:-}" ] || "$AMNEZIA_DNS_INIT" stop 2>/dev/null || true
  # Stop encrypted-DNS daemons.
  "$AMNEZIA_STUBBY_INIT" stop 2>/dev/null || true
  # shellcheck disable=SC2153
  "$AMNEZIA_DOH_INIT" stop 2>/dev/null || true
  # L8: only restore/reload dnsmasq if DoT was previously active (idempotent when already plain).
  if [ "$_was_enabled" = 1 ]; then
    dnsmasq_lock; dns_dnsmasq_restore; dns_dnsmasq_reload || true; dnsmasq_unlock
  fi
  # L3: unconditional ip-rule flush — doesn't depend on profile parsing succeeding.
  dns_iprule_flush
  uci set amnezia.config.dot_enabled=0
  uci -q delete amnezia.config.dns_active_tier 2>/dev/null || true
  uci commit amnezia
}

cmd_enable() {
  _has_bin || { echo "install stubby + https-dns-proxy first" >&2; return 1; }
  uci set amnezia.config.dot_enabled=1; uci commit amnezia
  cmd_apply || { cmd_disable; return 1; }
  if _verify_encrypted; then
    "$AMNEZIA_DNS_INIT" start 2>/dev/null || true   # launch the procd watchdog (was only started at boot)
    return 0
  fi
  amz_log "dns: encrypted verify failed -> auto-revert"; cmd_disable; return 1
}

cmd_set_provider() {
  _new=$1; dns_profile "$_new" || { echo "bad provider $_new" >&2; return 2; }
  _prev=$(uci -q get amnezia.config.dns_provider || echo quad9)
  # M1: clear the previous provider's pinned ip rule before switching so no
  # stale rule for the old DoT IP lingers after the provider change.
  if [ "$(uci -q get amnezia.config.dot_enabled)" = 1 ]; then
    if dns_profile "$_prev" 2>/dev/null; then dns_iprule_clear "$DNS_DOT_IP"; fi
  fi
  uci set "amnezia.config.dns_provider_prev=$_prev"
  uci set "amnezia.config.dns_provider=$_new"; uci commit amnezia
  [ "$(uci -q get amnezia.config.dot_enabled)" = 1 ] || return 0
  if cmd_apply && _verify_encrypted; then return 0; fi
  uci set "amnezia.config.dns_provider=$_prev"; uci commit amnezia
  if cmd_apply && _verify_encrypted; then return 1; fi
  cmd_disable; return 1
}

_now() { [ -n "${AMNEZIA_NOW:-}" ] && { echo "$AMNEZIA_NOW"; return; }; date +%s 2>/dev/null || echo 0; }
_set_tier() { uci set "amnezia.config.dns_active_tier=$1"; uci commit amnezia; }

_enter_plain() {
  dnsmasq_lock; dns_dnsmasq_add_plain
  if dns_dnsmasq_reload; then _r=0; else _r=1; fi
  dnsmasq_unlock
  [ "$_r" = 0 ] || { amz_log "dns: plaintext reload failed; not marking plaintext tier"; return 1; }
  _set_tier plaintext
  # M4: persist entry timestamp so dwell survives procd respawn.
  uci set "amnezia.config.dns_plain_ts=$(_now)"; uci commit amnezia
}
_exit_plain() {
  dnsmasq_lock; dns_dnsmasq_del_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
  # M4: clear stale timestamp when leaving plaintext tier.
  uci -q delete amnezia.config.dns_plain_ts 2>/dev/null || true; uci commit amnezia
}

cmd_watchdog() {
  _n=${AMNEZIA_DNS_WD_N:-3}; _m=${AMNEZIA_DNS_WD_M:-2}; _dwell=${AMNEZIA_DNS_WD_DWELL:-120}
  _fail=0; _ok=0; _ticks_done=0
  _tier=$(uci -q get amnezia.config.dns_active_tier 2>/dev/null || echo "")
  # M4: load persisted entry timestamp (survives procd respawn while in plaintext).
  _entered=$(uci -q get amnezia.config.dns_plain_ts 2>/dev/null || echo 0)
  # If tier=plaintext but no timestamp (legacy / first-time), seed with now so
  # the full dwell must still elapse before recovery — never skip it on respawn.
  if [ "$_tier" = plaintext ] && [ "$_entered" = 0 ]; then _entered=$(_now); fi
  while true; do
    if _probe_listener "127.0.0.1#$DOT_PORT"; then
      _fail=0; _ok=$((_ok + 1))
      if [ "$_tier" = plaintext ]; then
        if [ "$_ok" -ge "$_m" ] && [ "$(( $(_now) - _entered ))" -ge "$_dwell" ]; then _exit_plain; _tier="dot"; _set_tier dot; fi
      else
        [ "$_tier" = dot ] || { _tier="dot"; _set_tier dot; }
      fi
    elif _probe_listener "127.0.0.1#$DOH_PORT"; then
      _fail=0; _ok=$((_ok + 1))
      if [ "$_tier" = plaintext ]; then
        if [ "$_ok" -ge "$_m" ] && [ "$(( $(_now) - _entered ))" -ge "$_dwell" ]; then _exit_plain; _tier="doh"; _set_tier doh; fi
      else
        [ "$_tier" = doh ] || { _tier="doh"; _set_tier doh; }
      fi
    else
      _ok=0; _fail=$((_fail + 1))
      # HIGH: only latch plaintext state when _enter_plain succeeds (dnsmasq reload
      # passed). On failure, _tier stays unchanged so _fail keeps accumulating and
      # _enter_plain is retried on the next tick instead of getting stuck hard-down.
      if [ "$_tier" != plaintext ] && [ "$_fail" -ge "$_n" ]; then
        if _enter_plain; then _tier=plaintext; _entered=$(_now); fi
      fi
    fi
    # H2: AMNEZIA_DNS_WD_ONCE=1 is a backward-compatible alias for TICKS=1.
    # AMNEZIA_DNS_WD_TICKS=N runs exactly N iterations then exits (no sleep when
    # TICKS is active so tests never block on the 20s interval).
    [ -n "${AMNEZIA_DNS_WD_ONCE:-}" ] && break
    if [ -n "${AMNEZIA_DNS_WD_TICKS:-}" ]; then
      _ticks_done=$((_ticks_done + 1))
      [ "$_ticks_done" -ge "${AMNEZIA_DNS_WD_TICKS}" ] && break
    else
      sleep "${AMNEZIA_DNS_WD_INTERVAL:-20}"
    fi
  done
  return 0
}

cmd_status() {
  _en=$(uci -q get amnezia.config.dot_enabled || echo 0)
  _pr=$(uci -q get amnezia.config.dns_provider || echo quad9)
  _tier=$(uci -q get amnezia.config.dns_active_tier 2>/dev/null || echo off)
  # L5: short-circuit when disabled — no probe needed, report honestly.
  # Force active_tier=off regardless of stale UCI value (disabled status fix).
  if [ "$_en" != 1 ]; then
    printf '{"enabled":false,"provider":"%s","active_tier":"off","encrypted":false,"healthy":false}\n' \
      "$_pr"
    return 0
  fi
  _enc=false; case "$_tier" in dot|doh) _enc=true ;; esac
  # L1/L4: status path uses 1s probe timeout to keep status calls snappy.
  _hl=false; _PROBE_TIMEOUT=1 _verify_encrypted && _hl=true
  printf '{"enabled":%s,"provider":"%s","active_tier":"%s","encrypted":%s,"healthy":%s}\n' \
    "$([ "$_en" = 1 ] && echo true || echo false)" "$_pr" "$_tier" "$_enc" "$_hl"
}

case "${1:-}" in
  apply) cmd_apply ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  set-provider) cmd_set_provider "${2:?provider}" ;;
  watchdog) cmd_watchdog ;;
  status) cmd_status ;;
  *) echo "usage: amnezia-dns-ctl {apply|enable|disable|set-provider|status|watchdog}" >&2; exit 2 ;;
esac
