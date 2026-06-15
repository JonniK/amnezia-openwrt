# Routing-table / ip-rule management. Sourced; depends on amnezia-common.sh.
# Normalise a hex constant to lowercase (POSIX awk, BusyBox-safe).
_lc() { printf '%s' "$1" | awk '{print tolower($0)}'; }
# Build a leading-zero-tolerant ERE pattern for a hex value like 0x0a0000.
# The kernel prints fwmark with %#x (stripping leading zeros), so 0x0a0000
# becomes 0xa0000.  We produce "0x0*a0000" which matches both forms.
_hex_pat() {
  printf '%s' "$1" | awk '{
    s = tolower($0)
    prefix = substr(s, 1, 2)   # "0x"
    rest   = substr(s, 3)
    gsub(/^0+/, "", rest)
    print prefix "0*" rest
  }'
}
_rule_exists() {  # $1 mark/mask string (e.g. 0x0a0000/0x0ff0000)
  [ "${IP_FAKE_RULE_EXISTS:-0}" = 1 ] && return 0
  # Split mark/mask, build a leading-zero-tolerant pattern for each field.
  # Matches kernel form (0xa0000/0xff0000) AND our form (0x0a0000/0x0ff0000).
  _mark_s="${1%%/*}"; _mask_s="${1##*/}"
  _mp=$(_hex_pat "$_mark_s"); _mskp=$(_hex_pat "$_mask_s")
  ip rule show 2>/dev/null | grep -qE "fwmark ${_mp}/${_mskp}"
}
routing_install_rules() {
  _sm=$(_lc "$STICKY_MARK"); _pm=$(_lc "$POOL_MARK"); _mm=$(_lc "$MARK_MASK")
  _rule_exists "$_sm/$_mm" || ip rule add fwmark "$_sm/$_mm" lookup "$TBL_STICKY"
  _rule_exists "$_pm/$_mm" || ip rule add fwmark "$_pm/$_mm" lookup "$TBL_POOL"
}
routing_remove_rules() {
  _sm=$(_lc "$STICKY_MARK"); _pm=$(_lc "$POOL_MARK"); _mm=$(_lc "$MARK_MASK")
  ip rule del fwmark "$_sm/$_mm" lookup "$TBL_STICKY" 2>/dev/null
  ip rule del fwmark "$_pm/$_mm" lookup "$TBL_POOL" 2>/dev/null
}
# $1 = dev (empty -> blackhole). Fail-closed.
routing_set_pool_default() {
  if [ -z "$1" ]; then ip route replace blackhole default table "$TBL_POOL"
  else ip route replace default dev "$1" table "$TBL_POOL"; fi
}
routing_set_sticky_default() {
  if [ -z "$1" ]; then ip route replace blackhole default table "$TBL_STICKY"
  else ip route replace default dev "$1" table "$TBL_STICKY"; fi
}
# Emit the firewall UCI plan for the given tunnel list (space-separated awgN).
# The amnezia_block_quic rule is NEVER touched — it is preserved as-is.
# This is the shared plan source used by both dryrun (echo) and apply (uci set).
routing_firewall_dryrun() {
  echo "set firewall.vpn=zone"
  echo "set firewall.vpn.name=vpn"
  echo "set firewall.vpn.network=$1"
  echo "set firewall.vpn.input=REJECT"
  echo "set firewall.vpn.output=ACCEPT"
  echo "set firewall.vpn.forward=REJECT"
  echo "set firewall.vpn.masq=1"
  echo "set firewall.vpn.mtu_fix=1"
  echo "set firewall.vpn_fwd=forwarding"
  echo "set firewall.vpn_fwd.src=lan"
  echo "set firewall.vpn_fwd.dest=vpn"
  # IPv6 fail-closed (forward-drop): drop forwarded lan->wan v6 only.
  echo "set firewall.amnezia_v6_drop=rule"
  echo "set firewall.amnezia_v6_drop.name=amnezia-drop-v6-forward"
  echo "set firewall.amnezia_v6_drop.src=lan"
  echo "set firewall.amnezia_v6_drop.dest=wan"
  echo "set firewall.amnezia_v6_drop.family=ipv6"
  echo "set firewall.amnezia_v6_drop.proto=all"
  echo "set firewall.amnezia_v6_drop.target=DROP"
  # amnezia_block_quic is intentionally NOT touched here.
  # The migration function asserts via negative-space test that no delete or re-set occurs.
}
# Apply the firewall UCI plan via real uci calls. Mirrors routing_firewall_dryrun exactly.
# firewall.vpn.network is a UCI list (uci add_list per member, not a scalar).
# amnezia_block_quic is NEVER touched.
routing_firewall_apply() {
  _tlist=$1
  uci set firewall.vpn=zone
  uci set firewall.vpn.name=vpn
  uci -q delete firewall.vpn.network 2>/dev/null || true
  for _t in $_tlist; do
    uci add_list firewall.vpn.network="$_t"
  done
  uci set firewall.vpn.input=REJECT
  uci set firewall.vpn.output=ACCEPT
  uci set firewall.vpn.forward=REJECT
  uci set firewall.vpn.masq=1
  uci set firewall.vpn.mtu_fix=1
  uci set firewall.vpn_fwd=forwarding
  uci set firewall.vpn_fwd.src=lan
  uci set firewall.vpn_fwd.dest=vpn
  # IPv6 fail-closed (forward-drop): drop forwarded lan->wan v6 only.
  uci set firewall.amnezia_v6_drop=rule
  uci set firewall.amnezia_v6_drop.name=amnezia-drop-v6-forward
  uci set firewall.amnezia_v6_drop.src=lan
  uci set firewall.amnezia_v6_drop.dest=wan
  uci set firewall.amnezia_v6_drop.family=ipv6
  uci set firewall.amnezia_v6_drop.proto=all
  uci set firewall.amnezia_v6_drop.target=DROP
  uci commit firewall
  # Reload firewall to activate new rules.
  /etc/init.d/firewall reload 2>/dev/null || fw4 reload 2>/dev/null || true
}
routing_nexthop_supported() {
  if [ -n "${IP_NEXTHOP_OK:-}" ]; then
    [ "$IP_NEXTHOP_OK" = 1 ] && return 0 || return 1
  fi
  ip nexthop help >/dev/null 2>&1 && [ -e /proc/sys/net/ipv4/fib_multipath_hash_policy ]
}
# $1 = "devA:weightA devB:weightB ..." (healthy members, highest priority first)
routing_set_pool_balance() {
  if ! routing_nexthop_supported; then
    set -- $1; _first=${1%%:*}; routing_set_pool_default "$_first"; return
  fi
  sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null 2>&1 || true
  _grp=""; _id=10
  for _m in $1; do
    _dev=${_m%%:*}
    case "$_m" in *:*) _w=${_m##*:} ;; *) _w=1 ;; esac
    ip nexthop replace id "$_id" dev "$_dev"
    _grp="${_grp}${_id},${_w}/"; _id=$((_id+1))
  done
  ip nexthop replace id "$TBL_POOL" group "${_grp%/}" type resilient buckets 128 idle_timer 120
  ip route replace default nhid "$TBL_POOL" table "$TBL_POOL"
}
# Disable LAN RA/DHCPv6/NDP so LAN clients stay IPv4-only (v6 fail-closed part b).
routing_disable_lan_v6() {
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ndp='disabled'
  uci commit dhcp
}
