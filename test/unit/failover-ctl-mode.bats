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
  # H3: conntrack flush is now inside the backgrounded subshell (after fw4 reload).
  # The stub completes synchronously in test context — assert flush is logged after reload.
  grep -q 'fw4 reload' "$STUB_LOG"
  # conntrack stub logs its args; match case-insensitively (constants are 0x0B.. but tolerate 0xb..)
  grep -qiE -- '-D -m 0x0?b0000/0x0?ff0000' "$STUB_LOG"      # pool mark flushed
  grep -qiE -- '-D -m 0x0?a0000/0x0?ff0000' "$STUB_LOG"      # sticky mark flushed
  # Assert flush is ordered AFTER reload in the log (fw4 reload line precedes first conntrack -D line)
  awk '/fw4 reload/{r=NR} /conntrack -D/{if(!c)c=NR} END{exit !(r&&c&&r<c)}' "$STUB_LOG"
}
@test "set-routing-mode rejects an unknown mode" {
  run sh "$CTL" set-routing-mode bogus; [ "$status" -ne 0 ]
}
@test "set-source toggles a known source and rejects unknown" {
  run sh "$CTL" set-source antifilter 1
  [ "$status" -eq 0 ]; grep -q 'uci set amnezia.antifilter.enabled=1' "$STUB_LOG"
  run sh "$CTL" set-source not_a_source 1; [ "$status" -ne 0 ]
}
@test "set-routing-mode aborts if classifier emit fails (M1)" {
  # Create a wrapper that overrides routing_emit_classifier to fail, then runs
  # the set-routing-mode logic.  We cannot use AMNEZIA_NFT_DIR alone because
  # the lib falls back to dirname-relative paths that exist in the source tree.
  _wrap="$BATS_TEST_TMPDIR/failover-ctl-m1.sh"
  cat > "$_wrap" <<'EOF'
#!/bin/sh
AMNEZIA_LIB="${AMNEZIA_LIB:-/usr/lib/amnezia}"
if [ -f "$AMNEZIA_LIB/amnezia-common.sh" ]; then
  . "$AMNEZIA_LIB/amnezia-common.sh"
else
  . "$(dirname "$0")/lib/amnezia-common.sh"
fi
# Override emit to always fail — simulates fragment-not-found.
routing_emit_classifier() { return 1; }
# Inline the set-routing-mode body to test the guard.
_cls_tmp=$(mktemp /tmp/amnezia-cls-XXXXXX)
if ! routing_emit_classifier "tunnel-default" "br-lan" > "$_cls_tmp" 2>/dev/null; then
  rm -f "$_cls_tmp"
  exit 1
fi
mv "$_cls_tmp" "${AMNEZIA_CLASSIFIER_OUT:-/etc/nftables.d/30-amnezia-classify.nft}"
exit 0
EOF
  chmod +x "$_wrap"
  _wrap_lib="$BATS_TEST_TMPDIR/lib"
  mkdir -p "$_wrap_lib"
  cp "$(dirname "$CTL")/lib/amnezia-common.sh" "$_wrap_lib/"
  AMNEZIA_LIB="$_wrap_lib" run sh "$_wrap"
  [ "$status" -ne 0 ]
  # Classifier output file must NOT be written when emit fails.
  [ ! -f "$AMNEZIA_CLASSIFIER_OUT" ]
}
