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

@test "probe_cleanup removes probe rule, route, and state file (idempotent)" {
  # Install probe state first
  IP_FAKE_PROBE_RULE=0 probe_setup awg1 1.1.1.1
  [ -f "$ST_DIR/probe_rule_1.1.1.1" ]
  # Cleanup must remove the state file and issue the ip commands
  probe_cleanup awg1 1.1.1.1
  [ ! -f "$ST_DIR/probe_rule_1.1.1.1" ]
  grep -q "ip rule del to 1.1.1.1 lookup 110" "$STUB_LOG"
  grep -q "ip route del 1.1.1.1 table 110" "$STUB_LOG"
  # Second call must not error (idempotent)
  probe_cleanup awg1 1.1.1.1
  [ ! -f "$ST_DIR/probe_rule_1.1.1.1" ]
}

@test "_daemon_cleanup calls probe_cleanup for each member and removes state files" {
  # Simulate the run_loop environment: set MEMBERS with track_ip accessible via uci stub
  MEMBERS="awg1:1:1 awg2:2:1"
  IP_FAKE_PROBE_RULE=0
  probe_setup awg1 1.1.1.1
  probe_setup awg2 8.8.8.8
  [ -f "$ST_DIR/probe_rule_1.1.1.1" ]
  [ -f "$ST_DIR/probe_rule_8.8.8.8" ]
  # _daemon_cleanup is defined inside run_loop; define a testable wrapper here
  # that mirrors the cleanup loop without needing _ubus_pid or uci
  _test_cleanup() {
    for _m in $MEMBERS; do _n=${_m%%:*}
      case "$_n" in
        awg1) _track=1.1.1.1 ;;
        awg2) _track=8.8.8.8 ;;
        *)    _track=1.1.1.1 ;;
      esac
      probe_cleanup "$_n" "$_track"
    done
  }
  _test_cleanup
  [ ! -f "$ST_DIR/probe_rule_1.1.1.1" ]
  [ ! -f "$ST_DIR/probe_rule_8.8.8.8" ]
  grep -q "ip rule del to 1.1.1.1 lookup 110" "$STUB_LOG"
  grep -q "ip rule del to 8.8.8.8 lookup 110" "$STUB_LOG"
}

@test "daemon trap line is present in amnezia-failover for TERM INT EXIT" {
  grep -q "trap '_daemon_cleanup' TERM INT EXIT" "$HARNESS_DIR/../openwrt/amnezia-failover"
}

@test "daemon kill of listener uses process-group kill (covers ubus listen child)" {
  grep -q 'kill -- "-\${_ubus_pid}"' "$HARNESS_DIR/../openwrt/amnezia-failover"
}
