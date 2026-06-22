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
  "$AMNEZIA_NSLOOKUP" -timeout=3 openwrt.org "$1" >/dev/null 2>&1
}
_verify_encrypted() { _probe_listener "127.0.0.1#$DOT_PORT" || _probe_listener "127.0.0.1#$DOH_PORT"; }

cmd_disable() {
  dnsmasq_lock; dns_dnsmasq_restore; dns_dnsmasq_reload || true; dnsmasq_unlock
  _prov=$(uci -q get amnezia.config.dns_provider || echo quad9)
  dns_profile "$_prov" 2>/dev/null && dns_iprule_clear "$DNS_DOT_IP"
  "$AMNEZIA_STUBBY_INIT" stop 2>/dev/null || true
  # shellcheck disable=SC2153
  "$AMNEZIA_DOH_INIT" stop 2>/dev/null || true
  "$AMNEZIA_DNS_INIT" stop 2>/dev/null || true
  uci set amnezia.config.dot_enabled=0
  uci -q delete amnezia.config.dns_active_tier 2>/dev/null || true
  uci commit amnezia
}

cmd_enable() {
  _has_bin || { echo "install stubby + https-dns-proxy first" >&2; return 1; }
  uci set amnezia.config.dot_enabled=1; uci commit amnezia
  cmd_apply || { cmd_disable; return 1; }
  if _verify_encrypted; then return 0; fi    # verify runs OUTSIDE the lock (apply released it)
  amz_log "dns: encrypted verify failed -> auto-revert"; cmd_disable; return 1
}

cmd_set_provider() {
  _new=$1; dns_profile "$_new" || { echo "bad provider $_new" >&2; return 2; }
  _prev=$(uci -q get amnezia.config.dns_provider || echo quad9)
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
  dnsmasq_lock; dns_dnsmasq_add_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
  _set_tier plaintext
}
_exit_plain() {
  dnsmasq_lock; dns_dnsmasq_del_plain; dns_dnsmasq_reload || true; dnsmasq_unlock
}

cmd_watchdog() {
  _n=${AMNEZIA_DNS_WD_N:-3}; _m=${AMNEZIA_DNS_WD_M:-2}; _dwell=${AMNEZIA_DNS_WD_DWELL:-120}
  _fail=0; _ok=0; _entered=0
  _tier=$(uci -q get amnezia.config.dns_active_tier 2>/dev/null || echo "")
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
      if [ "$_tier" != plaintext ] && [ "$_fail" -ge "$_n" ]; then _enter_plain; _tier=plaintext; _entered=$(_now); fi
    fi
    [ -n "${AMNEZIA_DNS_WD_ONCE:-}" ] && break
    sleep "${AMNEZIA_DNS_WD_INTERVAL:-20}"
  done
  return 0
}

cmd_status() {
  _en=$(uci -q get amnezia.config.dot_enabled || echo 0)
  _pr=$(uci -q get amnezia.config.dns_provider || echo quad9)
  _tier=$(uci -q get amnezia.config.dns_active_tier || echo dot)
  _enc=false; case "$_tier" in dot|doh) _enc=true ;; esac
  _hl=false; _verify_encrypted && _hl=true
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
