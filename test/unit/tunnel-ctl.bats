#!/usr/bin/env bats
load '../lib/harness.bash'
TC="$HARNESS_DIR/../openwrt/amnezia-tunnel-ctl.sh"
FIX="$HARNESS_DIR/fixtures/awg-sample.conf"
setup() {
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"
  export CONF_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$CONF_DIR"
}
@test "list-free returns the lowest free slot, accounting for gaps" {
  UCI_FAKE_TUNNELS="awg1 awg3" run sh "$TC" list-free; [ "$output" = awg2 ]
}
@test "list-free exits 3 when full" {
  UCI_FAKE_TUNNELS="awg1 awg2 awg3 awg4 awg5" run sh "$TC" list-free; [ "$status" -eq 3 ]
}
@test "add refuses a conf missing Endpoint (no UCI mutation)" {
  run sh "$TC" add awg2 "$(printf '[Interface]\nPrivateKey=x\n[Peer]\nPublicKey=y\n')"
  [ "$status" -ne 0 ]
  run grep -q 'set network.awg2' "$STUB_LOG"; [ "$status" -ne 0 ]
}
@test "add emits typed tunnel section with all fields + fw membership + ifup + monitor restart" {
  run sh "$TC" add awg2 "$(cat "$FIX")" --label Backup
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg2=tunnel' "$STUB_LOG"
  grep -q 'set amnezia.awg2.enabled=1' "$STUB_LOG"
  grep -q 'set amnezia.awg2.label=Backup' "$STUB_LOG"
  grep -q 'set amnezia.awg2.weight=1' "$STUB_LOG"
  grep -q 'set amnezia.awg2.track_ip=' "$STUB_LOG"
  grep -q 'add_list firewall.vpn.network=awg2' "$STUB_LOG"
  grep -q 'ifup awg2' "$STUB_LOG"
  grep -q 'amnezia-failover restart' "$STUB_LOG"
}
@test "remove refuses the sticky target" {
  UCI_FAKE_TUNNELS="awg1 awg2" run sh "$TC" remove awg1   # sticky_target=awg1 (uci stub)
  [ "$status" -ne 0 ]
}
@test "remove refuses leaving zero firewall.vpn.network members" {
  UCI_FAKE_FWNET="awg2" run sh "$TC" remove awg2; [ "$status" -ne 0 ]
}
@test "remove stops the monitor BEFORE teardown, restarts after" {
  UCI_FAKE_TUNNELS="awg1 awg2" UCI_FAKE_FWNET="awg1 awg2" run sh "$TC" remove awg2
  [ "$status" -eq 0 ]
  awk '/amnezia-failover stop/{s=NR} /ifdown awg2/{i=NR} /amnezia-failover start/{e=NR} \
    END{exit !(s&&i&&e&&s<i&&i<e)}' "$STUB_LOG"
}
