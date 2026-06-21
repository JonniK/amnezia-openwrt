#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-update.sh"
setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export UCI_FAKE_SOURCES="itdoginfo_inside:1 itdoginfo_services:1 antifilter:0"
  export AMNEZIA_FORCE_LOAD="amnezia-force-load"   # PATH shim from P0 logs to $STUB_LOG
}

@test "update fetches only enabled sources" {
  run sh "$SCRIPT"
  grep -q 'itdoginfo_inside' "$STUB_LOG"            # fetch stub logs the source/url
  # antifilter is disabled (enabled=0); verify no fetch (wget/curl) was attempted for it.
  # uci calls for antifilter.enabled ARE logged (to determine it is disabled) — only
  # fetch attempts must be absent.
  run grep -q 'wget.*antifilter\|curl.*antifilter' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "a failed fetch keeps the previous cache and marks status failed" {
  printf 'OLD\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  FETCH_FAIL=1 run sh "$SCRIPT"
  grep -q OLD "$FORCE_DIR/force.d/itdoginfo_inside.list"     # not clobbered
  grep -q '"status":"failed"' "$FORCE_DIR/force-update.json"
}

@test "update writes a stamp and calls force-load" {
  run sh "$SCRIPT"
  grep -q '"ts"' "$FORCE_DIR/force-update.json"
  grep -q 'amnezia-force-load' "$STUB_LOG"
}

# Regression: real OpenWrt uci show quotes option values ('1', not 1).
# The old grep+sed extraction kept the quotes so _enabled became "'1'" and the
# comparison [ "$_enabled" = "1" ] was FALSE — every enabled source was skipped.
# This test drives force-update with the stub emitting quoted values (as real uci does)
# and asserts the source is enumerated and its cache is written.
@test "regression: uci show quoted values (enabled='1') do not skip enabled sources" {
  # UCI_FAKE_SOURCES is already set in setup; the stub now emits quoted option values
  # (amnezia.itdoginfo_inside.enabled='1') to match real OpenWrt uci show behaviour.
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # Cache file must have been written (source was enumerated and fetch succeeded).
  [ -f "$FORCE_DIR/force.d/itdoginfo_inside.list" ] || \
    { echo "cache not written — source was skipped"; false; }
  # Stamp must record the source as ok.
  grep -q '"itdoginfo_inside"' "$FORCE_DIR/force-update.json"
  grep -q '"status":"ok"' "$FORCE_DIR/force-update.json"
}

# H1: a fetch returning HTML/404 garbage must not overwrite the prior cache.
@test "H1: HTML/garbage fetch body leaves prior cache intact and marks failed" {
  # Plant prior cache that should survive.
  printf 'old.example\nkeep.example\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  # FETCH_GARBAGE=1 makes the wget stub write an HTML 404 body.
  FETCH_GARBAGE=1 run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # Cache must be the original content, not the HTML body.
  grep -q 'old.example' "$FORCE_DIR/force.d/itdoginfo_inside.list"
  run grep -q 'DOCTYPE' "$FORCE_DIR/force.d/itdoginfo_inside.list"
  [ "$status" -ne 0 ] || { echo "HTML body overwrote cache"; false; }
  # Stamp must record failed status.
  grep -q '"status":"failed"' "$FORCE_DIR/force-update.json"
}
