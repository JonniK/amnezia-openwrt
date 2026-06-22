#!/usr/bin/env bats
load '../lib/harness.bash'
setup() { . "$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"; . "$HARNESS_DIR/../openwrt/lib/amnezia-routing.sh"; }
@test "firewall dry-run matches golden (vpn zone, v6 drop, quic preserved)" {
  run routing_firewall_dryrun "awg1 awg2"
  echo "$output" > "$BATS_TEST_TMPDIR/out.uci"
  diff "$HARNESS_DIR/../test/golden/firewall.uci" "$BATS_TEST_TMPDIR/out.uci"
}
@test "routing_firewall_apply issues real uci set/add_list calls (not just echo)" {
  routing_firewall_apply "awg1 awg2"
  # Real uci calls must appear in STUB_LOG.
  grep -q "uci set firewall.vpn=zone" "$STUB_LOG"
  grep -q "uci set firewall.vpn.name=vpn" "$STUB_LOG"
  # network members must be added via add_list, not a single space-joined scalar.
  grep -q "uci add_list firewall.vpn.network=awg1" "$STUB_LOG"
  grep -q "uci add_list firewall.vpn.network=awg2" "$STUB_LOG"
  grep -q "uci set firewall.amnezia_v6_drop=rule" "$STUB_LOG"
  grep -q "uci commit firewall" "$STUB_LOG"
}
@test "routing_firewall_apply does NOT touch amnezia_block_quic (negative-space, real apply path)" {
  # The QUIC rule fixture is pre-loaded via UCI_PRELOAD env (uci stub logs all calls).
  UCI_PRELOAD="$HARNESS_DIR/../test/fixtures/firewall-quic.uci" \
    routing_firewall_apply "awg1"
  # Real apply must NOT delete or overwrite the QUIC rule.
  ! grep -q "uci delete firewall.amnezia_block_quic" "$STUB_LOG"
  ! grep -q "uci set firewall.amnezia_block_quic" "$STUB_LOG"
  # But real uci calls for the vpn zone must be present (proves real path ran).
  grep -q "uci set firewall.vpn=zone" "$STUB_LOG"
}
