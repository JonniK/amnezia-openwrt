#!/usr/bin/env bats
load '../lib/harness.bash'
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only
}

@test "writes state json with required keys and per-tunnel objects" {
  MODE=failover MEMBERS="awg1:1:1 awg2:2:1" HEALTHY="awg2" STATE_FILE="$BATS_TEST_TMPDIR/s.json"
  write_state awg2 awg2
  for k in mode active_pool active_sticky all_down tunnels; do grep -q "\"$k\"" "$BATS_TEST_TMPDIR/s.json"; done
  grep -q "\"name\":\"awg1\"" "$BATS_TEST_TMPDIR/s.json"
  grep -q "\"up\":false" "$BATS_TEST_TMPDIR/s.json"   # awg1 not in HEALTHY
}
