#!/bin/sh
# AmneziaWG failover control helper.
# Usage: amnezia-failover-ctl <command> [args]
# Commands: set-mode <failover|balance>, set-sticky <awgN>, set-weight <awgN> <w>, toggle <awgN>,
#           set-routing-mode <tunnel-default|direct-default>, set-source <name> <0|1>
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

_restart_monitor() {
  ( sleep 1 && /etc/init.d/amnezia-failover restart ) &
}

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
    # H3: conntrack flush AFTER reload, inside the backgrounded subshell.
    ( sleep 1 && fw4 reload \
      && conntrack -D -m "$POOL_MARK/$MARK_MASK" 2>/dev/null; \
      conntrack -D -m "$STICKY_MARK/$MARK_MASK" 2>/dev/null ) &
    ;;
  set-source)
    case "$2" in
      itdoginfo_inside|itdoginfo_services|refilter_domains|refilter_ip|antifilter) ;;
      *) amz_log "ctl: unknown source '$2'"; exit 1 ;;
    esac
    case "$3" in
      0|1) ;;
      *) amz_log "ctl: enabled must be 0 or 1"; exit 1 ;;
    esac
    uci set "amnezia.$2.enabled=$3"
    uci commit amnezia
    ;;
  *)
    echo "Usage: $0 {set-mode|set-sticky|set-weight|toggle|set-routing-mode|set-source} [args]" >&2
    exit 1
    ;;
esac
