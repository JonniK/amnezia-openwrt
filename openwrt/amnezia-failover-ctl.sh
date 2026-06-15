#!/bin/sh
# AmneziaWG failover control helper.
# Usage: amnezia-failover-ctl <command> [args]
# Commands: set-mode <failover|balance>, set-sticky <awgN>, set-weight <awgN> <w>, toggle <awgN>
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
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
  *)
    echo "Usage: $0 {set-mode|set-sticky|set-weight|toggle} [args]" >&2
    exit 1
    ;;
esac
