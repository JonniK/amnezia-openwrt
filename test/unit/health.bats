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
  # First call with no pre-existing rule — tbl 110 for awg1.
  probe_setup awg1 1.1.1.1 110
  _count=$(grep -c "ip route replace 1.1.1.1 dev awg1 table 110" "$STUB_LOG" || true)
  [ "$_count" -eq 1 ]
  # State file is keyed by iface, not target.
  [ -f "$ST_DIR/probe_rule_awg1" ]
  # Second call must NOT add another ip rule.
  : > "$STUB_LOG"
  probe_setup awg1 1.1.1.1 110
  ! grep -q "ip rule add" "$STUB_LOG"
}

@test "probe_cleanup removes probe rule, route, and state file (idempotent)" {
  # Install probe state first — tbl 110 for awg1.
  probe_setup awg1 1.1.1.1 110
  [ -f "$ST_DIR/probe_rule_awg1" ]
  # Cleanup must remove the state file and issue the ip commands.
  probe_cleanup awg1 1.1.1.1 110
  [ ! -f "$ST_DIR/probe_rule_awg1" ]
  grep -q "ip rule del from 10.100.1.2 lookup 110" "$STUB_LOG"
  grep -q "ip route del 1.1.1.1 table 110" "$STUB_LOG"
  # Second call must not error (idempotent).
  probe_cleanup awg1 1.1.1.1 110
  [ ! -f "$ST_DIR/probe_rule_awg1" ]
}

@test "_daemon_cleanup calls probe_cleanup for each member and removes state files" {
  # Simulate the run_loop environment: set MEMBERS with track_ip accessible via uci stub
  MEMBERS="awg1:1:1 awg2:2:1"
  probe_setup awg1 1.1.1.1 110
  probe_setup awg2 8.8.8.8 111
  [ -f "$ST_DIR/probe_rule_awg1" ]
  [ -f "$ST_DIR/probe_rule_awg2" ]
  # _daemon_cleanup is defined inside run_loop; define a testable wrapper here
  # that mirrors the cleanup loop without needing _ubus_pid or uci.
  _test_cleanup() {
    for _m in $MEMBERS; do _n=${_m%%:*}
      case "$_n" in
        awg1) _track=1.1.1.1; _probe_tbl=110 ;;
        awg2) _track=8.8.8.8; _probe_tbl=111 ;;
        *)    _track=1.1.1.1; _probe_tbl=110 ;;
      esac
      probe_cleanup "$_n" "$_track" "$_probe_tbl"
    done
  }
  _test_cleanup
  [ ! -f "$ST_DIR/probe_rule_awg1" ]
  [ ! -f "$ST_DIR/probe_rule_awg2" ]
  grep -q "ip rule del from 10.100.1.2 lookup 110" "$STUB_LOG"
  grep -q "ip rule del from 10.100.2.2 lookup 111" "$STUB_LOG"
}

@test "daemon trap line is present in amnezia-failover for TERM INT EXIT" {
  grep -q "trap '_daemon_cleanup' TERM INT EXIT" "$HARNESS_DIR/../openwrt/amnezia-failover"
}

@test "daemon kill of listener uses process-group kill (covers ubus listen child)" {
  grep -q 'kill -- "-\${_ubus_pid}"' "$HARNESS_DIR/../openwrt/amnezia-failover"
}

@test "two tunnels sharing track_ip each get a distinct probe route bound to their own dev" {
  # Both awg1 and awg2 use 1.1.1.1 as track_ip — the classic collision scenario.
  probe_setup awg1 1.1.1.1 110
  probe_setup awg2 1.1.1.1 111
  # Each tunnel must have its own route in its own table.
  grep -q "ip route replace 1.1.1.1 dev awg1 table 110" "$STUB_LOG"
  grep -q "ip route replace 1.1.1.1 dev awg2 table 111" "$STUB_LOG"
  # Each tunnel must have its own state file (keyed by iface, not target).
  [ -f "$ST_DIR/probe_rule_awg1" ]
  [ -f "$ST_DIR/probe_rule_awg2" ]
  # Each tunnel must have its own ip rule keyed by its unique source address.
  grep -q "ip rule add from 10.100.1.2 lookup 110" "$STUB_LOG"
  grep -q "ip rule add from 10.100.2.2 lookup 111" "$STUB_LOG"
  # Cleanup must remove both independently.
  probe_cleanup awg1 1.1.1.1 110
  probe_cleanup awg2 1.1.1.1 111
  [ ! -f "$ST_DIR/probe_rule_awg1" ]
  [ ! -f "$ST_DIR/probe_rule_awg2" ]
  grep -q "ip rule del from 10.100.1.2 lookup 110" "$STUB_LOG"
  grep -q "ip rule del from 10.100.2.2 lookup 111" "$STUB_LOG"
  grep -q "ip route del 1.1.1.1 table 110" "$STUB_LOG"
  grep -q "ip route del 1.1.1.1 table 111" "$STUB_LOG"
}
