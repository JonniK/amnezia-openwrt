#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"   # P0 stub
}

@test "force-load classifies IP/CIDR into the set and domains into config ipset" {
  printf '8.8.8.8\n1.2.3.0/24\nexample.com\n# comment\n\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'manual.example\n9.9.9.9\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # all stubs (nft/uci/dnsmasq) record to the single $STUB_LOG
  grep -q 'amnezia_force4.*8.8.8.8' "$STUB_LOG"
  grep -q 'amnezia_force4.*1.2.3.0/24' "$STUB_LOG"
  grep -q 'amnezia_force4.*9.9.9.9' "$STUB_LOG"
  grep -q 'add_list dhcp.amnezia_force.domain=example.com' "$STUB_LOG"
  grep -q 'add_list dhcp.amnezia_force.domain=manual.example' "$STUB_LOG"
}

@test "force-load restarts dnsmasq only when the domain set changed" {
  printf 'a.example\n' > "$FORCE_DIR/force-tunnel.list"
  sh "$SCRIPT"; : > "$STUB_LOG"
  sh "$SCRIPT"                                   # no change
  run grep -q 'dnsmasq.*restart' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "restarted w/o change"; false; }
  printf 'a.example\nb.example\n' > "$FORCE_DIR/force-tunnel.list"
  : > "$STUB_LOG"; sh "$SCRIPT"                   # domain added
  grep -q 'dnsmasq.*restart' "$STUB_LOG"
}

@test "save-manual writes the manual file without touching auto caches, then loads" {
  printf 'AUTO\n' > "$FORCE_DIR/force.d/x.list"
  run sh "$SCRIPT" save-manual "$(printf 'one.example\ntwo.example')"
  [ "$status" -eq 0 ]
  grep -q one.example "$FORCE_DIR/force-tunnel.list"
  grep -q AUTO "$FORCE_DIR/force.d/x.list"        # auto cache untouched
}
