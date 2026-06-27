#!/bin/sh
# amnezia-tunnel-ctl: add/remove/list-free AmneziaWG tunnels.
# Usage: amnezia-tunnel-ctl <add|remove|list-free> [args]
# shellcheck source=lib/amnezia-common.sh
AMNEZIA_LIB=${AMNEZIA_LIB:-/usr/lib/amnezia}
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
# shellcheck source=lib/amnezia-tunnel-lib.sh
if [ -f "$AMNEZIA_LIB/amnezia-tunnel-lib.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-tunnel-lib.sh"
else
  . "$(dirname "$0")/lib/amnezia-tunnel-lib.sh"
fi

# _tunnel_exists <name> — returns 0 if UCI knows this tunnel
_tunnel_exists() {
  uci show amnezia 2>/dev/null | grep -q "^amnezia\.$1="
}

# _fwnet_count — prints number of members in firewall.vpn.network
# Uses uci get which returns space-separated values on one line (works on every
# uci version including OpenWrt 24.10 which renders lists as one quoted line in
# uci show output).
_fwnet_count() {
  # shellcheck disable=SC2046,SC2086
  set -- $(uci -q get firewall.vpn.network 2>/dev/null)
  echo "$#"
}

# _fwnet_has <name> — returns 0 if <name> is in firewall.vpn.network
_fwnet_has() {
  for _m in $(uci -q get firewall.vpn.network 2>/dev/null); do
    [ "$_m" = "$1" ] && return 0
  done
  return 1
}

# _sticky_target — prints current sticky target
_sticky_target() {
  uci get amnezia.globals.sticky_target 2>/dev/null || echo ""
}

# _metric_for_name — metric = awgN index (not count+1, avoids collisions with gaps)
_metric_for_name() {
  printf '%s' "${1#awg}"
}

case "$1" in
  list-free)
    _i=1
    while [ "$_i" -le "$MAX_TUNNELS" ]; do
      if ! _tunnel_exists "awg${_i}"; then
        echo "awg${_i}"
        exit 0
      fi
      _i=$(( _i + 1 ))
    done
    exit 3
    ;;

  add)
    _name="${2:-}"
    _body="${3:-}"
    _label=""
    # Parse optional --label
    shift 3 2>/dev/null || true
    while [ $# -gt 0 ]; do
      case "$1" in
        --label) _label="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    # H2: Validate name BEFORE any mutation.
    # Must match awg[1-9] exactly (no path traversal, no awg0, no awg10+).
    case "$_name" in
      awg[1-9]) ;;
      *) amz_log "tunnel-ctl: invalid tunnel name '${_name}' (must be awg1..awg${MAX_TUNNELS})"; exit 1 ;;
    esac
    _slot="${_name#awg}"
    if [ "$_slot" -gt "$MAX_TUNNELS" ]; then
      amz_log "tunnel-ctl: tunnel '${_name}' exceeds MAX_TUNNELS=${MAX_TUNNELS}"; exit 1
    fi
    if _tunnel_exists "$_name"; then
      amz_log "tunnel-ctl: tunnel '${_name}' already exists"; exit 1
    fi

    [ -n "$_body" ] || { amz_log "tunnel-ctl: add requires <conf-body>"; exit 1; }
    [ -z "$_label" ] && _label="$_name"

    # Write conf body to a temp file (mode 600)
    _tmp=$(mktemp /tmp/amnezia-add-XXXXXX)
    chmod 600 "$_tmp"
    printf '%s\n' "$_body" > "$_tmp"

    # Parse and validate required fields
    parse_awg_conf "$_tmp" || { rm -f "$_tmp"; exit 1; }
    _missing=""
    [ -z "$AWG_PrivateKey" ]     && _missing="${_missing}PrivateKey "
    [ -z "$AWG_PublicKey" ]      && _missing="${_missing}PublicKey "
    [ -z "$AWG_Endpoint_host" ]  && _missing="${_missing}Endpoint_host "
    [ -z "$AWG_Endpoint_port" ]  && _missing="${_missing}Endpoint_port "
    if [ -n "$_missing" ]; then
      amz_log "tunnel-ctl: conf missing required fields: ${_missing}"
      rm -f "$_tmp"
      exit 1
    fi

    # C2: Apply gen_tunnel_uci output via uci batch (not per-line eval — word-splits I-field values).
    _uci_tmp=$(mktemp /tmp/amnezia-uci-XXXXXX)
    gen_tunnel_uci "$_name" "$_tmp" > "$_uci_tmp" 2>/dev/null || {
      rm -f "$_tmp" "$_uci_tmp"
      exit 1
    }
    uci batch < "$_uci_tmp"
    rm -f "$_uci_tmp"

    # Move temp to final destination (mode 600)
    mv "$_tmp" "${CONF_DIR:-/etc/amnezia}/${_name}.conf"
    chmod 600 "${CONF_DIR:-/etc/amnezia}/${_name}.conf"

    # Create typed amnezia tunnel section
    # M2: metric = slot index (not count+1) — avoids collisions with gapped slots.
    _metric=$(_metric_for_name "$_name")
    uci set "amnezia.${_name}=tunnel"
    uci set "amnezia.${_name}.enabled=1"
    uci set "amnezia.${_name}.label=${_label}"
    uci set "amnezia.${_name}.metric=${_metric}"
    uci set "amnezia.${_name}.weight=1"
    uci set "amnezia.${_name}.track_ip=1.1.1.1"

    # C1: Append-if-absent to firewall.vpn.network (NEVER blanket-delete the list).
    if ! _fwnet_has "$_name"; then
      uci add_list "firewall.vpn.network=${_name}"
    fi

    # Commit all changes
    uci commit network
    uci commit firewall
    uci commit amnezia

    # Bring up the interface
    ifup "$_name"

    # Reload firewall in background (SSH-drop-safe)
    ( sleep 1 && fw4 reload ) &

    # Restart the failover monitor so it picks up the new tunnel
    ${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover} restart
    ;;

  remove)
    _name="${2:-}"
    [ -n "$_name" ] || { amz_log "tunnel-ctl: remove requires <name>"; exit 1; }

    # Guard: refuse if this is the current sticky target
    _st=$(_sticky_target)
    if [ "$_name" = "$_st" ]; then
      amz_log "tunnel-ctl: '$_name' is the sticky target; reassign sticky before removing"
      exit 2
    fi

    # Guard: refuse if removal would leave zero firewall.vpn.network members
    _fwcnt=$(_fwnet_count)
    if [ "$_fwcnt" -le 1 ]; then
      amz_log "tunnel-ctl: removing '$_name' would leave no firewall.vpn.network members"
      exit 2
    fi

    # Stop the monitor BEFORE teardown
    ${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover} stop

    # Bring down the interface
    ifdown "$_name"

    # Remove network interface section
    uci -q delete "network.${_name}" 2>/dev/null || true
    # H1: Remove anonymous peer section using installer idiom (not named section).
    while uci -q delete "network.@amneziawg_${_name}[0]"; do :; done

    # Remove from firewall vpn zone member list (idiomatic per-value delete).
    uci -q del_list "firewall.vpn.network=${_name}" 2>/dev/null || true

    # Remove amnezia tunnel section
    uci -q delete "amnezia.${_name}" 2>/dev/null || true

    # Remove conf file
    rm -f "${CONF_DIR:-/etc/amnezia}/${_name}.conf"

    # Clear exit-IP cache and debounce state so a re-added slot starts clean.
    rm -f "$ST_DIR/exitip.${_name}.ip" "$ST_DIR/exitip.${_name}.ts" "$ST_DIR/$_name"

    # Commit all changes
    uci commit network
    uci commit firewall
    uci commit amnezia

    # Reload firewall in background (SSH-drop-safe)
    ( sleep 1 && fw4 reload ) &

    # Restart the monitor with the reduced member set
    ${AMNEZIA_FAILOVER_INIT:-/etc/init.d/amnezia-failover} start
    ;;

  *)
    echo "Usage: $0 {add|remove|list-free} [args]" >&2
    exit 1
    ;;
esac
