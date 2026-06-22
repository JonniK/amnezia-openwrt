#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/amnezia-failover.init"
@test "procd init declares the service and respawn" {
  grep -q "USE_PROCD=1" "$F"
  grep -q "procd_set_param respawn" "$F"
  grep -q "/usr/sbin/amnezia-failover" "$F"
}
