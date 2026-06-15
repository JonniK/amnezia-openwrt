#!/usr/bin/env bats
load '../lib/harness.bash'
setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export ST_DIR="$BATS_TEST_TMPDIR/amnezia-fo"
  mkdir -p "$ST_DIR"
  . "$HARNESS_DIR/../openwrt/amnezia-failover" --source-only
}

@test "fresh handshake -> healthy WITHOUT requiring a ping (fresh wins immediately)" {
  AWG_FAKE_HS=now PING_FAKE_OK=0 run tunnel_healthy awg1 1.1.1.1
  [ "$status" -eq 0 ]
  # ping must NOT have been called when handshake is fresh
  ! grep -q "ping -I awg1" "$STUB_LOG"
}
@test "stale handshake AND ping fail -> unhealthy" {
  AWG_FAKE_HS=stale PING_FAKE_OK=0 run tunnel_healthy awg1 1.1.1.1
  [ "$status" -ne 0 ]
}
@test "stale handshake but ping ok -> healthy (ping breaks the tie)" {
  AWG_FAKE_HS=stale PING_FAKE_OK=1 run tunnel_healthy awg1 1.1.1.1
  [ "$status" -eq 0 ]
}
@test "probe_setup installs probe route+rule idempotently (no duplicate rules)" {
  # First call with no pre-existing rule
  IP_FAKE_PROBE_RULE=0 probe_setup awg1 1.1.1.1
  _count=$(grep -c "ip rule add to 1.1.1.1 lookup 110" "$STUB_LOG" || true)
  [ "$_count" -eq 1 ]
  # Second call with rule already present — must NOT add again
  IP_FAKE_PROBE_RULE=1 probe_setup awg1 1.1.1.1
  _count2=$(grep -c "ip rule add to 1.1.1.1 lookup 110" "$STUB_LOG" || true)
  [ "$_count2" -eq 1 ]
}
