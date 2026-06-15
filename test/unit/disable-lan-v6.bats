#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }

@test "routing_disable_lan_v6 sets ra, dhcpv6, ndp to disabled and commits dhcp" {
  routing_disable_lan_v6
  grep -q "uci set dhcp.lan.ra=disabled" "$STUB_LOG"
  grep -q "uci set dhcp.lan.dhcpv6=disabled" "$STUB_LOG"
  grep -q "uci set dhcp.lan.ndp=disabled" "$STUB_LOG"
  grep -q "uci commit dhcp" "$STUB_LOG"
}
