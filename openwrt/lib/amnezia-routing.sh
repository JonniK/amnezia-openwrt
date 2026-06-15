# Routing-table / ip-rule management. Sourced; depends on amnezia-common.sh.
# Normalise a hex constant to lowercase (POSIX awk, BusyBox-safe).
_lc() { printf '%s' "$1" | awk '{print tolower($0)}'; }
_rule_exists() {  # $1 mark (lowercase fwmark/mask string)
  [ "${IP_FAKE_RULE_EXISTS:-0}" = 1 ] && return 0
  ip rule show 2>/dev/null | grep -q "fwmark $1"
}
routing_install_rules() {
  _sm=$(_lc "$STICKY_MARK"); _pm=$(_lc "$POOL_MARK"); _mm=$(_lc "$MARK_MASK")
  _rule_exists "$_sm/$_mm" || ip rule add fwmark "$_sm/$_mm" lookup "$TBL_STICKY"
  _rule_exists "$_pm/$_mm" || ip rule add fwmark "$_pm/$_mm" lookup "$TBL_POOL"
}
routing_remove_rules() {
  ip rule del fwmark "$STICKY_MARK/$MARK_MASK" lookup "$TBL_STICKY" 2>/dev/null
  ip rule del fwmark "$POOL_MARK/$MARK_MASK" lookup "$TBL_POOL" 2>/dev/null
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
routing_nexthop_supported() {
  [ -n "$IP_NEXTHOP_OK" ] && return "$([ "$IP_NEXTHOP_OK" = 1 ] && echo 0 || echo 1)"
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
    _dev=${_m%%:*}; _w=${_m##*:}
    ip nexthop replace id "$_id" dev "$_dev"
    _grp="${_grp}${_id},${_w}/"; _id=$((_id+1))
  done
  ip nexthop replace id "$TBL_POOL" group "${_grp%/}" type resilient buckets 128 idle_timer 120
  ip route replace default nhid "$TBL_POOL" table "$TBL_POOL"
}
