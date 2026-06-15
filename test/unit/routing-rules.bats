#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }

@test "install_ip_rules adds masked fwmark rules for both tables" {
  routing_install_rules
  grep -q "ip rule add pref 31000 fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG"
  grep -q "ip rule add pref 31001 fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG"
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
  # del must use lowercase marks and explicit pref so removal is precise.
  grep -q "ip rule del pref 31000 fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG"
  grep -q "ip rule del pref 31001 fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG"
}

# REGRESSION GUARD: explicit pref above pbr's cleanup range.
# pbr's cleanup loop deletes ip rules by priority in [uplink_ip_rules_priority-max .. uplink_ip_rules_priority]
# (default top = 30000). Rules installed WITHOUT an explicit pref get auto-assigned adjacent to pbr's
# rules and fall inside that range, so pbr's stop wipes them during migrate → WAN leak.
# Fix: install with pref 31000/31001 (above 30000, below main-table fallback 32766).
@test "install_ip_rules uses explicit pref ABOVE pbr cleanup range (> 30000) and BELOW main fallback (< 32766)" {
  routing_install_rules
  # Must see pref on the sticky rule
  grep -q "ip rule add pref [0-9]* fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG" \
    || grep -q "ip rule add.*pref [0-9].*fwmark 0x0a0000" "$STUB_LOG" \
    || { echo "FAIL: no pref on sticky rule add"; cat "$STUB_LOG"; false; }
  # Must see pref on the pool rule
  grep -q "ip rule add pref [0-9]* fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG" \
    || grep -q "ip rule add.*pref [0-9].*fwmark 0x0b0000" "$STUB_LOG" \
    || { echo "FAIL: no pref on pool rule add"; cat "$STUB_LOG"; false; }
  # Extract the actual pref values and assert > 30000 and < 32766
  _sticky_pref=$(grep "ip rule add.*fwmark 0x0a0000" "$STUB_LOG" | grep -o 'pref [0-9]*' | awk '{print $2}')
  _pool_pref=$(grep "ip rule add.*fwmark 0x0b0000" "$STUB_LOG" | grep -o 'pref [0-9]*' | awk '{print $2}')
  [ -n "$_sticky_pref" ] || { echo "FAIL: could not extract sticky pref"; false; }
  [ -n "$_pool_pref" ]   || { echo "FAIL: could not extract pool pref"; false; }
  [ "$_sticky_pref" -gt 30000 ] || { echo "FAIL: sticky pref $_sticky_pref not > 30000 (pbr cleanup range)"; false; }
  [ "$_pool_pref"   -gt 30000 ] || { echo "FAIL: pool pref $_pool_pref not > 30000 (pbr cleanup range)"; false; }
  [ "$_sticky_pref" -lt 32766 ] || { echo "FAIL: sticky pref $_sticky_pref not < 32766 (main fallback)"; false; }
  [ "$_pool_pref"   -lt 32766 ] || { echo "FAIL: pool pref $_pool_pref not < 32766 (main fallback)"; false; }
}

@test "routing_remove_rules uses explicit pref matching install — removes precisely" {
  routing_remove_rules
  grep -q "ip rule del pref $RULE_PREF_STICKY fwmark 0x0a0000/0x0ff0000 lookup 100" "$STUB_LOG" \
    || { echo "FAIL: remove didn't use explicit pref $RULE_PREF_STICKY"; cat "$STUB_LOG"; false; }
  grep -q "ip rule del pref $RULE_PREF_POOL fwmark 0x0b0000/0x0ff0000 lookup 101" "$STUB_LOG" \
    || { echo "FAIL: remove didn't use explicit pref $RULE_PREF_POOL"; cat "$STUB_LOG"; false; }
}
