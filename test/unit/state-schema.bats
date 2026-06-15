#!/usr/bin/env bats
load '../lib/harness.bash'

@test "amnezia-status emits a doc with all required top-level keys" {
  run sh "$HARNESS_DIR/../openwrt/amnezia-status.sh" --emit-empty
  [ "$status" -eq 0 ]
  for k in mode active_pool active_sticky all_down tunnels; do
    echo "$output" | grep -q "\"$k\""
  done
}
