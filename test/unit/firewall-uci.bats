#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }
@test "firewall dry-run matches golden (vpn zone, v6 drop, quic preserved)" {
  run routing_firewall_dryrun "awg1 awg2"
  echo "$output" > "$BATS_TEST_TMPDIR/out.uci"
  diff "$HARNESS_DIR/../test/golden/firewall.uci" "$BATS_TEST_TMPDIR/out.uci"
}
@test "migration with quic fixture does NOT delete amnezia_block_quic (negative-space)" {
  # Drive migration with the uci stub pre-loaded with the QUIC rule via env.
  UCI_PRELOAD="$HARNESS_DIR/../test/fixtures/firewall-quic.uci" \
    routing_firewall_dryrun "awg1"
  # No delete of the QUIC rule must appear — the migration must never destroy it.
  ! grep -q "uci delete firewall.amnezia_block_quic" "$STUB_LOG"
  ! grep -q "uci set firewall.amnezia_block_quic" "$STUB_LOG"
}
