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
@test "pbr panel is gone: no pbr-status or pbr-reload exec calls" {
  # Issue #9: pbr binaries no longer exist; the panel must be fully removed.
  ! grep -q "pbr-status" "$F"
  ! grep -q "pbr-reload" "$F"
  ! grep -q "pbr-reload-btn" "$F"
  ! grep -q "handlePbrReload" "$F"
}
@test "failover tunnel panel is present: renderTunnelTable and failover-tunnel-table id" {
  grep -q "renderTunnelTable" "$F"
  grep -q "failover-tunnel-table" "$F"
  grep -q "Failover tunnels" "$F"
}
@test "handshake_age is rendered directly as age-in-seconds (no Date.now subtract)" {
  # Issue MED: producer emits age-in-seconds; consumer must not double-convert via Date.now().
  # Ensure the stale pattern is gone and the direct path is present.
  ! grep -q "Date.now().*handshake_age\|handshake_age.*Date.now()" "$F"
  grep -q "age < 0.*never\|age < 60.*ago" "$F"
}
