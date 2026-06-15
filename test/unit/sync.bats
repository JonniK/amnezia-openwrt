#!/usr/bin/env bats
load '../lib/harness.bash'

@test "sync covers monitor/lib/nft/init and drops pbr.d template references" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-failover" "$F"
  grep -q "lib/amnezia-common.sh" "$F"
  grep -q "nftables.d/30-amnezia-classify.nft" "$F"
  grep -q "configure-dnsmasq-amnezia.sh" "$F"
  # These pbr.d references must be gone -- strings that actually appear in the old script:
  ! grep -q "pbr.d/ru-direct.sh" "$F"
  ! grep -q "/etc/pbr.d" "$F"
  ! grep -q "99-lan-vpn" "$F"
}
@test "sync includes all new runtime paths" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-failover" "$F"
  grep -q "amnezia-failover.init" "$F"
  grep -q "amnezia-routing.sh" "$F"
  grep -q "iproute2-amnezia-rt_tables.conf" "$F"
}
