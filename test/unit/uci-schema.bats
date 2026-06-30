#!/usr/bin/env bats
load '../lib/harness.bash'
@test "amnezia uci scaffold declares globals + a tunnel template" {
  f="$HARNESS_DIR/../openwrt/config/amnezia"
  grep -q "config globals 'globals'" "$f"
  grep -q "option mode 'failover'" "$f"
  grep -q "option sticky_target 'awg1'" "$f"
  grep -q "config tunnel 'awg1'" "$f"
  grep -q "option metric '1'" "$f"
}
@test "existing config amnezia 'config' section and routing_mode are preserved" {
  f="$HARNESS_DIR/../openwrt/config/amnezia"
  grep -q "config amnezia 'config'" "$f"
  grep -q "option routing_mode" "$f"
}
@test "config does NOT ship autolearn_* options (feature removed)" {
  CFG="$HARNESS_DIR/../openwrt/config/amnezia"
  ! grep -q "autolearn" "$CFG"
}
