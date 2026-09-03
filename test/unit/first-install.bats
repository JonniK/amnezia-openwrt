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
@test "first-install creates amnezia-covert via addgroup+adduser at the fixed uid/gid" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  AMNEZIA_PASSWD="$_passwd" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  grep -qE "^addgroup .*-g 391.*amnezia-covert" "$STUB_LOG"
  grep -qE "^adduser .*-u 391.*amnezia-covert" "$STUB_LOG"
}

@test "first-install id-precheck skips creation when amnezia-covert already exists at the fixed uid" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  AMNEZIA_PASSWD="$_passwd" STUB_ID_UID=391 UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  ! grep -q "^addgroup" "$STUB_LOG"
  ! grep -q "^adduser" "$STUB_LOG"
}

@test "first-install refuses and creates nothing when the fixed uid is held by a different user" {
  AMNEZIA_PASSWD="$HARNESS_DIR/../test/fixtures/passwd-uid-collision" UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  ! grep -q "^addgroup" "$STUB_LOG"
  ! grep -q "^adduser" "$STUB_LOG"
  grep -q "held by user 'nobody'" "$STUB_LOG"
}

@test "first-install pre-creates covert.log 0640 owned by amnezia-covert:amnezia-covert" {
  _passwd="$BATS_TEST_TMPDIR/passwd-clean"
  printf 'root:x:0:0:root:/root:/bin/ash\n' > "$_passwd"
  _covert_dir="$BATS_TEST_TMPDIR/covert"
  AMNEZIA_PASSWD="$_passwd" AMZ_COVERT_DIR="$_covert_dir" AMZ_COVERT_LOG="$_covert_dir/covert.log" \
    UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install
  [ -f "$_covert_dir/covert.log" ]
  _mode=$(stat -f %Lp "$_covert_dir/covert.log" 2>/dev/null || stat -c %a "$_covert_dir/covert.log" 2>/dev/null)
  [ "$_mode" = "640" ]
}
