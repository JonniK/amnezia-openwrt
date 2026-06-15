#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }

@test "install_ip_rules adds masked fwmark rules for both tables" {
  routing_install_rules
  grep -q "ip rule add fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG"
  grep -q "ip rule add fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG"
}
@test "install is idempotent (checks existence before add)" {
  IP_FAKE_RULE_EXISTS=1 routing_install_rules
  ! grep -q "ip rule add fwmark 0x0b0000" "$STUB_LOG"
}
@test "blackhole default installed when no member" {
  routing_set_pool_default ""   # empty = no healthy member
  grep -q "ip route replace blackhole default table 101" "$STUB_LOG"
}
@test "pool default points at a single dev in failover mode" {
  routing_set_pool_default "awg2"
  grep -q "ip route replace default dev awg2 table 101" "$STUB_LOG"
}
@test "balance mode builds a resilient weighted nexthop group when supported" {
  IP_NEXTHOP_OK=1 routing_set_pool_balance "awg1:2 awg2:1"
  grep -q "ip nexthop replace id 101 group" "$STUB_LOG"
  grep -q "ip route replace default nhid 101 table 101" "$STUB_LOG"
}
@test "balance mode falls back to single dev when nexthop unsupported" {
  IP_NEXTHOP_OK=0 routing_set_pool_balance "awg1:2 awg2:1"
  grep -q "ip route replace default dev awg1 table 101" "$STUB_LOG"
}
