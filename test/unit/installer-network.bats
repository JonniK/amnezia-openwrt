#!/usr/bin/env bats
load '../lib/harness.bash'

@test "installer dry-run emits network+peer+v4-only allowed_ips for awg2" {
  run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-tunnel awg2 \
        --conf "$HARNESS_DIR/../test/fixtures/awg2.conf"
  echo "$output" > "$BATS_TEST_TMPDIR/o"
  diff "$HARNESS_DIR/../test/golden/network-awg2.uci" "$BATS_TEST_TMPDIR/o"
  ! grep -q "::/0" "$BATS_TEST_TMPDIR/o"
}
@test "gen_tunnel_uci emits full S/H/I obfuscation params (spaces in I-param preserved)" {
  run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-tunnel awg_full \
        --conf "$HARNESS_DIR/../test/fixtures/awg-full-params.conf"
  echo "$output" > "$BATS_TEST_TMPDIR/o"
  diff "$HARNESS_DIR/../test/golden/network-awg-full.uci" "$BATS_TEST_TMPDIR/o"
  # Explicitly assert the critical params are present with correct values.
  grep -q "awg_s1=0" "$BATS_TEST_TMPDIR/o"
  grep -q "awg_h1=1" "$BATS_TEST_TMPDIR/o"
  grep -q "awg_h4=4" "$BATS_TEST_TMPDIR/o"
  grep -q "awg_i1='<r 2><b 0xDEADBEEF>'" "$BATS_TEST_TMPDIR/o"
  grep -q "awg_i2='<c>'" "$BATS_TEST_TMPDIR/o"
  grep -q "awg_i3='<t>'" "$BATS_TEST_TMPDIR/o"
}
@test "real installer code path never emits ::/0 to uci stub" {
  # Run a minimal install (UCI_FAKE_TUNNELS=awg1, no actual system changes due to stubs).
  UCI_FAKE_TUNNELS="awg1" \
    sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --dry-run-all
  ! grep -q "::/0" "$STUB_LOG"
}
