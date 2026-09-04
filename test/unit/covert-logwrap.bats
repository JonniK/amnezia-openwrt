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
  # Markers arriving spread out over time, with unrelated chatter in
  # between. NOTE: this spacing is NOT what production looks like -- the
  # real creator emits every marker inside one second and then goes silent
  # (see burst_then_silence below, the shape that actually shipped a bug).
  # Kept as the slow-drip counterpart: each marker must still land on its
  # own, without the next line being what flushes it.
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
  # Both lines carry the real upstream Go-log timestamp prefix (verified
  # against headless/vk/main.go: every "Failed"/"[rejoin]" surfacing line is
  # logged via log.Printf/log.Fatalf, never fmt.Print*) -- that timestamp is
  # the only anchor the wrapper now trusts to end multi-line body
  # suppression, so the second line's own timestamp is what correctly ends
  # the first line's (single-line, here) body suppression.
  printf '2026/01/01 00:00:00 Failed to create call: empty VK token, response: %s\n2026/01/01 00:00:01 [rejoin] Failed: empty session_key, response: %s\n' \
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

@test "logcap_mode_0640: logcap (a full copy of the join-link-bearing log) is chmodded 0640, never umask-default 0644" {
  awk 'BEGIN{for(i=0;i<10;i++) print "line " i}' > "$LOG"
  run "$WRAP" --cap-once
  [ "$status" -eq 0 ]
  [ -f "$RUN_DIR/logcap" ]
  perm="$(stat -c %a "$RUN_DIR/logcap" 2>/dev/null || stat -f %Lp "$RUN_DIR/logcap" 2>/dev/null)"
  [ "$perm" = "640" ]
}

@test "cap_log_never_truncates_on_run_dir_write_failure: a run-dir write failure preserves covert.log instead of truncating it to an empty logcap" {
  awk 'BEGIN{for(i=0;i<10;i++) print "line " i}' > "$LOG"
  ORIGINAL="$(cat "$LOG")"

  if [ "$(id -u)" -eq 0 ]; then
    # Root bypasses DAC against its own chmod -- enforce the boundary as a
    # real unprivileged user, same pattern as cap_is_truncate_in_place.
    chown -R nobody "$RUN_DIR" 2>/dev/null || true
    chgrp -R nobody "$RUN_DIR" 2>/dev/null || chgrp -R nogroup "$RUN_DIR" 2>/dev/null || true
    chmod 0500 "$RUN_DIR"
    run su -s /bin/sh nobody -c "AMZ_COVERT_LOG='$LOG' AMZ_COVERT_RUN_DIR='$RUN_DIR' '$WRAP' --cap-once"
  else
    # Non-root dev host: strip our own write bit on the run dir so `tail ...
    # > $RUN_DIR/logcap` cannot create the file -- a real, enforced DAC
    # restriction against our own process (mirrors cap_is_truncate_in_place).
    chmod u-w "$RUN_DIR"
    run "$WRAP" --cap-once
  fi

  chmod u+w "$RUN_DIR" 2>/dev/null || true

  # tail's redirect failed -> the whole `&&` chain must short-circuit before
  # the final `cat "$RUN_DIR/logcap" > "$LOG"` -- covert.log must be
  # UNCHANGED, never truncated to an empty/missing logcap.
  [ "$status" -ne 0 ]
  NEW="$(cat "$LOG")"
  [ "$NEW" = "$ORIGINAL" ]
}

@test "run_dir_mode_0750: the run dir the wrapper creates is not world-traversable" {
  rm -rf "$RUN_DIR"
  printf '  CALL CREATED\n' | "$WRAP"
  [ -d "$RUN_DIR" ]
  perm="$(stat -c %a "$RUN_DIR" 2>/dev/null || stat -f %Lp "$RUN_DIR" 2>/dev/null)"
  [ "$perm" = "750" ]
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

# ---------------------------------------------------------------------------
@test "redact_multiline_body_boundary_is_anchored: a body line merely CONTAINING Cannot/Failed/[vk-ws] does not end suppression early" {
  token="SECRETTOKEN777"
  # The body itself carries an embedded "Cannot" and mimics a VK JSON error
  # shape -- with the old UNANCHORED *"Cannot"* marker this line alone ends
  # IN_BODY mode and the access_token line right after it leaks raw.
  printf 'Failed to create call: empty VK token, response: {\n  "error_msg": "Cannot refresh session",\n  "access_token": "%s"\n}\n' \
    "$token" | "$WRAP"

  run grep -qF "$token" "$LOG"
  [ "$status" -ne 0 ]
  run grep -qF "Failed to create call: empty VK token, response:***" "$LOG"
  [ "$status" -eq 0 ]
  run grep -q '"access_token"' "$LOG"
  [ "$status" -ne 0 ]
  # The mid-body "Cannot" line and the closing brace must both be
  # wholesale-masked, not passed through raw.
  run grep -qF 'error_msg' "$LOG"
  [ "$status" -ne 0 ]

  # State classification off the first (unredacted, pre-body) line is
  # unaffected by the anchoring fix.
  run grep -o '"state":"[^"]*"' "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = '"state":"auth-failed"' ]
}

@test "redact_multiline_body_boundary_is_anchored: mid-line join_link substring does not end suppression early" {
  token="SECRETTOKEN888"
  # "  join_link: " only ends suppression when it is the line's own start --
  # embedded mid-line (e.g. quoted inside a JSON error body) it must not.
  printf 'Failed to create call: empty VK token, response: {\n  "hint": "see   join_link: below",\n  "access_token": "%s"\n}\n' \
    "$token" | "$WRAP"

  run grep -qF "$token" "$LOG"
  [ "$status" -ne 0 ]
  run grep -q '"access_token"' "$LOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Regression (live router 2026-09-04): the real creator emits its ENTIRE
# startup burst -- "CALL CREATED", join_link, "[vk-ws] Connected" and the
# post-connect notifications -- inside a single wall-clock second, and then
# goes SILENT waiting for a joiner. It does not chatter every ~1s. With a
# throttled flush that is only ever retried on the next input line, the
# "connected" write stayed pending forever, state.json was left at
# "starting" (or even "idle"), and amnezia-covert-run.sh's readiness monitor
# killed a perfectly healthy creator at its 30s timeout -- procd then
# respawned until it gave up, surfacing as state "not-started" /
# reason "readiness-timeout" in the LuCI panel.
@test "burst_then_silence: a same-second burst reaches connected with no further input" {
  mkfifo "$RUN_DIR/covert.fifo"
  "$WRAP" < "$RUN_DIR/covert.fifo" &
  WPID=$!

  # fd 9 stays OPEN for the whole test: the creator is still running, just
  # quiet. EOF must not be what finally flushes the state.
  exec 9> "$RUN_DIR/covert.fifo"

  _wait_for_state idle

  # One uninterrupted burst, no sleeps between lines -- exactly the shape
  # captured from the router's covert.log.
  {
    printf '2026/09/04 16:52:07 [auth] Joining conversation...\n'
    printf '  CALL CREATED\n'
    printf '  join_link: https://vk.ru/call/join/TESTLINK\n'
    printf '2026/09/04 16:52:08 [relay] PC created (2 ICE servers)\n'
    printf '2026/09/04 16:52:08 [vk-ws] Connecting...\n'
    printf '[vk-ws] Connected\n'
    printf '2026/09/04 16:52:08 [vk-ws] -> change-media-settings\n'
    printf '2026/09/04 16:52:08 [vk-ws] <- response seq=1: {"x":1}\n'
  } >&9

  _wait_for_state connected
  run grep -o '"link":"[^"]*"' "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = '"link":"https://vk.ru/call/join/TESTLINK"' ]

  exec 9>&-
  wait "$WPID" 2>/dev/null || true
}
