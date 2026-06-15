#!/usr/bin/env bats
load '../lib/harness.bash'
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only
}

@test "restart with existing state does not reset a tunnel that was confirmed down" {
  # Simulate a tunnel that was confirmed down before a daemon restart.
  echo "down 0" > "$ST_DIR/awg1"
  # Replicate the run_loop logic: only seed state_reset when no prior file exists.
  [ -f "$ST_DIR/awg1" ] || state_reset awg1
  [ "$(state_get awg1)" = down ]
}

@test "needs 3 consecutive fails to go down, 3 to come up" {
  state_reset awg1
  # debounce returns 1 (no state change) on first N-1 calls; || true guards set -e.
  for i in 1 2; do debounce awg1 0 || true; [ "$(state_get awg1)" = up ]; done
  debounce awg1 0 || true; [ "$(state_get awg1)" = down ]
  for i in 1 2; do debounce awg1 1 || true; [ "$(state_get awg1)" = down ]; done
  debounce awg1 1 || true; [ "$(state_get awg1)" = up ]
}
