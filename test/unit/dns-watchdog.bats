#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
setup() { export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  printf 'nameserver 109.195.112.1\n' > "$BATS_TEST_TMPDIR/resolv.auto"
  export AMNEZIA_RESOLV_AUTO="$BATS_TEST_TMPDIR/resolv.auto"
}

@test "DoT up -> active_tier=dot, no plaintext" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"
  run grep -q "dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "DoT down, DoH up -> active_tier=doh, still no plaintext" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=doh" "$STUB_LOG"
  run grep -q "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "both down for N=1 -> enters plaintext with live-read provider IP" {
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
}

@test "recovery: in plaintext, an encrypted tier up for M with dwell elapsed exits plaintext" {
  # M4/M6: dwell is loaded from persisted dns_plain_ts; set ts=1000, now=99999 so
  # elapsed >> 120s and the dwell is satisfied.
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  export UCI_GET_amnezia_config_dns_plain_ts=1000
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_M=1 AMNEZIA_NOW=99999 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
  grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"
}

@test "N-threshold: 2 ticks with N=3 does NOT enter plaintext (accumulation not reached)" {
  # H2: drop the _fail >= _n guard and this test breaks (tier would enter plain after 1 fail).
  run sh -c "AMNEZIA_DNS_WD_TICKS=2 AMNEZIA_DNS_WD_N=3 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  run grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "N-threshold: 3 ticks with N=3 DOES enter plaintext (threshold reached)" {
  run sh -c "AMNEZIA_DNS_WD_TICKS=3 AMNEZIA_DNS_WD_N=3 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
}

@test "dwell hold: tier=plaintext, ts=1000, now=1050 (50s < 120s) — plaintext NOT exited" {
  # H2: mutate dwell guard to 'true' and this test breaks (would exit plain despite not elapsed).
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  export UCI_GET_amnezia_config_dns_plain_ts=1000
  run sh -c "AMNEZIA_DNS_WD_TICKS=1 AMNEZIA_DNS_WD_M=1 AMNEZIA_NOW=1050 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # del_list of provider IP = exit-plain signal; must NOT be present
  run grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"; [ "$status" -ne 0 ]
  # tier must remain plaintext (no dns_active_tier=dot logged)
  run grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "dwell elapsed: tier=plaintext, ts=1000, now=1200 (200s >= 120s) — plaintext IS exited" {
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  export UCI_GET_amnezia_config_dns_plain_ts=1000
  run sh -c "AMNEZIA_DNS_WD_TICKS=1 AMNEZIA_DNS_WD_M=1 AMNEZIA_NOW=1200 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
  grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"
}

@test "M-hysteresis: tier=plaintext, M=2, TICKS=1 — plaintext NOT exited (_ok=1 < 2)" {
  # Mutation-coverage: if `[ "$_ok" -ge "$_m" ] &&` is deleted from the exit guard,
  # the watchdog would exit plaintext after the first consecutive OK. This test
  # catches that mutation because with TICKS=1 only one OK tick runs (_ok=1),
  # which is < M=2, so plaintext must be retained.
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  export UCI_GET_amnezia_config_dns_plain_ts=1000
  run sh -c "AMNEZIA_DNS_WD_TICKS=1 AMNEZIA_DNS_WD_M=2 AMNEZIA_NOW=99999 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # del_list of provider IP = exit-plain signal; must NOT be present (_ok=1 < M=2)
  run grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"; [ "$status" -ne 0 ]
  # dns_active_tier must NOT flip to dot
  run grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "M-hysteresis: tier=plaintext, M=2, TICKS=2 — plaintext IS exited on 2nd OK (_ok=2 >= 2)" {
  # Companion to the TICKS=1 test: proves _ok accumulates correctly across ticks
  # and that the exit fires exactly when the threshold is met.
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  export UCI_GET_amnezia_config_dns_plain_ts=1000
  run sh -c "AMNEZIA_DNS_WD_TICKS=2 AMNEZIA_DNS_WD_M=2 AMNEZIA_NOW=99999 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # After 2 consecutive OK ticks with M=2 and dwell elapsed, plaintext must exit
  grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
  grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"
}

@test "watchdog: _enter_plain failure leaves no latch, retries on next tick (HIGH)" {
  # Bug: the watchdog unconditionally latched _tier=plaintext after calling
  # _enter_plain, even when it returned 1 (dnsmasq reload failed). Once latched,
  # the re-entry guard (_tier != plaintext) became permanently false, preventing
  # any retry — DNS stayed hard-down forever.
  # Fix: only latch on success (if _enter_plain; then _tier=plaintext; ...; fi).
  # With AMNEZIA_DNSMASQ_FAIL=1, TICKS=2, N=1:
  # - tick 1: both down, _fail=1 >= N=1, _enter_plain called but fails -> no latch
  # - tick 2: both still down, _fail=2 >= N=1, _enter_plain called again (retry)
  # Assert: dns_active_tier=plaintext is never set (no latch)
  # Assert: dnsmasq --test is attempted TWICE (once per tick, showing retry)
  run sh -c "AMNEZIA_DNS_WD_TICKS=2 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNSMASQ_FAIL=1 sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # No plaintext latch
  run grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
  # _enter_plain retried: dnsmasq called at least twice (--test invoked per tick)
  _dnsmasq_count=$(grep -c "dnsmasq --test" "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$_dnsmasq_count" -ge 2 ]
}

@test "exit-plain reload fail: tier stays plaintext, no dot commit (HIGH)" {
  # Bug: _exit_plain did dns_dnsmasq_reload || true then _set_tier unconditionally.
  # A reload failure left plaintext servers LIVE in dnsmasq but committed the tier
  # as dot/doh — torn state: lying status + no watchdog retry.
  # Fix: gate _set_tier on reload success; on failure return 1 and stay plaintext.
  # Setup: tier=plaintext, dwell elapsed (ts=1000, now=99999), M=1 (exit fires),
  # but AMNEZIA_DNSMASQ_FAIL=1 so the reload inside _exit_plain fails.
  # Assert: dns_active_tier=dot is NOT committed (tier stays plaintext).
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  export UCI_GET_amnezia_config_dns_plain_ts=1000
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_M=1 AMNEZIA_NOW=99999 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNSMASQ_FAIL=1 sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # Tier must NOT be committed as dot — plaintext stays
  run grep -q "set amnezia.config.dns_active_tier=dot" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "status emits JSON and never calls apply" {
  run sh -c "AMNEZIA_VERIFY_DOT=pass sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"active_tier"'
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "structural: _enter_plain commits tier INSIDE the lock (before dnsmasq_unlock)" {
  # Regression guard: if _set_tier plaintext is moved back outside the lock,
  # a cross-process interleave can leave UCI saying plaintext while dnsmasq has
  # no plaintext server — DNS hard-down.  Assert the line number of the
  # '_set_tier plaintext' call inside _enter_plain is less than the line number
  # of the NEXT 'dnsmasq_unlock' call that follows it in the function.
  _src="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
  # Line number of _set_tier plaintext inside _enter_plain
  _set_line=$(grep -n '_set_tier plaintext' "$_src" | head -1 | cut -d: -f1)
  # Line number of the dnsmasq_unlock that follows _set_tier plaintext
  _unlock_line=$(awk "NR > $_set_line && /dnsmasq_unlock/{print NR; exit}" "$_src")
  [ -n "$_set_line" ] && [ -n "$_unlock_line" ]
  [ "$_set_line" -lt "$_unlock_line" ]
}

@test "structural: _exit_plain commits tier INSIDE the lock (before dnsmasq_unlock)" {
  # Regression guard: the tier-restore in _exit_plain must be inside the fd-8
  # lock, so apply's plaintext-gate reads a consistent state.
  _src="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
  # _exit_plain starts at the line with '_exit_plain()'; find _set_tier inside it
  _func_line=$(grep -n '^_exit_plain()' "$_src" | head -1 | cut -d: -f1)
  _set_line=$(awk "NR > $_func_line && /_set_tier/{print NR; exit}" "$_src")
  _unlock_line=$(awk "NR > $_set_line && /dnsmasq_unlock/{print NR; exit}" "$_src")
  [ -n "$_set_line" ] && [ -n "$_unlock_line" ]
  [ "$_set_line" -lt "$_unlock_line" ]
}
