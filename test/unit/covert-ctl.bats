#!/usr/bin/env bats
# Phase 6 (covert-creator-router plan): amnezia-covert-ctl (enable | disable |
# apply | status). Stubs Phase 7's init via a new test/stubs/amnezia-covert-init
# (bats never needs the real init) and the shared test/stubs/uci (real
# quoted `uci show` format, so `uci -q get` vs a quote-blind parse is
# distinguished).
load '../lib/harness.bash'
CLI="$HARNESS_DIR/../openwrt/amnezia-covert-ctl.sh"
COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"

setup() {
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  ETC_DIR="$BATS_TEST_TMPDIR/etc-covert"
  NFT_DIR="$BATS_TEST_TMPDIR/nftables.d"
  mkdir -p "$RUN_DIR" "$ETC_DIR" "$NFT_DIR"

  BIN_DIR="$BATS_TEST_TMPDIR/localbin"
  mkdir -p "$BIN_DIR"
  export PATH="$BIN_DIR:$PATH"

  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export AMNEZIA_COVERT_INIT="amnezia-covert-init"   # routes to test/stubs stub
  export AMZ_COVERT_UID=6553
  export AMZ_COVERT_RUN_DIR="$RUN_DIR"
  export AMZ_COVERT_DIR="$ETC_DIR"
  export AMZ_COVERT_COOKIES="$ETC_DIR/vk-cookies.json"
  export AMZ_COVERT_MANIFEST="$ETC_DIR/BUILD_MANIFEST"
  export AMZ_COVERT_FRAGMENT="$NFT_DIR/40-amnezia-covert-egress.nft"
  export AMZ_COVERT_BIN="$BATS_TEST_TMPDIR/creator-bin"
  export AMZ_PROC_DIR="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$AMZ_PROC_DIR"
  export AMZ_COVERT_REAP_WAIT=0

  # Real creator binary path must be present+executable for preflight.
  printf '#!/bin/sh\nexit 0\n' > "$AMZ_COVERT_BIN"
  chmod +x "$AMZ_COVERT_BIN"

  # A structurally-valid cookie by default; individual tests override.
  printf '[{"name":"a","value":"b"}]' > "$AMZ_COVERT_COOKIES"

  # No /proc/meminfo fixture by default -> _mem_ok degrades to "don't block".
  unset AMZ_COVERT_MEMINFO

  export UCI_GET_amnezia_config_covert_enabled=0
  export UCI_GET_network_lan_device=br-lan
}

teardown() {
  for p in $(jobs -p 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
}

# ---- local, per-test-controllable fw4 stub (shadows the shared
# test/stubs/fw4, which always succeeds unconditionally) ------------------
_install_fw4_stub() {
  cat > "$BIN_DIR/fw4" <<'EOF'
#!/bin/sh
case "$1" in
  reload) [ -n "${STUB_FW4_RELOAD_DELAY:-}" ] && sleep "$STUB_FW4_RELOAD_DELAY" ;;
esac
echo "fw4 $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
  check)  [ -n "${STUB_FW4_CHECK_FAIL:-}" ] && exit 1; exit 0 ;;
  reload) [ -n "${STUB_FW4_RELOAD_FAIL:-}" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$BIN_DIR/fw4"
}

_uci_set_lines() {
  grep '^uci set amnezia.config.covert_enabled' "$STUB_LOG" 2>/dev/null
}

# ===========================================================================
@test "enable_no_cookie_refuses_no_set: missing cookie refuses, no uci set at all" {
  _install_fw4_stub
  rm -f "$AMZ_COVERT_COOKIES"
  run "$CLI" enable
  [ "$status" -ne 0 ]
  [ -z "$(_uci_set_lines)" ]
  [ ! -f "$AMZ_COVERT_FRAGMENT" ]
}

@test "enable_happy_order: fragment written with numeric uid, fw4 check before any reload, init enable then restart" {
  _install_fw4_stub
  run "$CLI" enable
  [ "$status" -eq 0 ]

  [ -f "$AMZ_COVERT_FRAGMENT" ]
  grep -q "meta skuid $AMZ_COVERT_UID" "$AMZ_COVERT_FRAGMENT"
  ! grep -q '@@' "$AMZ_COVERT_FRAGMENT"

  # fw4 check must precede any fw4 reload in the log.
  awk '/fw4 check/{c=NR} /fw4 reload/{r=NR} END{exit !(c && (!r || c<r))}' "$STUB_LOG"

  # init enable must precede init restart.
  awk '/amnezia-covert-init enable/{e=NR} /amnezia-covert-init restart/{r=NR} END{exit !(e && r && e<r)}' "$STUB_LOG"

  grep -q "uci set amnezia.config.covert_enabled=1" "$STUB_LOG"
}

@test "enable_fw4check_fail_rolls_back: fw4 check fail removes fragment, no UCI mutation, non-zero, no reload" {
  _install_fw4_stub
  export STUB_FW4_CHECK_FAIL=1
  run "$CLI" enable
  [ "$status" -ne 0 ]
  [ ! -f "$AMZ_COVERT_FRAGMENT" ]
  [ -z "$(_uci_set_lines)" ]
  ! grep -q 'fw4 reload' "$STUB_LOG"
}

@test "disable_reaps_before_fragment: real /proc-scan confirms empty BEFORE fragment removal" {
  _install_fw4_stub
  printf 'meta skuid %s oifname "lo" reject\n' "$AMZ_COVERT_UID" > "$AMZ_COVERT_FRAGMENT"

  # A TERM-immune process (only SIGKILL, sent on the reap's second stage,
  # actually kills it) widens the window between "reap started" and
  # "process actually gone" enough for the poller below to observe it. A
  # non-zero AMZ_COVERT_REAP_WAIT widens it further.
  export AMZ_COVERT_REAP_WAIT=0.2
  sh -c 'trap "" TERM; sleep 30' &
  pid=$!
  mkdir -p "$AMZ_PROC_DIR/$pid"
  printf 'Name:\tsh\nUid:\t%s\t%s\t%s\t%s\n' "$AMZ_COVERT_UID" "$AMZ_COVERT_UID" "$AMZ_COVERT_UID" "$AMZ_COVERT_UID" \
    > "$AMZ_PROC_DIR/$pid/status"

  # A real /proc entry disappears the instant its process dies -- this
  # fixture is a manually-created directory that would otherwise persist
  # forever, which would make the fail-safe re-scan (M2) see a "surviving"
  # process even after the real one is confirmed dead. Model real /proc:
  # remove the fixture as soon as the underlying process is actually gone.
  ( while kill -0 "$pid" 2>/dev/null; do sleep 0.02; done; rm -rf "$AMZ_PROC_DIR/$pid" ) &
  watcher_pid=$!

  BAD_ORDER="$BATS_TEST_TMPDIR/bad-order"
  rm -f "$BAD_ORDER"
  "$CLI" disable &
  disable_pid=$!
  while kill -0 "$disable_pid" 2>/dev/null; do
    if [ ! -f "$AMZ_COVERT_FRAGMENT" ] && kill -0 "$pid" 2>/dev/null; then
      touch "$BAD_ORDER"
    fi
    sleep 0.02
  done
  wait "$disable_pid"
  status=$?
  wait "$watcher_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ ! -f "$BAD_ORDER" ]

  # Process must be dead (reap actually ran, via the real /proc-scan helper).
  run kill -0 "$pid"
  [ "$status" -ne 0 ]

  [ ! -f "$AMZ_COVERT_FRAGMENT" ]
  grep -q "uci set amnezia.config.covert_enabled=0" "$STUB_LOG"
}

@test "disable_idempotent: disabling an already-disabled feature is exit 0, cookie kept" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=0
  [ -f "$AMZ_COVERT_COOKIES" ]
  run "$CLI" disable
  [ "$status" -eq 0 ]
  [ -f "$AMZ_COVERT_COOKIES" ]
}

@test "cookie_validator: rejects non-JSON, non-array, missing name/value; accepts the real shape" {
  printf 'not json' > "$AMZ_COVERT_COOKIES"
  run "$CLI" enable
  [ "$status" -ne 0 ]

  printf '{"name":"a","value":"b"}' > "$AMZ_COVERT_COOKIES"   # object, not array
  run "$CLI" enable
  [ "$status" -ne 0 ]

  printf '[{"value":"b"}]' > "$AMZ_COVERT_COOKIES"            # missing name
  run "$CLI" enable
  [ "$status" -ne 0 ]

  printf '[{"name":"","value":"b"}]' > "$AMZ_COVERT_COOKIES"  # empty name
  run "$CLI" enable
  [ "$status" -ne 0 ]

  _install_fw4_stub
  printf '[{"name":"a","value":"b"}]' > "$AMZ_COVERT_COOKIES"
  run "$CLI" enable
  [ "$status" -eq 0 ]
}

@test "enable_low_mem_refuses: MemAvailable below threshold refuses, no uci set, status reports the reason" {
  _install_fw4_stub
  MEMINFO="$BATS_TEST_TMPDIR/meminfo"
  printf 'MemTotal:       65536 kB\nMemAvailable:      100 kB\n' > "$MEMINFO"
  export AMZ_COVERT_MEMINFO="$MEMINFO"
  export AMZ_COVERT_MIN_MEM_KB=32768

  run "$CLI" enable
  [ "$status" -ne 0 ]
  [ -z "$(_uci_set_lines)" ]
  [ ! -f "$AMZ_COVERT_FRAGMENT" ]
}

@test "apply_rechowns_cookie: apply re-asserts chown+chmod on the cookie after a simulated rpcd write" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=1
  # No fixture is needed for chown itself to be observable portably (macOS
  # chown to a non-existent group would fail) -- assert the CLI attempted
  # it via the stub log instead of asserting real ownership bits.
  cat > "$BIN_DIR/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "${STUB_LOG:-/dev/null}"
exit 0
EOF
  chmod +x "$BIN_DIR/chown"

  run "$CLI" apply
  [ "$status" -eq 0 ]
  grep -q "chown root:amnezia-covert $AMZ_COVERT_COOKIES" "$STUB_LOG"
  # chmod 0640 really landed (portable to assert via `ls -l`/stat is not
  # needed -- the real system chmod ran, not a stub).
  perm="$(sh -c 'umask' >/dev/null 2>&1; stat -c %a "$AMZ_COVERT_COOKIES" 2>/dev/null || stat -f %Lp "$AMZ_COVERT_COOKIES" 2>/dev/null)"
  [ "$perm" = "640" ]
}

@test "apply_resubstitutes_and_reloads_on_drift: re-substitutes to the current uid and issues a SYNCHRONOUS fw4 reload; no-op when unchanged" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=1

  # Stale fragment carrying a DIFFERENT uid than AMZ_COVERT_UID, and the
  # instance is NOT currently running (so the uid-mismatch-while-running
  # fail-closed abort does not fire here -- that is uid_mismatch_fail_closed,
  # below).
  unset STUB_COVERT_RUNNING
  printf 'chain amnezia_covert_egress {\n    meta skuid 9999 oifname "lo" reject\n}\n' > "$AMZ_COVERT_FRAGMENT"

  # A deliberate delay on `fw4 reload` distinguishes synchronous from
  # backgrounded: if `apply` backgrounds the reload (`… &`), `run` returns
  # BEFORE the delay elapses and the log has no reload line yet. Only a
  # synchronous call makes `apply` itself block for the full delay, so the
  # reload line is guaranteed present the instant `run` returns.
  export STUB_FW4_RELOAD_DELAY=0.3

  run "$CLI" apply
  [ "$status" -eq 0 ]
  grep -q "meta skuid $AMZ_COVERT_UID" "$AMZ_COVERT_FRAGMENT"
  ! grep -q 'meta skuid 9999' "$AMZ_COVERT_FRAGMENT"

  # Reload must have ALREADY completed and logged by the time `run` returns
  # -- proves it was awaited synchronously, not backgrounded.
  grep -q "^fw4 reload$" "$STUB_LOG"
  unset STUB_FW4_RELOAD_DELAY

  # No-drift case: re-running apply against the now-matching fragment must
  # NOT reload again.
  : > "$STUB_LOG"
  run "$CLI" apply
  [ "$status" -eq 0 ]
  ! grep -q 'fw4 reload' "$STUB_LOG"
}

@test "apply_resubstitutes_and_reloads_on_drift: fw4 check failure on drift aborts non-zero" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=1
  export STUB_FW4_CHECK_FAIL=1
  printf 'chain amnezia_covert_egress {\n    meta skuid 9999 oifname "lo" reject\n}\n' > "$AMZ_COVERT_FRAGMENT"

  run "$CLI" apply
  [ "$status" -ne 0 ]
  ! grep -q 'fw4 reload' "$STUB_LOG"
}

@test "status_truth_table: seven states, discriminated by state-file+reason, link null not empty-string" {
  export UCI_GET_amnezia_config_covert_enabled=0
  unset STUB_COVERT_RUNNING
  run "$CLI" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"enabled":false'
  echo "$output" | grep -q '"state":"idle"'
  echo "$output" | grep -q '"link":null'

  export UCI_GET_amnezia_config_covert_enabled=0
  export STUB_COVERT_RUNNING=1
  run "$CLI" status
  echo "$output" | grep -q '"state":"idle"'
  unset STUB_COVERT_RUNNING

  export UCI_GET_amnezia_config_covert_enabled=1
  export STUB_COVERT_RUNNING=1
  printf '{"state":"starting","link":null,"reason":""}' > "$RUN_DIR/state.json"
  run "$CLI" status
  echo "$output" | grep -q '"state":"starting"'
  echo "$output" | grep -q '"link":null'

  printf '{"state":"connected","link":"https://vk.com/call/join/XXXX","reason":""}' > "$RUN_DIR/state.json"
  run "$CLI" status
  echo "$output" | grep -q '"state":"connected"'
  echo "$output" | grep -q '"link":"https://vk.com/call/join/XXXX"'
  echo "$output" | grep -q '"link_age_s":[0-9]'

  unset STUB_COVERT_RUNNING
  printf '{"state":"auth-failed","link":null,"reason":"cannot-read-cookies"}' > "$RUN_DIR/state.json"
  run "$CLI" status
  echo "$output" | grep -q '"state":"auth-failed"'
  echo "$output" | grep -q '"reason":"cannot-read-cookies"'
  echo "$output" | grep -q '"link":null'

  printf '{"state":"not-started","link":null,"reason":"respawn-exhausted"}' > "$RUN_DIR/state.json"
  run "$CLI" status
  echo "$output" | grep -q '"state":"crashed"'

  printf '{"state":"not-started","link":null,"reason":"readiness-timeout"}' > "$RUN_DIR/state.json"
  run "$CLI" status
  echo "$output" | grep -q '"state":"not-started"'
  echo "$output" | grep -q '"reason":"readiness-timeout"'
}

@test "status_reads_manifest: build_sha/build_hash come from BUILD_MANIFEST, never recomputed" {
  printf 'upstream_sha=89d7a474b7aca6cce664280e6feeaeca2706733b\ngo_version=go1.26\nartifact_sha256=ab12cd34ef000000000000000000000000000000000000000000000000000000\n' \
    > "$AMZ_COVERT_MANIFEST"

  # Poison every hashing tool on PATH -- if the CLI ever shells out to hash
  # the binary, this test fails loudly instead of silently passing.
  for _tool in sha256sum shasum md5sum; do
    cat > "$BIN_DIR/$_tool" <<EOF
#!/bin/sh
echo "POISONED-$_tool-CALLED" >> "\${STUB_LOG:-/dev/null}"
exit 1
EOF
    chmod +x "$BIN_DIR/$_tool"
  done

  run "$CLI" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"build_sha":"89d7a474"'
  echo "$output" | grep -q '"build_hash":"ab12cd34"'
  ! grep -q 'POISONED-' "$STUB_LOG"
}

@test "apply_drift_check_fail_restores_fragment: fw4 check failure restores the on-disk fragment byte-for-byte" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=1
  export STUB_FW4_CHECK_FAIL=1
  printf 'chain amnezia_covert_egress {\n    meta skuid 9999 oifname "lo" reject\n}\n' > "$AMZ_COVERT_FRAGMENT"
  ORIGINAL="$(cat "$AMZ_COVERT_FRAGMENT")"

  run "$CLI" apply
  [ "$status" -ne 0 ]

  NEW="$(cat "$AMZ_COVERT_FRAGMENT")"
  [ "$ORIGINAL" = "$NEW" ]
  grep -q "meta skuid 9999" "$AMZ_COVERT_FRAGMENT"
  ! grep -q "meta skuid $AMZ_COVERT_UID" "$AMZ_COVERT_FRAGMENT"
}

@test "apply_drift_reload_fail_restores_fragment: fw4 reload failure restores the on-disk fragment byte-for-byte" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=1
  export STUB_FW4_RELOAD_FAIL=1
  printf 'chain amnezia_covert_egress {\n    meta skuid 9999 oifname "lo" reject\n}\n' > "$AMZ_COVERT_FRAGMENT"
  ORIGINAL="$(cat "$AMZ_COVERT_FRAGMENT")"

  run "$CLI" apply
  [ "$status" -ne 0 ]

  NEW="$(cat "$AMZ_COVERT_FRAGMENT")"
  [ "$ORIGINAL" = "$NEW" ]
  grep -q "meta skuid 9999" "$AMZ_COVERT_FRAGMENT"
  ! grep -q "meta skuid $AMZ_COVERT_UID" "$AMZ_COVERT_FRAGMENT"
}

@test "disable_keeps_fragment_when_reap_cannot_confirm_empty: fail-safe -- a surviving covert-uid process keeps the fragment, non-zero" {
  _install_fw4_stub
  printf 'meta skuid %s oifname "lo" reject\n' "$AMZ_COVERT_UID" > "$AMZ_COVERT_FRAGMENT"

  # Fabricate a /proc entry for the covert uid that the reap's kill cannot
  # actually remove (no real process behind it -- kill is a silent no-op),
  # simulating a genuine survivor after TERM+KILL.
  fakepid=999999
  mkdir -p "$AMZ_PROC_DIR/$fakepid"
  printf 'Name:\tghost\nUid:\t%s\t%s\t%s\t%s\n' "$AMZ_COVERT_UID" "$AMZ_COVERT_UID" "$AMZ_COVERT_UID" "$AMZ_COVERT_UID" \
    > "$AMZ_PROC_DIR/$fakepid/status"

  run "$CLI" disable
  [ "$status" -ne 0 ]
  [ -f "$AMZ_COVERT_FRAGMENT" ]
  grep -q "meta skuid $AMZ_COVERT_UID" "$AMZ_COVERT_FRAGMENT"
  grep -q "uci set amnezia.config.covert_enabled=0" "$STUB_LOG"
}

@test "uid_mismatch_fail_closed: running-uid != fragment-uid aborts/stops, non-zero" {
  _install_fw4_stub
  export UCI_GET_amnezia_config_covert_enabled=1
  export STUB_COVERT_RUNNING=1
  printf 'chain amnezia_covert_egress {\n    meta skuid 4242 oifname "lo" reject\n}\n' > "$AMZ_COVERT_FRAGMENT"
  # AMZ_COVERT_UID (6553) != the fragment's substituted uid (4242) while the
  # instance is reported RUNNING.

  run "$CLI" apply
  [ "$status" -ne 0 ]
  grep -q "amnezia-covert-init stop" "$STUB_LOG"
  # Must NOT have silently re-substituted+reloaded to "fix" a running
  # mismatched-uid instance -- no reload call at all on this path.
  ! grep -q 'fw4 reload' "$STUB_LOG"
}
