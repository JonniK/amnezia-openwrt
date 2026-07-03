#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
setup() { export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  export UCI_GET_amnezia_config_dot_enabled=1
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
  # Regression guard: if _set_tier plaintext is moved outside the lock (e.g. after
  # the success-branch dnsmasq_unlock), a cross-process interleave can leave UCI
  # saying plaintext while dnsmasq has no plaintext server — DNS hard-down.
  #
  # Robust approach: extract the _enter_plain body (from its opening line to the
  # closing '^}') and work only within that body. Assert that the FIRST
  # dnsmasq_unlock in the body comes AFTER _set_tier plaintext.
  # This catches the mutation "swap _set_tier and dnsmasq_unlock in success branch"
  # even when a second dnsmasq_unlock exists in the failure branch further down.
  _src="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
  # Start line of the function body (line after '^_enter_plain() {')
  _func_start=$(grep -n '^_enter_plain()' "$_src" | head -1 | cut -d: -f1)
  # Extract the function body (from func_start+1 to closing '^}')
  _body=$(awk "NR > $_func_start { if (/^\}/) exit; print NR, \$0 }" "$_src")
  # Line number of _set_tier plaintext within the body (absolute file line)
  _set_line=$(echo "$_body" | awk '/_set_tier plaintext/{print $1; exit}')
  # Line number of the FIRST dnsmasq_unlock within the body (absolute file line)
  _first_unlock=$(echo "$_body" | awk '/dnsmasq_unlock/{print $1; exit}')
  [ -n "$_set_line" ] || { echo "FAIL: _set_tier plaintext not found in _enter_plain body" >&2; false; }
  [ -n "$_first_unlock" ] || { echo "FAIL: dnsmasq_unlock not found in _enter_plain body" >&2; false; }
  # _set_tier must come BEFORE the first dnsmasq_unlock in the function
  [ "$_set_line" -lt "$_first_unlock" ]
}

@test "structural: _exit_plain commits tier INSIDE the lock (before dnsmasq_unlock)" {
  # Regression guard: the tier-restore in _exit_plain must be inside the fd-8
  # lock (committed before success-branch dnsmasq_unlock), so apply's
  # plaintext-gate reads a consistent state.
  #
  # Robust approach: extract the _exit_plain body and assert _set_tier comes
  # before the FIRST dnsmasq_unlock in the body. The function has two unlock
  # calls (success + failure branch); using "first unlock in body" catches the
  # mutation even when a second unlock exists further down.
  _src="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"
  _func_start=$(grep -n '^_exit_plain()' "$_src" | head -1 | cut -d: -f1)
  _body=$(awk "NR > $_func_start { if (/^\}/) exit; print NR, \$0 }" "$_src")
  _set_line=$(echo "$_body" | awk '/_set_tier/{print $1; exit}')
  _first_unlock=$(echo "$_body" | awk '/dnsmasq_unlock/{print $1; exit}')
  [ -n "$_set_line" ] || { echo "FAIL: _set_tier not found in _exit_plain body" >&2; false; }
  [ -n "$_first_unlock" ] || { echo "FAIL: dnsmasq_unlock not found in _exit_plain body" >&2; false; }
  # _set_tier must come BEFORE the first dnsmasq_unlock in the function
  [ "$_set_line" -lt "$_first_unlock" ]
}

@test "empty resolv.conf.auto: _enter_plain falls back to AMNEZIA_FALLBACK_DNS, tier=plaintext" {
  # Regression guard: when DHCP provides no nameservers, _resolv_provider_ips
  # returns nothing.  Without the fallback, dns_dnsmasq_add_plain adds ZERO
  # servers while dnsmasq is in noresolv+strict-order -> total DNS outage.
  # Fix: _effective_provider_ips falls back to AMNEZIA_FALLBACK_DNS (8.8.8.8 1.1.1.1).
  # Set resolv.auto to an empty file so _resolv_provider_ips returns nothing.
  printf '' > "$BATS_TEST_TMPDIR/resolv.auto"
  export AMNEZIA_RESOLV_AUTO="$BATS_TEST_TMPDIR/resolv.auto"
  # Force plaintext path: both encrypted probes fail, N=1.
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # Plaintext tier must be committed.
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
  # Fallback resolver 8.8.8.8 must be added (not the empty resolv.auto).
  grep -q "add_list dhcp.@dnsmasq\[0\].server=8.8.8.8" "$STUB_LOG"
}

@test "disabled watchdog: dot_enabled=0 breaks loop immediately, never enters plaintext" {
  # Regression guard for tier-resurrection race: when cmd_disable signals the
  # watchdog (via procd stop), a late tick already past the signal could run
  # _enter_plain and commit dns_active_tier=plaintext. The fix re-reads
  # dot_enabled at the TOP of each iteration and breaks when it is no longer 1.
  # With dot_enabled=0 and both probes failing + N=1 + TICKS=3 the watchdog
  # must exit immediately on the first iteration WITHOUT ever calling _enter_plain.
  run sh -c "UCI_GET_amnezia_config_dot_enabled=0 AMNEZIA_DNS_WD_TICKS=3 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' watchdog"
  [ "$status" -eq 0 ]
  # Must NOT have written plaintext tier
  run grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
}
