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
