#!/usr/bin/env bats
load '../lib/harness.bash'
F="$HARNESS_DIR/../openwrt/amnezia-failover.init"

@test "failover init contains master-enabled guard line" {
  grep -q 'amz_master_enabled ||' "$F"
}

@test "master-enabled guard precedes routing_install_rules in start_service" {
  guard_line=$(grep -n 'amz_master_enabled ||' "$F" | head -1 | cut -d: -f1)
  rules_line=$(grep -n 'routing_install_rules' "$F" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ] && [ -n "$rules_line" ]
  [ "$guard_line" -lt "$rules_line" ]
}
