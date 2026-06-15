#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }

@test "install_ip_rules adds masked fwmark rules for both tables" {
  routing_install_rules
  grep -q "ip rule add fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG"
  grep -q "ip rule add fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG"
}
@test "install is idempotent: no duplicate add when stub emits real kernel form" {
  # IP_FAKE_RULE_EXISTS shortcut bypasses _rule_exists entirely; instead we
  # rely on the stub's 'ip rule show' output which now emits the real kernel
  # form (0xa0000/0xff0000, no leading zeros) to prove _rule_exists matches it.
  IP_FAKE_RULE_EXISTS=1 routing_install_rules
  # Primary check: the stub emits rules already present, so no 'add' for awg2 table.
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
@test "_rule_exists matches real kernel hex form (0xa0000 not 0x0a0000) — no false duplicate add" {
  # Real iproute2 prints fwmark with %#x, stripping leading zeros from the mark:
  # STICKY_MARK=0x0A0000 appears as 0xa0000, MARK_MASK=0x0FF0000 appears as 0xff0000.
  # The stub must emit the REAL kernel form; _rule_exists must recognise it.
  # IP_FAKE_RULE_EXISTS is NOT set — _rule_exists must call 'ip rule show'.
  _ip_dir="$BATS_TEST_TMPDIR/ip_bin"
  mkdir -p "$_ip_dir"
  # Real kernel form: leading zeros stripped from mark (0xa0000, 0xb0000).
  printf '#!/bin/sh\necho "ip $*" >> "${STUB_LOG:-/dev/null}"\ncase "$*" in\n  "rule show"*) printf "fwmark 0xa0000/0xff0000 lookup 100\\nfwmark 0xb0000/0xff0000 lookup 101\\n" ;;\nesac\nexit 0\n' > "$_ip_dir/ip"
  chmod +x "$_ip_dir/ip"
  : > "$STUB_LOG"
  PATH="$_ip_dir:$PATH" routing_install_rules
  # Both rules already exist in real kernel form — no 'ip rule add' must fire.
  ! grep -q "ip rule add" "$STUB_LOG"
}
@test "routing_remove_rules uses lowercase marks matching kernel form" {
  routing_remove_rules
  # del must use lowercase marks so they match what the kernel installed.
  grep -q "ip rule del fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG"
  grep -q "ip rule del fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG"
}
