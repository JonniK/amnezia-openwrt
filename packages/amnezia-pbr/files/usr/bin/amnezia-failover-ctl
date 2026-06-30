#!/bin/sh
# AmneziaWG failover control helper.
# Usage: amnezia-failover-ctl <command> [args]
# Commands: set-mode <failover|balance>, set-sticky <awgN>, set-weight <awgN> <w>, toggle <awgN>,
#           set-routing-mode <tunnel-default|direct-default>, set-source <name> <0|1>,
#           make-default <awgN>, force-pin <awgN>, force-unpin,
#           restart <awgN>, master on|off
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
# shellcheck source=lib/amnezia-routing.sh
if [ -f "$AMNEZIA_LIB/amnezia-routing.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-routing.sh"
else
  . "$(dirname "$0")/lib/amnezia-routing.sh"
fi
# shellcheck source=lib/amnezia-dns-lib.sh
# Optional: dns-lib may be absent on a minimal install (DNS feature not deployed).
# Source it when present so dns_iprule_flush is available for master-off cleanup.
_dns_lib="${AMNEZIA_LIB}/amnezia-dns-lib.sh"
[ -r "$_dns_lib" ] || _dns_lib="$(dirname "$0")/lib/amnezia-dns-lib.sh"
# shellcheck disable=SC1090
[ -r "$_dns_lib" ] && . "$_dns_lib"

_restart_monitor() {
  ( sleep 1 && /etc/init.d/amnezia-failover restart ) &
}

# True when uci reports a section of type 'tunnel' for the given name.
_ctl_tun_exists()  { [ -n "$1" ] && [ "$(uci -q get "amnezia.$1" 2>/dev/null)" = tunnel ]; }
# True when the tunnel's enabled option is exactly '1'.
_ctl_tun_enabled() { [ "$(uci -q get "amnezia.$1.enabled" 2>/dev/null)" = 1 ]; }

case "$1" in
  set-mode)
    case "$2" in
      failover|balance) ;;
      *) amz_log "ctl: invalid mode '$2'"; exit 1 ;;
    esac
    uci set amnezia.globals.mode="$2"
    uci commit amnezia
    _restart_monitor
    ;;
  set-sticky)
    [ -n "$2" ] || { amz_log "ctl: set-sticky requires a tunnel name"; exit 1; }
    uci set amnezia.globals.sticky_target="$2"
    uci commit amnezia
    _restart_monitor
    ;;
  set-weight)
    [ -n "$2" ] && [ -n "$3" ] || { amz_log "ctl: set-weight requires tunnel and weight"; exit 1; }
    case "$2" in awg[0-9]*) ;; *) amz_log "ctl: invalid tunnel name '$2'"; exit 1 ;; esac
    case "$3" in *[!0-9]*|'') amz_log "ctl: weight must be a non-negative integer"; exit 1 ;; esac
    uci set "amnezia.$2.weight=$3"
    uci commit amnezia
    _restart_monitor
    ;;
  toggle)
    [ -n "$2" ] || { amz_log "ctl: toggle requires a tunnel name"; exit 1; }
    case "$2" in awg[0-9]*) ;; *) amz_log "ctl: invalid tunnel name '$2'"; exit 1 ;; esac
    _cur=$(uci -q get "amnezia.$2.enabled" 2>/dev/null || echo 0)
    if [ "$_cur" = 1 ]; then
      uci set "amnezia.$2.enabled=0"
    else
      uci set "amnezia.$2.enabled=1"
    fi
    uci commit amnezia
    _restart_monitor
    ;;
  set-routing-mode)
    case "$2" in
      tunnel-default|direct-default) ;;
      *) amz_log "ctl: invalid routing mode '$2'"; exit 1 ;;
    esac
    uci set amnezia.config.routing_mode="$2"
    uci commit amnezia
    LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo br-lan)
    # M1: Capture classifier to a temp; check rc; bail BEFORE writing output or reloading.
    _cls_tmp=$(mktemp /tmp/amnezia-cls-XXXXXX)
    if ! routing_emit_classifier "$2" "$LAN_DEV" > "$_cls_tmp" 2>/dev/null; then
      rm -f "$_cls_tmp"
      amz_log "ctl: classifier emit failed for mode '$2'; aborting reload"
      exit 1
    fi
    mv "$_cls_tmp" "${AMNEZIA_CLASSIFIER_OUT:-/etc/nftables.d/30-amnezia-classify.nft}"
    ${AMNEZIA_FORCE_LOAD:-amnezia-force-load}
    # M2: Both conntrack flushes are unconditional after fw4 reload —
    # POOL and STICKY are flushed regardless of reload exit status.
    ( sleep 1 && fw4 reload 2>/dev/null; \
      conntrack -D -m "$POOL_MARK/$MARK_MASK" 2>/dev/null; \
      conntrack -D -m "$STICKY_MARK/$MARK_MASK" 2>/dev/null ) &
    ;;
  set-source)
    # Accept any force_source section (built-in or user-added via amnezia-app-ctl).
    # Check the UCI section type; also accept the five well-known built-in source names
    # before they exist as UCI sections (installer may pre-seed them from config template).
    _src_type=$(uci -q get "amnezia.$2" 2>/dev/null || echo "")
    _src_ok=0
    [ "$_src_type" = "force_source" ] && _src_ok=1
    if [ "$_src_ok" = 0 ]; then
      case "$2" in
        itdoginfo_inside|itdoginfo_services|refilter_domains|refilter_ip|antifilter)
          _src_ok=1 ;;
      esac
    fi
    [ "$_src_ok" = 1 ] || { amz_log "ctl: unknown source '$2' (not a force_source section)"; exit 1; }
    case "$3" in
      0|1) ;;
      *) amz_log "ctl: enabled must be 0 or 1"; exit 1 ;;
    esac
    uci set "amnezia.$2.enabled=$3"
    uci commit amnezia
    ;;
  make-default)
    _ctl_tun_exists "$2"  || { amz_log "ctl: make-default unknown tunnel '$2'"; exit 1; }
    _ctl_tun_enabled "$2" || { amz_log "ctl: make-default tunnel '$2' is disabled"; exit 1; }
    uci set "amnezia.$2.metric=1"
    _next=2
    for _i in 1 2 3 4 5; do _t="awg$_i"
      [ "$_t" = "$2" ] && continue
      [ "$(uci -q get "amnezia.$_t" 2>/dev/null)" = tunnel ] || continue
      [ "$(uci -q get "amnezia.$_t.enabled" 2>/dev/null)" = 1 ] || continue
      uci set "amnezia.$_t.metric=$_next"; _next=$((_next+1))
    done
    uci commit amnezia
    _restart_monitor
    ;;
  force-pin)
    _ctl_tun_exists "$2" || { amz_log "ctl: force-pin unknown tunnel '$2'"; exit 1; }
    uci set "amnezia.globals.force_pool=$2"
    uci commit amnezia
    touch "$ST_DIR/immediate"
    ;;
  force-unpin)
    uci -q delete amnezia.globals.force_pool
    uci commit amnezia
    touch "$ST_DIR/immediate"
    ;;
  restart)
    _ctl_tun_exists "$2" || { amz_log "ctl: restart unknown tunnel '$2'"; exit 1; }
    ifdown "$2"; sleep 1; ifup "$2"
    ;;
  master)
    # Real bounded WAN+DNS probe. Overridable for tests via AMNEZIA_VERIFY_CMD=true.
    _amz_verify_conn() {
      ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1
    }
    _verify="${AMNEZIA_VERIFY_CMD:-_amz_verify_conn}"
    case "$2" in
      off)
        _me=$(uci -q get amnezia.config.master_enabled 2>/dev/null || echo 1)
        if [ "$_me" != 0 ]; then
          _ds=$(uci -q get amnezia.config.dot_enabled 2>/dev/null || echo 0)
          uci set amnezia.config.dot_master_saved="$_ds"
        fi
        uci set amnezia.config.master_enabled=0
        uci commit amnezia
        ${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover} stop 2>/dev/null || true
        # Remove stale state JSON so the LuCI table shows "No tunnel state available"
        # instead of dimmed UP tunnels under the "routing disabled" strip.
        rm -f "$STATE_FILE"
        if [ "$_ds" = 1 ]; then
          ${AMNEZIA_DNS_CTL:-amnezia-dns-ctl} disable 2>/dev/null || true
        fi
        # Explicitly flush pref-30900 (DoT ip rule) even if amnezia-dns-ctl disable
        # failed — prevents the rule from stranding against the flushed table 100.
        # dns_iprule_flush is a documented safe-when-absent no-op (loops until no more).
        if command -v dns_iprule_flush >/dev/null 2>&1; then
          dns_iprule_flush 2>/dev/null || true
        fi
        ip route flush table 100 2>/dev/null || true
        ip route flush table 101 2>/dev/null || true
        if $_verify >/dev/null 2>&1; then
          amz_log "ctl: master OFF — policy routing bypassed (WAN direct)"
        else
          amz_log "ctl: master OFF applied but WAN/DNS verify FAILED — check connectivity"
        fi
        ;;
      on)
        uci set amnezia.config.master_enabled=1
        uci commit amnezia
        ${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover} start 2>/dev/null || true
        _ds=$(uci -q get amnezia.config.dot_master_saved 2>/dev/null || echo 0)
        if [ "$_ds" = 1 ]; then
          ${AMNEZIA_DNS_CTL:-amnezia-dns-ctl} enable 2>/dev/null || true
        fi
        uci -q delete amnezia.config.dot_master_saved
        uci commit amnezia
        # Cold-start verify: retry up to 3 times with 2s sleep to allow the daemon's
        # first poll + AWG handshake (~15s total) to complete before logging failure.
        # Failure is advisory only — never fails the verb.
        _vi=0; _vok=0
        while [ "$_vi" -lt 3 ]; do
          if $_verify >/dev/null 2>&1; then _vok=1; break; fi
          _vi=$((_vi+1)); [ "$_vi" -lt 3 ] && sleep 2
        done
        if [ "$_vok" = 1 ]; then
          amz_log "ctl: master ON — stack restored"
        else
          amz_log "ctl: master ON applied but verify FAILED — handshake may take ~15s, check logs if persists"
        fi
        ;;
      *) amz_log "ctl: master requires on|off"; exit 1 ;;
    esac
    ;;
  *)
    echo "Usage: $0 {set-mode|set-sticky|set-weight|toggle|set-routing-mode|set-source|make-default|force-pin|force-unpin|restart|master} [args]" >&2
    exit 1
    ;;
esac
