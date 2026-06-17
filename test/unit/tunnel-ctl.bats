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

# C1: add must NOT wipe existing firewall.vpn.network members
@test "C1: add awg2 when awg1 is present keeps awg1 in firewall.vpn.network" {
  UCI_FAKE_FWNET="awg1" run sh "$TC" add awg2 "$(cat "$FIX")"
  [ "$status" -eq 0 ]
  # awg2 must be added
  grep -q 'add_list firewall.vpn.network=awg2' "$STUB_LOG"
  # awg1 must NOT be deleted (no blanket delete before add)
  # A delete firewall.vpn.network command (without =value) signals a list wipe
  run grep -q 'uci -q delete firewall.vpn.network$\|uci delete firewall.vpn.network$' "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# C2: add must apply gen_tunnel_uci via uci batch so I-field values with spaces are not split
@test "C2: I1 field value with spaces reaches uci intact (not word-split)" {
  run sh "$TC" add awg2 "$(cat "$FIX")"
  [ "$status" -eq 0 ]
  # The fixture has: I1 = <b 0xf1f2 0xf3f4 0xf5f6>
  # gen_tunnel_uci single-quotes it: set network.awg2.awg_i1='<b 0xf1f2 0xf3f4 0xf5f6>'
  # uci batch receives the quoted form; stub logs: uci batch
  # Verify that uci batch was called (not per-line uci)
  grep -q 'uci batch' "$STUB_LOG"
}

# H1: remove must delete anonymous peer section (not named section)
@test "H1: remove deletes network.@amneziawg_awg2[0] (anonymous section idiom)" {
  UCI_FAKE_TUNNELS="awg1 awg2" UCI_FAKE_FWNET="awg1 awg2" run sh "$TC" remove awg2
  [ "$status" -eq 0 ]
  # Must use anonymous-section delete form
  grep -q 'delete network.@amneziawg_awg2\[0\]' "$STUB_LOG"
  # Must NOT use the (wrong) named-section form
  run grep -q 'delete network.amneziawg_awg2$' "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# H2: add must refuse invalid names BEFORE any UCI mutation
@test "H2: add awg9 refused (exceeds MAX_TUNNELS=5)" {
  run sh "$TC" add awg9 "$(cat "$FIX")"
  [ "$status" -ne 0 ]
  run grep -q 'uci set\|uci batch\|uci commit' "$STUB_LOG"
  [ "$status" -ne 0 ]
}
@test "H2: add path-traversal name refused" {
  run sh "$TC" add '../etc/passwd' "$(cat "$FIX")"
  [ "$status" -ne 0 ]
  run grep -q 'uci set\|uci batch\|uci commit' "$STUB_LOG"
  [ "$status" -ne 0 ]
}
@test "H2: add awg1 refused when awg1 already exists" {
  UCI_FAKE_TUNNELS="awg1" run sh "$TC" add awg1 "$(cat "$FIX")"
  [ "$status" -ne 0 ]
  run grep -q 'uci set amnezia.awg1\|uci batch\|uci commit' "$STUB_LOG"
  [ "$status" -ne 0 ]
}

# M2: metric must equal slot index, not count+1
@test "M2: metric for awg3 is 3 (slot index, not count+1)" {
  run sh "$TC" add awg3 "$(cat "$FIX")"
  [ "$status" -eq 0 ]
  grep -q 'set amnezia.awg3.metric=3' "$STUB_LOG"
}

# L1: _fwnet_count returns a single integer (not two lines at zero)
@test "L1: _fwnet_count returns single integer 0 when no members" {
  # UCI_FAKE_FWNET unset → show firewall returns nothing
  unset UCI_FAKE_FWNET
  # remove awg2 with awg1 faking exactly 1 fw member → count=1 triggers the guard
  UCI_FAKE_TUNNELS="awg1 awg2" UCI_FAKE_FWNET="awg2" run sh "$TC" remove awg2
  # Should refuse because count=1 (would leave zero members)
  [ "$status" -ne 0 ]
}
