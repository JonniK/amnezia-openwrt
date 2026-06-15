#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/luci-app-amnezia/view/main.js"
@test "main.js parses and references the failover state file + per-tunnel table" {
  node --check "$F"
  grep -q "amnezia-failover.json" "$F"
  grep -q "renderTunnelTable" "$F"
  grep -q "parseFailoverState" "$F"
}
@test "main.js still reads seed-must-tunnel.list at the existing runtime path (~line 962)" {
  grep -q "seed-must-tunnel.list" "$F"
}
@test "panel calls amnezia-failover-ctl matching the helper installed name" {
  # The ctl helper is installed as amnezia-failover-ctl (see F3/ACL).
  grep -q "amnezia-failover-ctl" "$F"
}
