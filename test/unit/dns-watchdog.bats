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

@test "status emits JSON and never calls apply" {
  run sh -c "AMNEZIA_VERIFY_DOT=pass sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"active_tier"'
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}
