#!/usr/bin/env bats
# Phase 7 (covert-creator-router plan): openwrt/amnezia-covert.init.
#
# There is no functional procd harness in this repo (procd itself doesn't
# run off-device), so per the plan's Phase 7 assertion table these are
# static/structural grep checks over the init file text -- the real
# functional gate (no instance opens under a failing `apply`, reboot with a
# mismatched uid) is the live router smoke-test, not bats.
load '../lib/harness.bash'
INIT_FILE="$HARNESS_DIR/../openwrt/amnezia-covert.init"

@test "init_no_stdout_stderr: the init does not route stdout/stderr to logd" {
  run grep -E 'procd_set_param[[:space:]]+(stdout|stderr)' "$INIT_FILE"
  [ "$status" -ne 0 ]
}

@test "init_start_guarded: start_service calls amz_covert_enabled and returns on false" {
  run grep -E 'amz_covert_enabled[[:space:]]*\|\|[[:space:]]*return[[:space:]]+0' "$INIT_FILE"
  [ "$status" -eq 0 ]
}

@test "init_creates_runtime_dir_owned: start_service mkdir+chowns /var/run/amnezia-covert/ to amnezia-covert" {
  run grep -E 'mkdir[[:space:]].*-p.*/var/run/amnezia-covert' "$INIT_FILE"
  [ "$status" -eq 0 ]
  run grep -E 'chown[[:space:]]+amnezia-covert:amnezia-covert[[:space:]]+/var/run/amnezia-covert' "$INIT_FILE"
  [ "$status" -eq 0 ]
}

@test "init_restricts_runtime_dir_mode: start_service chmods /var/run/amnezia-covert to 0750, never world-traversable" {
  # Static/structural check like its siblings above (no functional procd
  # harness off-device) -- the run dir holds logcap (join-link-bearing log
  # copy) and covert.fifo (pre-redaction raw creator stream), so a 0755 dir
  # would leave both world-readable regardless of their own file modes.
  run grep -E 'chmod[[:space:]]+0750[[:space:]]+/var/run/amnezia-covert' "$INIT_FILE"
  [ "$status" -eq 0 ]
}

@test "init_calls_apply_reconcile: start_service calls amnezia-covert-ctl apply" {
  run grep -E 'amnezia-covert-ctl[[:space:]]+apply' "$INIT_FILE"
  [ "$status" -eq 0 ]
}

@test "init_gates_instance_on_apply: the apply call carries an explicit || return 1 on the same line" {
  run grep -E 'amnezia-covert-ctl[[:space:]]+apply[[:space:]]*\|\|[[:space:]]*return[[:space:]]+1' "$INIT_FILE"
  [ "$status" -eq 0 ]
}
