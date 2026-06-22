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
@test "config ships autolearn_* defaults with learning OFF" {
  CFG="$HARNESS_DIR/../openwrt/config/amnezia"
  grep -q "option autolearn_enabled '0'" "$CFG"
  grep -q "option autolearn_interval_min '30'" "$CFG"
  grep -q "option autolearn_max_probes '20'" "$CFG"
  grep -q "option autolearn_max_per_client '5'" "$CFG"
  grep -q "option autolearn_revalidate_days '14'" "$CFG"
  grep -q "option autolearn_max_entries '500'" "$CFG"
  grep -q "option autolearn_candidate_retention_days '30'" "$CFG"
}
