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
