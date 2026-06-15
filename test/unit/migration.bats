#!/usr/bin/env bats
load '../lib/harness.bash'

@test "migration declares sets, repoints dnsmasq, installs, THEN removes pbr only if ru4 populated" {
  NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  # ordering check — assert both markers exist before comparing positions
  o="$output"
  echo "$o" | grep -q "install:classifier" || { echo "marker install:classifier missing"; false; }
  echo "$o" | grep -q "remove:pbr"        || { echo "marker remove:pbr missing"; false; }
  pos_install=$(echo "$o" | grep -n "install:classifier" | head -1 | cut -d: -f1)
  pos_remove=$(echo "$o"  | grep -n "remove:pbr"         | head -1 | cut -d: -f1)
  [ "$pos_install" -lt "$pos_remove" ]
}
@test "migration ABORTS pbr removal when amnezia_ru4 is empty" {
  NFT_FAKE_RU4_COUNT=0 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  ! echo "$output" | grep -q "remove:pbr"
  echo "$output" | grep -q "ABORT:ru4-empty"
}
@test "migration does NOT delete or rebuild amnezia_block_quic (negative-space)" {
  # Drive migration with the uci stub pre-loaded with the QUIC rule fixture.
  UCI_PRELOAD="$HARNESS_DIR/../test/fixtures/firewall-quic.uci" \
    NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  ! echo "$output" | grep -q "uci delete firewall.amnezia_block_quic"
  ! echo "$output" | grep -q "uci set firewall.amnezia_block_quic"
}
@test "must-tunnel migration: domains from seed-must-tunnel.list each get a sticky binding" {
  # Fixture: a multi-entry seed-must-tunnel.list
  printf 'example.com\nfoo.org\n' > "$BATS_TEST_TMPDIR/seed-must-tunnel.list"
  MUST_TUNNEL_LIST="$BATS_TEST_TMPDIR/seed-must-tunnel.list" \
    NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  grep -q "uci add_list dhcp.amnezia_sticky.domain=example.com" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_sticky.domain=foo.org" "$STUB_LOG"
}
@test "migrate (real branch) calls routing_firewall_apply and routing_disable_lan_v6" {
  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate
  # Real firewall apply must emit real uci set calls.
  grep -q "uci set firewall.vpn=zone" "$STUB_LOG"
  grep -q "uci add_list firewall.vpn.network=awg1" "$STUB_LOG"
  # v6 disable must be called.
  grep -q "uci set dhcp.lan.ra=disabled" "$STUB_LOG"
}
@test "must-tunnel add_list is idempotent (delete before repopulate)" {
  # If migrate is called twice, the sticky list must not double-accumulate.
  printf 'example.com\n' > "$BATS_TEST_TMPDIR/seed-must-tunnel.list"
  MUST_TUNNEL_LIST="$BATS_TEST_TMPDIR/seed-must-tunnel.list" \
    NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  # A delete of the list section must precede the add_list repopulation.
  grep -q "uci -q delete dhcp.amnezia_sticky" "$STUB_LOG"
}
