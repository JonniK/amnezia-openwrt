#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-failover-ctl.sh"
setup() {
  export AMNEZIA_NFT_DIR="$HARNESS_DIR/../openwrt/nftables.d"
  export AMNEZIA_CLASSIFIER_OUT="$BATS_TEST_TMPDIR/active.nft"   # redirect the write target in tests
  export UCI_FAKE_SOURCES="itdoginfo_inside:1 antifilter:0"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"
}
@test "set-routing-mode validates, regenerates classifier, force-loads, flushes both marks" {
  run sh "$CTL" set-routing-mode direct-default
  [ "$status" -eq 0 ]
  grep -q 'uci set amnezia.config.routing_mode=direct-default' "$STUB_LOG"
  grep -q '@amnezia_force4' "$AMNEZIA_CLASSIFIER_OUT"        # direct fragment written
  grep -q 'amnezia-force-load' "$STUB_LOG"
  # conntrack stub logs its args; match case-insensitively (constants are 0x0B.. but tolerate 0xb..)
  grep -qiE -- '-D -m 0x0?b0000/0x0?ff0000' "$STUB_LOG"      # pool mark flushed
  grep -qiE -- '-D -m 0x0?a0000/0x0?ff0000' "$STUB_LOG"      # sticky mark flushed
}
@test "set-routing-mode rejects an unknown mode" {
  run sh "$CTL" set-routing-mode bogus; [ "$status" -ne 0 ]
}
@test "set-source toggles a known source and rejects unknown" {
  run sh "$CTL" set-source antifilter 1
  [ "$status" -eq 0 ]; grep -q 'uci set amnezia.antifilter.enabled=1' "$STUB_LOG"
  run sh "$CTL" set-source not_a_source 1; [ "$status" -ne 0 ]
}
