#!/usr/bin/env bats
# Phase 5 (covert-creator-router plan): amnezia-covert-run.sh, the procd
# instance command. Exercises the ordered contract (enabled guard, uid-match
# fail-closed, state/link truncation, the dedicated-timestamp call gap, the
# FIFO-captured dual-pid launch, and the concurrent readiness monitor)
# against a FAKE creator and a minimal PATH-shadowed amnezia-covert-logwrap.sh
# stub -- Phase 5 never requires Phase 4's real log wrapper (H2, sonnet-lens;
# mirrors the test/stubs/amnezia-*-init convention already used for
# AMNEZIA_DNSLEAK_INIT: default is the real absolute path, tests override the
# env var to a bare command name resolved off a scratch PATH entry).
load '../lib/harness.bash'
RUN_SH="$HARNESS_DIR/../openwrt/amnezia-covert-run.sh"
COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"

setup() {
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN_DIR"
  STATE="$RUN_DIR/state.json"

  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  export PATH="$BIN_DIR:$PATH"

  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export AMZ_COVERT_RUN_DIR="$RUN_DIR"
  export AMZ_COVERT_UID=6553
  export AMZ_COVERT_COOKIES="$BATS_TEST_TMPDIR/vk-cookies.json"
  : > "$AMZ_COVERT_COOKIES"

  # Real UCI is stubbed via harness.bash's PATH prepend of test/stubs/uci;
  # UCI_GET_<dotted_path_with_underscores> is that stub's read seam.
  export UCI_GET_amnezia_config_covert_enabled=1

  # A world-readable fragment with the numeric skuid substituted, matching
  # what `enable` installs -- default: matches AMZ_COVERT_UID.
  FRAGMENT="$BATS_TEST_TMPDIR/40-amnezia-covert-egress.nft"
  cat > "$FRAGMENT" <<EOF
chain amnezia_covert_egress {
    type filter hook output priority filter; policy accept;
    meta skuid $AMZ_COVERT_UID oifname "lo" ip  daddr 127.0.0.1 udp dport 53 accept
    meta skuid $AMZ_COVERT_UID oifname "eth0" reject
}
EOF
  export AMZ_COVERT_FRAGMENT="$FRAGMENT"

  # Fast defaults for the test suite; the launcher's real defaults (120s /
  # 30s) are untouched in production -- these are pure test seams.
  export AMZ_COVERT_CALL_GAP=0
  export AMZ_COVERT_READY_TIMEOUT=3

  # Minimal PATH-shadowed logwrap stub: reads marker lines off the FIFO and
  # writes the corresponding state.json, nothing else. Bare-name env value
  # (not an absolute path) so PATH resolution is what wires it in --
  # exactly what "PATH-shadowed" means for a launcher that otherwise
  # defaults to the real /usr/lib/amnezia/amnezia-covert-logwrap.sh.
  cat > "$BIN_DIR/amnezia-covert-logwrap.sh" <<'EOF'
#!/bin/sh
STATE="${AMZ_COVERT_RUN_DIR:-/var/run/amnezia-covert}/state.json"
while IFS= read -r line; do
  case "$line" in
    *"CALL CREATED"*) printf '{"state":"starting","link":null,"reason":""}\n' > "$STATE" ;;
    *"[vk-ws] Connected"*) printf '{"state":"connected","link":null,"reason":""}\n' > "$STATE" ;;
  esac
done
EOF
  chmod +x "$BIN_DIR/amnezia-covert-logwrap.sh"
  export AMZ_COVERT_LOGWRAP=amnezia-covert-logwrap.sh

  CREATOR_ARGS="$BATS_TEST_TMPDIR/creator-args"
  CREATOR_PIDFILE="$BATS_TEST_TMPDIR/creator-pid"
  export AMZ_COVERT_CREATOR_BIN="$BIN_DIR/amnezia-covert-creator"
}

teardown() {
  # Belt-and-braces: nothing from a failed assertion lingers.
  # shellcheck disable=SC2009
  for p in $(jobs -p 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  pkill -f "$AMZ_COVERT_CREATOR_BIN" 2>/dev/null || true
}

# A fake creator that records its own pid + the REAL argv the launcher
# built (so resources_flag_present inspects exactly what the launcher
# constructs, never a test-only flag), then behaves per
# $AMZ_FAKE_CREATOR_MODE:
#   connect  -- emit CALL CREATED then [vk-ws] Connected (with a short gap),
#               then exit 0.
#   hang     -- sleep 60s, never emitting a marker (readiness-timeout and
#               sigterm tests).
#   quick    -- exit 0 immediately (flag/gap-timing assertions).
_write_fake_creator() {
  cat > "$AMZ_COVERT_CREATOR_BIN" <<EOF
#!/bin/sh
echo \$\$ > "$CREATOR_PIDFILE"
printf '%s\n' "\$*" > "$CREATOR_ARGS"
case "\${AMZ_FAKE_CREATOR_MODE:-quick}" in
  connect)
    printf '  CALL CREATED\n'
    sleep 0.2
    printf '[vk-ws] Connected\n'
    sleep 0.2
    exit 0
    ;;
  hang)
    # exec, not a forked subshell: the real creator binary is a single
    # process (no children to leak); this must be too, or SIGTERM to the
    # shell's pid (which \$CREATOR_PIDFILE records and the launcher's
    # trap kills) leaves the forked sleep orphaned under pid 1, holding
    # bats' own output pipe open and hanging the whole suite.
    exec sleep 60
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$AMZ_COVERT_CREATOR_BIN"
}

# ---------------------------------------------------------------------------
@test "disabled_respawn_exits: covert_enabled=0 exits 0 without launching anything" {
  export UCI_GET_amnezia_config_covert_enabled=0
  _write_fake_creator
  run "$RUN_SH"
  [ "$status" -eq 0 ]
  [ ! -f "$CREATOR_ARGS" ]
}

# ---------------------------------------------------------------------------
@test "launcher_uid_mismatch_fail_closed: fragment skuid != current uid -> not-started/uid-mismatch, creator never exec'd" {
  # Fragment still restricts the OLD uid; amz_covert_uid now resolves to a
  # different one (e.g. post --migrate reallocation).
  export AMZ_COVERT_UID=9999
  _write_fake_creator
  run "$RUN_SH"
  [ "$status" -ne 0 ]
  [ ! -f "$CREATOR_ARGS" ]
  run cat "$STATE"
  [[ "$output" == *'"state":"not-started"'* ]]
  [[ "$output" == *'"reason":"uid-mismatch"'* ]]
}

@test "launcher_uid_mismatch_fail_closed: missing fragment also fails closed" {
  export AMZ_COVERT_FRAGMENT="$BATS_TEST_TMPDIR/does-not-exist.nft"
  _write_fake_creator
  run "$RUN_SH"
  [ "$status" -ne 0 ]
  [ ! -f "$CREATOR_ARGS" ]
  run cat "$STATE"
  [[ "$output" == *'"reason":"uid-mismatch"'* ]]
}

# ---------------------------------------------------------------------------
@test "fifo_lives_in_var_run: mkfifo target is under AMZ_COVERT_RUN_DIR, not a flash-style dir" {
  export AMZ_FAKE_CREATOR_MODE=quick
  _write_fake_creator
  run "$RUN_SH"
  [ -p "$RUN_DIR/covert.fifo" ]
}

# ---------------------------------------------------------------------------
@test "readiness_connected: fake creator reaches CALL CREATED + Connected, status ends connected" {
  export AMZ_FAKE_CREATOR_MODE=connect
  _write_fake_creator
  run "$RUN_SH"
  [ "$status" -eq 0 ]
  run cat "$STATE"
  [[ "$output" == *'"state":"connected"'* ]]
}

# ---------------------------------------------------------------------------
@test "readiness_timeout_not_started: fake creator never connects -> not-started, and it does not survive" {
  export AMZ_FAKE_CREATOR_MODE=hang
  _write_fake_creator
  run "$RUN_SH"
  [ "$status" -ne 0 ]
  run cat "$STATE"
  [[ "$output" == *'"state":"not-started"'* ]]
  [ -f "$CREATOR_PIDFILE" ]
  run kill -0 "$(cat "$CREATOR_PIDFILE")"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
@test "sigterm_no_orphan: SIGTERM to the launcher kills the fake creator via the trap" {
  export AMZ_FAKE_CREATOR_MODE=hang
  export AMZ_COVERT_READY_TIMEOUT=60
  _write_fake_creator

  "$RUN_SH" &
  LAUNCHER_PID=$!

  # Wait for the creator to actually be up before signaling.
  _tries=0
  while [ ! -f "$CREATOR_PIDFILE" ] && [ "$_tries" -lt 50 ]; do
    sleep 0.1
    _tries=$((_tries + 1))
  done
  [ -f "$CREATOR_PIDFILE" ]
  CPID="$(cat "$CREATOR_PIDFILE")"
  run kill -0 "$CPID"
  [ "$status" -eq 0 ]

  kill -TERM "$LAUNCHER_PID"
  wait "$LAUNCHER_PID" 2>/dev/null || true

  _tries=0
  while kill -0 "$CPID" 2>/dev/null && [ "$_tries" -lt 50 ]; do
    sleep 0.1
    _tries=$((_tries + 1))
  done
  run kill -0 "$CPID"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
@test "state_json_mode_0640: step-1 truncate + the timeout writer both leave state.json 0640" {
  export AMZ_FAKE_CREATOR_MODE=quick
  _write_fake_creator
  run "$RUN_SH"
  [ -f "$STATE" ]
  perm="$(stat -c %a "$STATE" 2>/dev/null || stat -f %Lp "$STATE" 2>/dev/null)"
  [ "$perm" = "640" ]
}

# ---------------------------------------------------------------------------
@test "resources_flag_present: the exec'd creator command line carries -resources moderate" {
  export AMZ_FAKE_CREATOR_MODE=quick
  _write_fake_creator
  run "$RUN_SH"
  [ -f "$CREATOR_ARGS" ]
  run cat "$CREATOR_ARGS"
  [[ "$output" == *"-resources moderate"* ]]
}

# ---------------------------------------------------------------------------
@test "call_gap_uses_dedicated_ts: a simulated respawn still waits out the remaining gap" {
  export AMZ_COVERT_CALL_GAP=3
  # last-call.ts stamped "now" -- a fresh respawn must wait ~3s before launch.
  date +%s > "$RUN_DIR/last-call.ts"
  export AMZ_FAKE_CREATOR_MODE=connect
  _write_fake_creator

  start_ts=$(date +%s)
  run "$RUN_SH"
  end_ts=$(date +%s)
  [ "$status" -eq 0 ]
  [ -f "$CREATOR_ARGS" ]
  elapsed=$((end_ts - start_ts))
  [ "$elapsed" -ge 2 ]
}

@test "call_gap_uses_dedicated_ts: state.json truncation in step 1 does not defeat the gap" {
  export AMZ_COVERT_CALL_GAP=3
  date +%s > "$RUN_DIR/last-call.ts"
  # A stale state.json from a previous generation must have zero bearing on
  # the gap calculation -- it gets truncated in step 1, before the gap is
  # even read.
  printf '{"state":"connected","link":null,"reason":""}\n' > "$STATE"
  export AMZ_FAKE_CREATOR_MODE=connect
  _write_fake_creator

  start_ts=$(date +%s)
  run "$RUN_SH"
  end_ts=$(date +%s)
  [ "$status" -eq 0 ]
  elapsed=$((end_ts - start_ts))
  [ "$elapsed" -ge 2 ]
}
