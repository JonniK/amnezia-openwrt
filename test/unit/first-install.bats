#!/usr/bin/env bats
load '../lib/harness.bash'

@test "first-install wiring copies rt_tables, runs routing_install_rules, enables monitor, installs classifier" {
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install --dry-run
  # rt_tables
  grep -q "install:rt_tables" "$STUB_LOG"
  # ip rules
  grep -q "ip rule add pref" "$STUB_LOG"
  # monitor enabled
  grep -q "/etc/init.d/amnezia-failover enable" "$STUB_LOG"
  # classifier installed
  grep -q "install:classifier" "$STUB_LOG"
  # dnsmasq ipset configured
  grep -q "uci set dhcp.amnezia_ru_tld=ipset" "$STUB_LOG"
}
@test "first-install (real branch) calls routing_firewall_apply and routing_disable_lan_v6" {
  UCI_FAKE_TUNNELS="awg1 awg2" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  # Real firewall apply must emit real uci set calls (not just echo).
  grep -q "uci set firewall.vpn=zone" "$STUB_LOG"
  grep -q "uci add_list firewall.vpn.network=awg1" "$STUB_LOG"
  # v6 disable must be called.
  grep -q "uci set dhcp.lan.ra=disabled" "$STUB_LOG"
  grep -q "uci commit dhcp" "$STUB_LOG"
}
@test "first-install (real branch) applies all enabled tunnels via uci" {
  UCI_FAKE_TUNNELS="awg1 awg2" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  # Each enabled tunnel must be applied via uci (network interface section).
  # The stub reports no .conf files so we can only verify the tunnel-list is used.
  grep -q "uci add_list firewall.vpn.network=awg1" "$STUB_LOG"
  grep -q "uci add_list firewall.vpn.network=awg2" "$STUB_LOG"
}
@test "first-install per-tunnel network apply: uci batch and ifup invoked for each conf-backed tunnel" {
  # Verify the per-tunnel bring-up loop: for each tunnel whose .conf exists,
  # the installer must call 'uci batch' (to apply network UCI) and 'ifup <tunnel>'.
  # Prior to the CONF_DIR save/restore fix, amnezia-common.sh hard-overwrote
  # CONF_DIR=/etc/amnezia and the conf files were never found, silently skipping
  # the uci batch + ifup block for every tunnel.
  _conf_dir="$BATS_TEST_TMPDIR/confs"
  mkdir -p "$_conf_dir"
  cp "$HARNESS_DIR/../test/fixtures/awg-sample.conf" "$_conf_dir/awg1.conf"
  cp "$HARNESS_DIR/../test/fixtures/awg2.conf"       "$_conf_dir/awg2.conf"
  CONF_DIR="$_conf_dir" UCI_FAKE_TUNNELS="awg1 awg2" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  # uci batch must have been called for both tunnels (two separate pipe invocations).
  [ "$(grep -c "^uci batch" "$STUB_LOG")" -ge 2 ]
  # ifup must have been invoked once per tunnel.
  grep -q "ifup awg1" "$STUB_LOG"
  grep -q "ifup awg2" "$STUB_LOG"
}
@test "first-install skips uci batch and ifup for a tunnel with a malformed conf" {
  # A .conf missing PrivateKey/PublicKey must cause gen_tunnel_uci to fail;
  # the installer must skip uci batch and ifup for that tunnel only.
  # A sibling tunnel with a valid conf must still be applied.
  _conf_dir="$BATS_TEST_TMPDIR/confs"
  mkdir -p "$_conf_dir"
  cp "$HARNESS_DIR/../test/fixtures/awg-sample.conf"  "$_conf_dir/awg1.conf"
  cp "$HARNESS_DIR/../test/fixtures/awg-malformed.conf" "$_conf_dir/awg2.conf"
  CONF_DIR="$_conf_dir" UCI_FAKE_TUNNELS="awg1 awg2" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  # Valid tunnel (awg1) must be applied and brought up.
  grep -q "ifup awg1" "$STUB_LOG"
  # Malformed tunnel (awg2) must NOT be applied or brought up.
  ! grep -q "ifup awg2" "$STUB_LOG"
  # Only one uci batch call (for awg1), not two.
  [ "$(grep -c "^uci batch" "$STUB_LOG")" -eq 1 ]
}

# Phase 9 (covert-creator-router plan): fixed-uid user creation.
# OpenWrt busybox ships no adduser/addgroup applets (verified on the armsr
# aarch64 VM 2026-09-04) -- the installer creates the user/group by
# appending directly to /etc/passwd + /etc/group instead.
@test "first-install creates amnezia-covert user+group at fixed uid/gid" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  _group="$BATS_TEST_TMPDIR/group-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  printf 'root:x:0:\n' > "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  grep -qE '^amnezia-covert:x:391:391:' "$_passwd"
  grep -qE '^amnezia-covert:x:391:' "$_group"
}

@test "first-install is idempotent when amnezia-covert already exists at the correct uid" {
  _passwd="$BATS_TEST_TMPDIR/passwd-existing"
  _group="$BATS_TEST_TMPDIR/group-existing"
  printf 'root:x:0:0:root:/root:/bin/ash\namnezia-covert:x:391:391:amnezia-covert:/var/run/amnezia-covert:/bin/false\n' > "$_passwd"
  printf 'root:x:0:\namnezia-covert:x:391:\n' > "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  [ "$(grep -c '^amnezia-covert:' "$_passwd")" -eq 1 ]
  [ "$(grep -c '^amnezia-covert:' "$_group")" -eq 1 ]
  ! grep -q "ERROR: amnezia-covert exists with uid=" "$STUB_LOG"
}

@test "first-install refuses and creates nothing when the fixed uid is held by a different user" {
  _passwd="$BATS_TEST_TMPDIR/passwd-uid-collision"
  _group="$BATS_TEST_TMPDIR/group-clean"
  cp "$HARNESS_DIR/../test/fixtures/passwd-uid-collision" "$_passwd"
  printf 'root:x:0:\n' > "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  # NOTE: `!`-negated commands are exempt from bash errexit, so a `!`
  # assertion must never be a non-final statement in a bats test body (its
  # failure would silently not fail the test) -- use `run` + an explicit
  # status check instead.
  run grep -q '^amnezia-covert:' "$_passwd"
  [ "$status" -ne 0 ]
  run grep -q '^amnezia-covert:' "$_group"
  [ "$status" -ne 0 ]
  grep -q "held by user 'nobody'" "$STUB_LOG"
}

@test "first-install refuses and creates nothing when the fixed gid is held by a different group" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  _group="$BATS_TEST_TMPDIR/group-gid-collision"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  cp "$HARNESS_DIR/../test/fixtures/group-gid-collision" "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  run grep -q '^amnezia-covert:' "$_passwd"
  [ "$status" -ne 0 ]
  run grep -q '^amnezia-covert:' "$_group"
  [ "$status" -ne 0 ]
  grep -q "held by group 'othergrp'" "$STUB_LOG"
}

@test "first-install pre-creates covert.log 0640 owned by amnezia-covert:amnezia-covert" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  _group="$BATS_TEST_TMPDIR/group-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  printf 'root:x:0:\n' > "$_group"
  _covert_dir="$BATS_TEST_TMPDIR/covert"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" AMZ_COVERT_DIR="$_covert_dir" AMZ_COVERT_LOG="$_covert_dir/covert.log" \
    UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  [ -f "$_covert_dir/covert.log" ]
  _mode=$(stat -f %Lp "$_covert_dir/covert.log" 2>/dev/null || stat -c %a "$_covert_dir/covert.log" 2>/dev/null)
  [ "$_mode" = "640" ]
}

# H4 gap (VM probe 2026-09-04): amnezia.config.covert_enabled is absent on a
# fresh/cutover install whose /etc/config/amnezia predates this feature (the
# shipped default only reaches .ipk installs). The installer must default it
# to 0 (feature OFF) when unset -- the uci stub's "get" falls through to exit 1
# / empty output for any key with no UCI_GET_* override, which is exactly the
# "unset" case here (no UCI_GET_amnezia_config_covert_enabled exported).
@test "first-install defaults covert_enabled to 0 when unset" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  _group="$BATS_TEST_TMPDIR/group-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  printf 'root:x:0:\n' > "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  grep -q "uci set amnezia.config.covert_enabled=0" "$STUB_LOG"
}

# The important half of the guard: a user's existing covert_enabled=1 must
# survive a re-install/upgrade. Without the "unset" guard, a shared default
# write would silently disable a user's already-enabled feature.
@test "first-install does NOT reset an existing covert_enabled=1" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  _group="$BATS_TEST_TMPDIR/group-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  printf 'root:x:0:\n' > "$_group"
  AMNEZIA_PASSWD="$_passwd" AMNEZIA_GROUP="$_group" UCI_FAKE_TUNNELS="awg1" \
    UCI_GET_amnezia_config_covert_enabled="1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  ! grep -q "uci set amnezia.config.covert_enabled=0" "$STUB_LOG"
}
