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
  run grep -q 'antifilter' "$STUB_LOG"; [ "$status" -ne 0 ]
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
