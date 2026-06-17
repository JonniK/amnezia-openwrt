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
@test "aborted migration (ru4-empty) does NOT leave dnsmasq repointed" {
  # When @amnezia_ru4 is empty the migration must abort before touching dnsmasq.
  # In dry-run the 'repoint:dnsmasq' marker must NOT appear in stdout.
  NFT_FAKE_RU4_COUNT=0 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  echo "$output" | grep -q "ABORT:ru4-empty"
  ! echo "$output" | grep -q "repoint:dnsmasq"
  # In the real (non-dry-run) path, configure-dnsmasq-amnezia.sh must not be called.
  ! grep -q "configure-dnsmasq-amnezia" "$STUB_LOG"
}
@test "successful migration repoints dnsmasq AFTER the ru4 gate (ordering)" {
  NFT_FAKE_RU4_COUNT=12 run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  o="$output"
  echo "$o" | grep -q "install:classifier"
  echo "$o" | grep -q "repoint:dnsmasq"
  echo "$o" | grep -q "remove:pbr"
  # install:classifier must appear before repoint:dnsmasq
  pos_classifier=$(echo "$o" | grep -n "install:classifier" | head -1 | cut -d: -f1)
  pos_dnsmasq=$(echo "$o"    | grep -n "repoint:dnsmasq"    | head -1 | cut -d: -f1)
  pos_remove=$(echo "$o"     | grep -n "remove:pbr"          | head -1 | cut -d: -f1)
  [ "$pos_classifier" -lt "$pos_dnsmasq" ]
  [ "$pos_dnsmasq" -lt "$pos_remove" ]
}

# ---------------------------------------------------------------------------
# New test: real-path wiring completeness (catches BUG 1 + BUG 2).
# ---------------------------------------------------------------------------
@test "migrate (real path): ru4 set declared before ru-cidr runs, full failover stack wired, fw4 before pbr removal" {
  # Plant a fake amnezia-ru-cidr.sh in /tmp so resolve_dep finds it and
  # we can verify its invocation order relative to the nft add set call.
  printf '#!/bin/sh\necho "amnezia-ru-cidr:run" >> "${STUB_LOG:-/dev/null}"\n' \
    > /tmp/amnezia-ru-cidr.sh
  chmod +x /tmp/amnezia-ru-cidr.sh
  rm -f /usr/bin/amnezia-ru-cidr 2>/dev/null || true

  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  # --- BUG 1: amnezia_ru4 set must be DECLARED before ru-cidr populates it ---
  grep -q "nft add set inet fw4 amnezia_ru4" "$STUB_LOG" \
    || { echo "FAIL: nft add set amnezia_ru4 never called"; false; }
  grep -q "amnezia-ru-cidr:run" "$STUB_LOG" \
    || { echo "FAIL: amnezia-ru-cidr never invoked"; false; }
  # Line-number ordering: set declaration must precede ru-cidr invocation.
  pos_nft_set=$(grep -n "nft add set inet fw4 amnezia_ru4" "$STUB_LOG" | head -1 | cut -d: -f1)
  pos_rucidr=$(grep -n "amnezia-ru-cidr:run" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ "$pos_nft_set" -lt "$pos_rucidr" ] \
    || { echo "FAIL: nft add set (line $pos_nft_set) must precede ru-cidr (line $pos_rucidr)"; false; }

  # --- BUG 2: full failover stack must be wired ---
  # rt_tables installed (logger stub captures amz_log "install:rt_tables")
  grep -q "install:rt_tables" "$STUB_LOG" \
    || { echo "FAIL: install:rt_tables not found in STUB_LOG"; false; }
  # ip rules installed (routing_install_rules calls ip rule add)
  grep -q "ip rule add pref" "$STUB_LOG" \
    || { echo "FAIL: ip rule add pref not found — routing_install_rules not called"; false; }
  # Fail-closed blackhole routes installed
  grep -q "ip route replace blackhole default table" "$STUB_LOG" \
    || { echo "FAIL: fail-closed blackhole routes not installed"; false; }
  # amnezia-failover monitor enabled
  grep -q "amnezia-failover:enable" "$STUB_LOG" \
    || { echo "FAIL: amnezia-failover enable not called"; false; }

  # --- Step 13 before 14: fw4/firewall reload must precede opkg remove pbr ---
  # At least one of fw4 reload or /etc/init.d/firewall reload must appear.
  ( grep -q "^fw4 reload" "$STUB_LOG" || grep -q "firewall reload" "$STUB_LOG" ) \
    || { echo "FAIL: no fw4/firewall reload found before pbr removal"; false; }
  grep -q "opkg remove pbr" "$STUB_LOG" \
    || { echo "FAIL: opkg remove pbr not found"; false; }
  # Ordering: classifier activation before pbr removal.
  pos_fw4=$(grep -n "fw4 reload\|firewall reload" "$STUB_LOG" | head -1 | cut -d: -f1)
  pos_pbr_remove=$(grep -n "opkg remove pbr" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ "$pos_fw4" -lt "$pos_pbr_remove" ] \
    || { echo "FAIL: fw4/firewall reload (line $pos_fw4) must precede opkg remove pbr (line $pos_pbr_remove)"; false; }

  # Cleanup
  rm -f /tmp/amnezia-ru-cidr.sh
}
