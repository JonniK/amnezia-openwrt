#!/usr/bin/env bats
# Tests for dependency resolution in first_install_wiring and migrate_from_pbr.
# Covers the real (non-dry-run) paths that the dry-run tests were hiding.
load '../lib/harness.bash'

# ---------------------------------------------------------------------------
# Helper: build a minimal staging area that mirrors what install.sh puts in
# /tmp/ (Path A). Returns the dir path in $_staging_dir.
# ---------------------------------------------------------------------------
setup_staging() {
  _staging_dir="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_staging_dir/nftables.d"

  # Minimal stubs for every dep that first_install_wiring or migrate_from_pbr calls.
  printf '#!/bin/sh\necho "configure-dnsmasq-amnezia called" >> "%s/stub.log"\n' \
    "$BATS_TEST_TMPDIR" > "$_staging_dir/configure-dnsmasq-amnezia.sh"
  printf '#!/bin/sh\necho "amnezia-ru-cidr called" >> "%s/stub.log"\n' \
    "$BATS_TEST_TMPDIR" > "$_staging_dir/amnezia-ru-cidr.sh"
  printf '@@LAN_IFNAME@@\n' > "$_staging_dir/nftables.d/30-amnezia-classify.nft"
  printf 'amnezia 100 vpn\n' > "$_staging_dir/iproute2-amnezia-rt_tables.conf"
  printf '#!/bin/sh /etc/rc.common\nSTART=96\nboot() { true; }\nstart() { boot; }\n' \
    > "$_staging_dir/amnezia-ru-load.init"
  printf '#!/bin/sh\n[ "$ACTION" = reload ] || exit 0\ntrue\n' \
    > "$_staging_dir/99-amnezia-ru-load.hotplug"
  chmod +x \
    "$_staging_dir/configure-dnsmasq-amnezia.sh" \
    "$_staging_dir/amnezia-ru-cidr.sh" \
    "$_staging_dir/amnezia-ru-load.init" \
    "$_staging_dir/99-amnezia-ru-load.hotplug"
}

# ---------------------------------------------------------------------------
# #1a: resolve_dep finds dep in SCRIPT_DIR when not installed.
# ---------------------------------------------------------------------------
@test "resolve_dep: finds configure-dnsmasq-amnezia in staging (SCRIPT_DIR path)" {
  setup_staging
  # Override SCRIPT_DIR to point at our staging area; no /usr/sbin version present.
  SCRIPT_DIR="$_staging_dir" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  [ "$status" -eq 0 ]
  # Classifier install must appear (real path ran sed + wrote the file).
  grep -q "install:classifier" "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# #1b: first-install real path installs classifier, ip rules, ru-load files,
#      and enables failover — all via resolved deps.
# ---------------------------------------------------------------------------
@test "first-install (real, staged deps): classifier/ip rules/firewall all appear in STUB_LOG" {
  setup_staging
  SCRIPT_DIR="$_staging_dir" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  [ "$status" -eq 0 ]
  grep -q "install:rt_tables"               "$STUB_LOG"
  grep -q "ip rule add fwmark"              "$STUB_LOG"
  grep -q "install:classifier"              "$STUB_LOG"
  # firewall zone apply must have been called (routing_firewall_apply stub output)
  grep -q "uci set firewall.vpn=zone"       "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# #1c: migrate real path resolves classifier + amnezia-ru-cidr from SCRIPT_DIR.
# ---------------------------------------------------------------------------
@test "migrate (real, staged deps): classifier installed and ru-cidr called" {
  setup_staging
  NFT_FAKE_RU4_COUNT=12 SCRIPT_DIR="$_staging_dir" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --migrate
  [ "$status" -eq 0 ]
  grep -q "install:classifier" "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# #1d: negative — missing optional dep degrades (warns) instead of aborting.
# When configure-dnsmasq-amnezia is absent entirely, the install must NOT
# abort under set -eu; it must log a warning and continue.
# ---------------------------------------------------------------------------
@test "first-install (real): missing configure-dnsmasq-amnezia degrades with warn, no abort" {
  # Staging dir with EVERYTHING except configure-dnsmasq-amnezia.sh.
  _staging_dir2="$BATS_TEST_TMPDIR/staging_nodns"
  mkdir -p "$_staging_dir2/nftables.d"
  printf '@@LAN_IFNAME@@\n' > "$_staging_dir2/nftables.d/30-amnezia-classify.nft"
  printf 'amnezia 100 vpn\n' > "$_staging_dir2/iproute2-amnezia-rt_tables.conf"
  # No configure-dnsmasq-amnezia.sh here.

  SCRIPT_DIR="$_staging_dir2" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  # Must exit 0 (degraded, not aborted).
  [ "$status" -eq 0 ]
  # Must still have performed the other steps.
  grep -q "install:rt_tables" "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# #1e: missing classifier source file degrades (warns) instead of aborting.
# ---------------------------------------------------------------------------
@test "first-install (real): missing classifier nft source degrades with warn, no abort" {
  _staging_dir3="$BATS_TEST_TMPDIR/staging_nonft"
  mkdir -p "$_staging_dir3"
  # No nftables.d/30-amnezia-classify.nft here.
  printf 'amnezia 100 vpn\n' > "$_staging_dir3/iproute2-amnezia-rt_tables.conf"
  printf '#!/bin/sh\ntrue\n' > "$_staging_dir3/configure-dnsmasq-amnezia.sh"
  chmod +x "$_staging_dir3/configure-dnsmasq-amnezia.sh"

  SCRIPT_DIR="$_staging_dir3" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  [ "$status" -eq 0 ]
  grep -q "install:rt_tables" "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# #3: sync-to-packages.sh maps ru-load init and hotplug to correct /etc paths.
# ---------------------------------------------------------------------------
@test "sync maps amnezia-ru-load.init to /etc/init.d/amnezia-ru-load" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "amnezia-ru-load.init" "$F"
  grep -q "etc/init.d/amnezia-ru-load" "$F"
}

@test "sync maps 99-amnezia-ru-load.hotplug to /etc/hotplug.d/firewall/" {
  F="$HARNESS_DIR/../dev/sync-to-packages.sh"
  grep -q "99-amnezia-ru-load.hotplug" "$F"
  grep -q "etc/hotplug.d/firewall" "$F"
}

# ---------------------------------------------------------------------------
# #2: install.sh stages all wiring deps into /tmp/.
# ---------------------------------------------------------------------------
@test "install.sh stages amnezia-ru-cidr.sh for Path A" {
  grep -q "amnezia-ru-cidr.sh" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages lib/amnezia-common.sh for Path A" {
  grep -q "amnezia-common.sh" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages lib/amnezia-routing.sh for Path A" {
  grep -q "amnezia-routing.sh" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages 30-amnezia-classify.nft for Path A" {
  grep -q "30-amnezia-classify.nft" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages iproute2-amnezia-rt_tables.conf for Path A" {
  grep -q "iproute2-amnezia-rt_tables.conf" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages amnezia-ru-load.init for Path A" {
  grep -q "amnezia-ru-load.init" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages 99-amnezia-ru-load.hotplug for Path A" {
  grep -q "99-amnezia-ru-load.hotplug" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages amnezia-failover for Path A" {
  grep -q "amnezia-failover" "$HARNESS_DIR/../install.sh"
}

@test "install.sh stages amnezia-failover.init for Path A" {
  grep -q "amnezia-failover.init" "$HARNESS_DIR/../install.sh"
}
