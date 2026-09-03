#!/usr/bin/env bats
# Phase 4 (covert-creator-router plan): amnezia-covert-logwrap.sh.
# State machine from marker lines, GENERIC ", response:" redaction (the VK
# access_token / session_key must never reach covert.log -- nine upstream
# body-dump sites, incl. the self-healing rejoin path), and a truncate-in-
# place cap that works from the 0750 root:amnezia-covert flash dir the
# unprivileged wrapper cannot write into.
load '../lib/harness.bash'
WRAP="$HARNESS_DIR/../openwrt/amnezia-covert-logwrap.sh"

setup() {
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  LOG="$BATS_TEST_TMPDIR/covert.log"
  mkdir -p "$RUN_DIR"
  : > "$LOG"
  export AMZ_COVERT_RUN_DIR="$RUN_DIR"
  export AMZ_COVERT_LOG="$LOG"
  STATE="$RUN_DIR/state.json"
}

teardown() {
  # Belt-and-braces: kill any leftover backgrounded wrapper from a failed
  # assertion (mirrors covert-reap.bats).
  for p in $(jobs -p 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
}

_wait_for_state() {
  _want="$1"
  _tries=0
  while [ "$_tries" -lt 50 ]; do
    if [ -f "$STATE" ] && grep -q "\"state\":\"$_want\"" "$STATE"; then
      return 0
    fi
    _tries=$((_tries + 1))
    sleep 0.1
  done
  echo "timed out waiting for state=$_want; got: $(cat "$STATE" 2>/dev/null || echo '<missing>')" >&2
  return 1
}

# ---------------------------------------------------------------------------
@test "states_from_markers: a live marker stream transitions idle -> starting -> connected" {
  mkfifo "$RUN_DIR/covert.fifo"
  "$WRAP" < "$RUN_DIR/covert.fifo" &
  WPID=$!

  exec 9> "$RUN_DIR/covert.fifo"

  _wait_for_state idle

  printf '  CALL CREATED\n' >&9
  # >1s gap so the throttled flush (<=1 write/sec) is due, then a benign
  # chatter line (not a marker) is what actually triggers the periodic
  # check on the next loop iteration -- exactly like the real unconditional
  # "[vk-ws]" debug dumps that arrive every ~1s in production and drive the
  # same throttled-flush check.
  sleep 1.2
  printf '[vk-ws] <- notification chatter\n' >&9
  _wait_for_state starting

  sleep 1.2
  printf '[vk-ws] Connected\n' >&9
  _wait_for_state connected

  exec 9>&-
  wait "$WPID" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
@test "redacts_generic_response_tail: masks VK secrets on both the create-path and the rejoin-path body dump" {
  token="SECRETTOKEN123"
  session_key="SECRETSESSIONKEY456"
  printf 'Failed to create call: empty VK token, response: %s\n[rejoin] Failed: empty session_key, response: %s\n' \
    "$token" "$session_key" | "$WRAP"

  run cat "$LOG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$token"* ]]
  [[ "$output" != *"$session_key"* ]]
  # generic: both surfacing prefixes got masked, not just one enumerated shape.
  [[ "$output" == *"Failed to create call: empty VK token, response:***"* ]]
  [[ "$output" == *"[rejoin] Failed: empty session_key, response:***"* ]]
}

# ---------------------------------------------------------------------------
@test "redaction_keeps_state_prefix: auth-failed is still classified after masking" {
  token="SECRETTOKEN789"
  printf 'Failed to create call: empty VK token, response: %s\n' "$token" | "$WRAP"
  run grep -o '"state":"[^"]*"' "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = '"state":"auth-failed"' ]
}

# ---------------------------------------------------------------------------
@test "cap_is_truncate_in_place: caps a large covert.log inside a 0750-style dir without dir-write" {
  flash_dir="$BATS_TEST_TMPDIR/flash"
  mkdir -p "$flash_dir"
  export AMZ_COVERT_LOG="$flash_dir/covert.log"

  awk 'BEGIN{for(i=0;i<3000;i++) print "line " i}' > "$AMZ_COVERT_LOG"
  chmod 0640 "$AMZ_COVERT_LOG"

  if [ "$(id -u)" -eq 0 ]; then
    # Root (CI's `sudo bats`) bypasses DAC entirely against its own
    # restrictive chmod, so the permission boundary has to be enforced by
    # actually running as a real unprivileged user -- root can `su` to one
    # without a password, unlike a non-root dev shell.
    chown -R nobody "$flash_dir" "$RUN_DIR" 2>/dev/null || true
    chgrp -R nobody "$flash_dir" "$RUN_DIR" 2>/dev/null || chgrp -R nogroup "$flash_dir" "$RUN_DIR" 2>/dev/null || true
    chmod 0750 "$flash_dir"
    run su -s /bin/sh nobody -c "AMZ_COVERT_LOG='$AMZ_COVERT_LOG' AMZ_COVERT_RUN_DIR='$RUN_DIR' '$WRAP' --cap-once"
  else
    # Non-root dev host: strip OUR OWN write bit on the dir (we own it, so
    # this is a real, enforced DAC restriction against our own process).
    chmod u-w "$flash_dir"
    run "$WRAP" --cap-once
  fi

  [ "$status" -eq 0 ]
  chmod u+w "$flash_dir" 2>/dev/null || true
  run sh -c "wc -l < '$AMZ_COVERT_LOG'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2000 ]
  run sh -c "head -n1 '$AMZ_COVERT_LOG'"
  [ "$output" = "line 1000" ]
}

@test "cap_is_truncate_in_place: the FORBIDDEN blackbox tmp+mv pattern EACCESes in the same dir" {
  flash_dir="$BATS_TEST_TMPDIR/flash2"
  mkdir -p "$flash_dir"
  log="$flash_dir/covert.log"
  awk 'BEGIN{for(i=0;i<3000;i++) print "line " i}' > "$log"
  chmod 0640 "$log"

  if [ "$(id -u)" -eq 0 ]; then
    chown -R nobody "$flash_dir" 2>/dev/null || true
    chgrp -R nobody "$flash_dir" 2>/dev/null || chgrp -R nogroup "$flash_dir" 2>/dev/null || true
    chmod 0750 "$flash_dir"
    run su -s /bin/sh nobody -c "tail -n 2000 '$log' > '$log.tmp' && mv '$log.tmp' '$log'"
  else
    chmod u-w "$flash_dir"
    run sh -c "tail -n 2000 '$log' > '$log.tmp' && mv '$log.tmp' '$log'"
  fi

  chmod u+w "$flash_dir" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
@test "redact_multiline_body_suppresses_secret_until_next_marker: a newline inside the response body cannot smuggle a secret past redaction" {
  token="SECRETTOKEN999"
  printf 'Failed to create call: empty VK token, response: {\n  "access_token": "%s"\n}\n[vk-ws] <- notification chatter\n' \
    "$token" | "$WRAP"

  # NOTE: `run` + explicit status check, never a bare `! cmd` that isn't the
  # test's LAST statement -- bash's `set -e` does not fire on a `!`-negated
  # command's failure, so a non-final `! grep ...` silently swallows a red
  # assertion (verified against this exact test while mutation-testing H2).
  run grep -qF "$token" "$LOG"
  [ "$status" -ne 0 ]
  run grep -qF "Failed to create call: empty VK token, response:***" "$LOG"
  [ "$status" -eq 0 ]
  # Continuation lines are wholesale-masked, never written raw.
  run grep -qF '***' "$LOG"
  [ "$status" -eq 0 ]
  run grep -q '"access_token"' "$LOG"
  [ "$status" -ne 0 ]

  run grep -o '"state":"[^"]*"' "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = '"state":"auth-failed"' ]
}

@test "state_json_mode_0640: state.json is written 0640, never the umask-default 0644" {
  printf '  CALL CREATED\n' | "$WRAP"
  perm="$(stat -c %a "$STATE" 2>/dev/null || stat -f %Lp "$STATE" 2>/dev/null)"
  [ "$perm" = "640" ]
}

# ---------------------------------------------------------------------------
@test "no_terminal_downgrade: a buffered CALL CREATED does not flip a not-started state back to starting" {
  printf '{"state":"not-started","link":null,"reason":"readiness-timeout"}\n' > "$STATE"
  printf '  CALL CREATED\n' | "$WRAP"
  run grep -o '"state":"[^"]*"' "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = '"state":"not-started"' ]
}

@test "no_terminal_downgrade: a crashed state is likewise protected" {
  printf '{"state":"crashed","link":null,"reason":"respawn-exhausted"}\n' > "$STATE"
  printf '[vk-ws] Connected\n' | "$WRAP"
  run grep -o '"state":"[^"]*"' "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = '"state":"crashed"' ]
}
