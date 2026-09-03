#!/usr/bin/env bats
# Phase 9 (covert-creator-router plan): openwrt/install-amnezia-pbr.sh
# --uninstall reverse-order teardown (design "Uninstall/rollback").
load '../lib/harness.bash'

@test "uninstall_reverses: disable runs before init removal, deluser/delgroup run LAST" {
  AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]

  # amnezia-covert-ctl disable must have run (routed through the stub init:
  # cmd_disable calls "$AMNEZIA_COVERT_INIT" stop/disable).
  grep -q "amnezia-covert-init stop" "$STUB_LOG"
  grep -q "amnezia-covert-init disable" "$STUB_LOG"
  grep -q "uninstall:init-removed" "$STUB_LOG"
  grep -q "uninstall:deluser" "$STUB_LOG"
  grep -q "uninstall:delgroup" "$STUB_LOG"

  # Ordering: the ctl's own "disable" (via the init stub) precedes the
  # installer's own init-file removal, which precedes deluser, which
  # precedes delgroup.
  _l_disable=$(grep -n "amnezia-covert-init disable" "$STUB_LOG" | head -n1 | cut -d: -f1)
  _l_init_removed=$(grep -n "uninstall:init-removed" "$STUB_LOG" | head -n1 | cut -d: -f1)
  _l_deluser=$(grep -n "uninstall:deluser" "$STUB_LOG" | head -n1 | cut -d: -f1)
  _l_delgroup=$(grep -n "uninstall:delgroup" "$STUB_LOG" | head -n1 | cut -d: -f1)

  [ "$_l_disable" -lt "$_l_init_removed" ]
  [ "$_l_init_removed" -lt "$_l_deluser" ]
  [ "$_l_deluser" -lt "$_l_delgroup" ]
}

@test "uninstall is idempotent when nothing was ever installed" {
  AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]
  # A second run must also succeed cleanly (absent -> skip, never error).
  AMNEZIA_COVERT_INIT=amnezia-covert-init \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall
  [ "$status" -eq 0 ]
}

@test "uninstall --dry-run emits the ordered step markers without side effects" {
  run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "uninstall:disable"
  echo "$output" | grep -q "uninstall:deluser"
  echo "$output" | grep -q "uninstall:delgroup"
}
