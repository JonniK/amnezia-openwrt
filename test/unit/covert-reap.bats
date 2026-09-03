#!/usr/bin/env bats
# Phase 2 (covert-creator-router plan): amz_covert_uid / amz_covert_enabled /
# amz_covert_reap. Real target has NO pkill/pgrep -u/ps -o (BusyBox) and no
# /proc on the macOS dev host running these bats, so the reap is exercised
# against a fabricated /proc fixture (AMZ_PROC_DIR override) driving real
# `kill` on real spawned `sleep` subprocesses — the deaths are real, only the
# uid-lookup filesystem is faked.
load '../lib/harness.bash'
COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"

setup() {
  # AMZ_COVERT_UID is a test seam: when set it short-circuits `id -u
  # amnezia-covert` (that user does not exist on the dev host / CI runner).
  export AMZ_COVERT_UID=6553
  export AMZ_PROC_DIR="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$AMZ_PROC_DIR"
}

teardown() {
  # Belt-and-braces: make sure no leaked sleep from a failed assertion lingers.
  # shellcheck disable=SC2009
  for p in $(jobs -p 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
}

# Write a fake /proc/<pid>/status with a real-uid column of $2 (as real
# /proc/<pid>/status renders it: "Uid:\t<real>\t<eff>\t<saved>\t<fs>").
_fake_proc_entry() {
  _pid="$1"; _uid="$2"
  mkdir -p "$AMZ_PROC_DIR/$_pid"
  printf 'Name:\tsleep\nUid:\t%s\t%s\t%s\t%s\n' "$_uid" "$_uid" "$_uid" "$_uid" \
    > "$AMZ_PROC_DIR/$_pid/status"
}

@test "reap_kills_matching_uid: a process whose fake /proc uid matches amz_covert_uid is killed" {
  sleep 60 &
  pid=$!
  _fake_proc_entry "$pid" "$AMZ_COVERT_UID"
  run sh -c ". '$COMMON'; amz_covert_reap TERM"
  [ "$status" -eq 0 ]
  # Give the signal a moment to land.
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}

@test "reap_uses_proc_not_pkill: reap still kills the target with pkill absent/poisoned on PATH" {
  sleep 60 &
  pid=$!
  _fake_proc_entry "$pid" "$AMZ_COVERT_UID"

  poison_dir="$BATS_TEST_TMPDIR/poisonbin"
  mkdir -p "$poison_dir"
  marker="$BATS_TEST_TMPDIR/pkill-called"
  cat > "$poison_dir/pkill" <<EOF
#!/bin/sh
touch "$marker"
exit 127
EOF
  chmod +x "$poison_dir/pkill"

  run sh -c "PATH='$poison_dir:$PATH'; export PATH; . '$COMMON'; amz_covert_reap TERM"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]

  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}

@test "reap_ignores_other_uids: a fake /proc process under a different uid survives the reap" {
  sleep 60 &
  pid=$!
  _fake_proc_entry "$pid" "$((AMZ_COVERT_UID + 1))"
  run sh -c ". '$COMMON'; amz_covert_reap TERM"
  [ "$status" -eq 0 ]
  sleep 0.3
  run kill -0 "$pid"
  [ "$status" -eq 0 ]
  kill -KILL "$pid" 2>/dev/null
}

@test "enabled_reads_uci_get: true when uci -q get (unquoted) returns 1" {
  export UCI_GET_amnezia_config_covert_enabled=1
  run sh -c ". '$COMMON'; amz_covert_enabled"
  [ "$status" -eq 0 ]
}

@test "enabled_reads_uci_get: false when uci -q get returns 0" {
  export UCI_GET_amnezia_config_covert_enabled=0
  run sh -c ". '$COMMON'; amz_covert_enabled"
  [ "$status" -ne 0 ]
}

@test "enabled_reads_uci_get: a quoted uci-show-style value alone (no -q get) does NOT enable" {
  # Real `uci show` renders amnezia.config.covert_enabled='1' (quoted). A
  # `uci show | grep | sed`-style parse that forgets to strip quotes, or that
  # reads the show output instead of `-q get`, must NOT read this as enabled.
  unset UCI_GET_amnezia_config_covert_enabled
  export UCI_SHOW_amnezia_config="amnezia.config.covert_enabled='1'"
  run sh -c ". '$COMMON'; amz_covert_enabled"
  [ "$status" -ne 0 ]
}
