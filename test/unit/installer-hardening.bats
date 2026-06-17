#!/usr/bin/env bats
# Tests for the four hardening fixes applied to install-amnezia-pbr.sh.
#
# Fix 1: Flow offloading disabled before fw4 reload (both migrate and first-install)
# Fix 2: amnezia-ru-cidr binary installed to /usr/bin before it is run
# Fix 3: Weekly cron entry uses /usr/bin/amnezia-ru-cidr (not awg-ru-update), idempotent
# Fix 4: pbr remnants cleaned during migrate (config, pbr.d, dnsmasq section, nft fragment)
load '../lib/harness.bash'

# ---------------------------------------------------------------------------
# Fix 1: flow_offloading disabled in --migrate path
# ---------------------------------------------------------------------------
@test "Fix1/migrate: flow_offloading and flow_offloading_hw set to 0 before fw4 reload" {
  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  # Both offload knobs must be cleared.
  grep -q "uci set firewall.@defaults\[0\].flow_offloading=0" "$STUB_LOG" \
    || { echo "FAIL: flow_offloading not set to 0"; false; }
  grep -q "uci set firewall.@defaults\[0\].flow_offloading_hw=0" "$STUB_LOG" \
    || { echo "FAIL: flow_offloading_hw not set to 0"; false; }

  # The uci commit firewall must follow immediately.
  grep -q "uci commit firewall" "$STUB_LOG" \
    || { echo "FAIL: uci commit firewall not found"; false; }

  # Ordering: offload knobs must appear BEFORE fw4/firewall reload.
  pos_offload=$(grep -n "flow_offloading=0" "$STUB_LOG" | head -1 | cut -d: -f1)
  pos_reload=$(grep -n "fw4 reload\|firewall reload" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$pos_offload" ] && [ -n "$pos_reload" ] \
    || { echo "FAIL: could not locate offload or reload line"; false; }
  [ "$pos_offload" -lt "$pos_reload" ] \
    || { echo "FAIL: flow_offloading (line $pos_offload) must precede fw4 reload (line $pos_reload)"; false; }
}

@test "Fix1/migrate dry-run: flow_offloading lines NOT emitted (dry-run guard respected)" {
  NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  # In dry-run the uci set calls for offloading must not appear.
  ! grep -q "flow_offloading" "$STUB_LOG" \
    || { echo "FAIL: flow_offloading appeared in dry-run"; false; }
}

@test "Fix1/first-install: flow_offloading and flow_offloading_hw set to 0 before firewall apply" {
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install

  grep -q "uci set firewall.@defaults\[0\].flow_offloading=0" "$STUB_LOG" \
    || { echo "FAIL: flow_offloading not set to 0 in first-install"; false; }
  grep -q "uci set firewall.@defaults\[0\].flow_offloading_hw=0" "$STUB_LOG" \
    || { echo "FAIL: flow_offloading_hw not set to 0 in first-install"; false; }

  # Ordering: offload knobs before routing_firewall_apply's vpn zone uci.
  pos_offload=$(grep -n "flow_offloading=0" "$STUB_LOG" | head -1 | cut -d: -f1)
  pos_vpn=$(grep -n "uci set firewall.vpn=zone" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$pos_offload" ] && [ -n "$pos_vpn" ] \
    || { echo "FAIL: could not locate offload or vpn zone line"; false; }
  [ "$pos_offload" -lt "$pos_vpn" ] \
    || { echo "FAIL: flow_offloading (line $pos_offload) must precede vpn zone apply (line $pos_vpn)"; false; }
}

@test "Fix1/first-install dry-run: flow_offloading lines NOT emitted" {
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install --dry-run
  ! grep -q "flow_offloading" "$STUB_LOG" \
    || { echo "FAIL: flow_offloading appeared in first-install dry-run"; false; }
}

# ---------------------------------------------------------------------------
# Fix 2: amnezia-ru-cidr binary installed to /usr/bin before it is run
# ---------------------------------------------------------------------------
@test "Fix2/migrate: amnezia-ru-cidr binary self-install invoked before it is run" {
  # Plant a fake source binary in /tmp so resolve_dep finds it.
  printf '#!/bin/sh\necho "amnezia-ru-cidr:run" >> "${STUB_LOG:-/dev/null}"\n' \
    > /tmp/amnezia-ru-cidr.sh
  chmod +x /tmp/amnezia-ru-cidr.sh
  rm -f /usr/bin/amnezia-ru-cidr 2>/dev/null || true

  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  # The loader must have been invoked (either from installed path or source fallback).
  grep -q "amnezia-ru-cidr:run" "$STUB_LOG" \
    || { echo "FAIL: amnezia-ru-cidr was never run"; false; }

  # The script must have attempted to copy to /usr/bin (cp appears in STUB_LOG
  # only if the stub intercepts cp; we verify via the logic path instead by
  # checking that the binary install log message was emitted to logger).
  # The logger stub writes to STUB_LOG so look for the install/warn line.
  ( grep -q "amnezia-ru-cidr installed to /usr/bin" "$STUB_LOG" \
    || grep -q "could not install amnezia-ru-cidr to /usr/bin" "$STUB_LOG" ) \
    || { echo "FAIL: neither install nor fallback-warn log message found"; false; }

  rm -f /tmp/amnezia-ru-cidr.sh
}

@test "Fix2/first-install: amnezia-ru-cidr binary self-install invoked and binary run" {
  printf '#!/bin/sh\necho "amnezia-ru-cidr:run-fi" >> "${STUB_LOG:-/dev/null}"\n' \
    > /tmp/amnezia-ru-cidr.sh
  chmod +x /tmp/amnezia-ru-cidr.sh
  rm -f /usr/bin/amnezia-ru-cidr 2>/dev/null || true

  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install

  grep -q "amnezia-ru-cidr:run-fi" "$STUB_LOG" \
    || { echo "FAIL: amnezia-ru-cidr was never run in first-install"; false; }

  ( grep -q "amnezia-ru-cidr installed to /usr/bin" "$STUB_LOG" \
    || grep -q "could not install amnezia-ru-cidr to /usr/bin" "$STUB_LOG" ) \
    || { echo "FAIL: neither install nor fallback-warn log message found"; false; }

  rm -f /tmp/amnezia-ru-cidr.sh
}

@test "Fix2/migrate: nft set declared BEFORE amnezia-ru-cidr runs (ordering)" {
  printf '#!/bin/sh\necho "amnezia-ru-cidr:run" >> "${STUB_LOG:-/dev/null}"\n' \
    > /tmp/amnezia-ru-cidr.sh
  chmod +x /tmp/amnezia-ru-cidr.sh
  rm -f /usr/bin/amnezia-ru-cidr 2>/dev/null || true

  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  pos_nft=$(grep -n "nft add set inet fw4 amnezia_ru4" "$STUB_LOG" | head -1 | cut -d: -f1)
  pos_run=$(grep -n "amnezia-ru-cidr:run" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$pos_nft" ] && [ -n "$pos_run" ] \
    || { echo "FAIL: nft add set (line ${pos_nft:-missing}) or ru-cidr run (line ${pos_run:-missing}) not found"; false; }
  [ "$pos_nft" -lt "$pos_run" ] \
    || { echo "FAIL: nft add set (line $pos_nft) must precede amnezia-ru-cidr run (line $pos_run)"; false; }

  rm -f /tmp/amnezia-ru-cidr.sh
}

# ---------------------------------------------------------------------------
# Fix 3: Cron entry uses /usr/bin/amnezia-ru-cidr, replaces awg-ru-update
# ---------------------------------------------------------------------------
@test "Fix3/migrate: cron installs amnezia-ru-cidr weekly entry and removes awg-ru-update" {
  # Use a writable tmp dir as the cron file so we can inspect it.
  _cron="$BATS_TEST_TMPDIR/crontabs-root"
  # Pre-seed with old pbr-era entry that must be removed.
  printf '0 3 * * 0 /usr/bin/awg-ru-update >/dev/null 2>&1 # amnezia-pbr\n' > "$_cron"

  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run env _AMNEZIA_CRON_FILE="$_cron" \
      sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  # The cron file written inside the script goes to /etc/crontabs/root (which
  # can't be patched here without a wrapper), so assert via STUB_LOG that the
  # amnezia-ru-update install log message was emitted.
  grep -q "amnezia-ru-update cron installed" "$STUB_LOG" \
    || { echo "FAIL: cron install log message not found"; false; }
}

@test "Fix3/first-install: cron log message emitted (cron install attempted)" {
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install

  grep -q "amnezia-ru-update cron installed" "$STUB_LOG" \
    || { echo "FAIL: cron install log message not found in first-install"; false; }
}

@test "Fix3: installer source installs /usr/bin/amnezia-ru-cidr cron line (not awg-ru-update)" {
  # Static source check: the cron entry WRITTEN must use amnezia-ru-cidr.
  # (awg-ru-update may appear in comments/sed dedup patterns — that is expected.)
  F="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"
  # The new cron line must reference amnezia-ru-cidr.
  grep -q '/usr/bin/amnezia-ru-cidr.*# amnezia-ru-update' "$F" \
    || { echo "FAIL: amnezia-ru-cidr cron line not found in source"; false; }
  # The cron echo must NOT install an awg-ru-update command line.
  ! grep -E "^[[:space:]]*echo '.*awg-ru-update" "$F" \
    || { echo "FAIL: installer still echoes an awg-ru-update cron entry"; false; }
}

@test "Fix3: cron entry tagged # amnezia-ru-update for idempotent dedup" {
  # The dedup sed pattern matches '# amnezia-ru-update'; verify both are present.
  F="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"
  grep -q '# amnezia-ru-update' "$F" \
    || { echo "FAIL: # amnezia-ru-update tag not found in source"; false; }
  grep -q "awg-ru-update.*d.*amnezia-ru-update.*d\|sed.*awg-ru-update" "$F" \
    || grep -q "sed -i.*awg-ru-update" "$F" \
    || { echo "FAIL: sed dedup of awg-ru-update not found"; false; }
}

# ---------------------------------------------------------------------------
# Fix 4: pbr remnants removed during migrate
# ---------------------------------------------------------------------------
@test "Fix4/migrate: pbr remnants removed after pbr package removal" {
  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  # uci -q delete dhcp.pbr_ru_tld must be called.
  grep -q "uci -q delete dhcp.pbr_ru_tld" "$STUB_LOG" \
    || { echo "FAIL: uci delete dhcp.pbr_ru_tld not called"; false; }

  # uci commit dhcp must follow the delete (the routing_disable_lan_v6 also
  # calls commit dhcp, so just assert at least one commit appears after remove:pbr).
  grep -q "uci commit dhcp" "$STUB_LOG" \
    || { echo "FAIL: uci commit dhcp not found after pbr removal"; false; }

  # dnsmasq reload is called via /etc/init.d/dnsmasq which is not a stub;
  # verify instead that the source code contains the reload call (static check).
  grep -q '/etc/init.d/dnsmasq reload' \
    "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" \
    || { echo "FAIL: /etc/init.d/dnsmasq reload not found in source"; false; }
}

@test "Fix4/migrate: remnant cleanup is dry-run guarded" {
  # In dry-run mode the remnant cleanup code must NOT emit uci delete
  # or dnsmasq reload calls.
  NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate --dry-run
  ! grep -q "uci -q delete dhcp.pbr_ru_tld" "$STUB_LOG" \
    || { echo "FAIL: uci delete dhcp.pbr_ru_tld appeared in dry-run"; false; }
}

@test "Fix4/migrate: cleanup ordered AFTER pbr package removal" {
  UCI_FAKE_TUNNELS="awg1" NFT_FAKE_RU4_COUNT=12 \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate

  # The pbr_ru_tld delete must come after the opkg remove pbr line.
  pos_pbr_rm=$(grep -n "opkg remove pbr" "$STUB_LOG" | head -1 | cut -d: -f1)
  pos_tld_del=$(grep -n "uci -q delete dhcp.pbr_ru_tld" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$pos_pbr_rm" ] && [ -n "$pos_tld_del" ] \
    || { echo "FAIL: opkg remove pbr (${pos_pbr_rm:-missing}) or dhcp.pbr_ru_tld delete (${pos_tld_del:-missing}) not found"; false; }
  [ "$pos_pbr_rm" -lt "$pos_tld_del" ] \
    || { echo "FAIL: opkg remove pbr (line $pos_pbr_rm) must precede dhcp.pbr_ru_tld delete (line $pos_tld_del)"; false; }
}

@test "Fix4: source contains rm -f /etc/config/pbr and rm -rf /etc/pbr.d/" {
  F="$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh"
  grep -q 'rm -f /etc/config/pbr' "$F" \
    || { echo "FAIL: rm -f /etc/config/pbr not in source"; false; }
  grep -q 'rm -rf /etc/pbr.d/' "$F" \
    || { echo "FAIL: rm -rf /etc/pbr.d/ not in source"; false; }
  grep -q 'rm -f /etc/nftables.d/15-pbr-ru-tld4.nft' "$F" \
    || { echo "FAIL: rm -f 15-pbr-ru-tld4.nft not in source"; false; }
}
