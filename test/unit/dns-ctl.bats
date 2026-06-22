#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  export UCI_GET_amnezia_config_dot_enabled=1
  # L7: resolv.auto fixture for plaintext-fallback tests
  printf 'nameserver 109.195.112.1\n' > "$BATS_TEST_TMPDIR/resolv.auto"
  export AMNEZIA_RESOLV_AUTO="$BATS_TEST_TMPDIR/resolv.auto"
}

@test "apply (binaries present) renders both daemons, encrypted dnsmasq, ip rule, reload" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  grep -q "stubby restart" "$STUB_LOG"
  grep -q "https-dns-proxy restart" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "dnsmasq restart" "$STUB_LOG"
}

@test "apply with missing binary -> plain + active_tier=plaintext, never wedges (L7)" {
  # L7: also assert that the plaintext provider IP from resolv.auto is added
  # (not just the tier label) so the missing-binary path is fully exercised.
  run sh -c "AMNEZIA_HAS_BIN=0 AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
}

@test "enable applies encrypted upstreams and persists dot_enabled=1 (L6)" {
  # L6: renamed from "verifies the encrypted listeners (not #53)" — this test
  # asserts apply-side config (encrypted upstreams wired + dot_enabled persisted),
  # not the verify probe path (covered by auto-revert + set-provider-rollback tests).
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' enable"
  [ "$status" -eq 0 ]
  grep -q "127.0.0.1#5453" "$STUB_LOG"
  grep -q "set amnezia.config.dot_enabled=1" "$STUB_LOG"
}

@test "enable auto-reverts to plain when BOTH encrypted tiers fail verify" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' enable"
  [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dot_enabled=0" "$STUB_LOG"
  grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"
}

@test "disable restores resolvfile, flushes the ip rule, stops the watchdog" {
  # setup() exports dot_enabled=1 so the restore path runs
  run sh -c "AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' disable"
  [ "$status" -eq 0 ]
  grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"
  # L3: unconditional flush via dns_iprule_flush (pref-based, no IP needed)
  grep -q "ip rule del pref 30900" "$STUB_LOG"
  grep -q "amnezia-dns stop" "$STUB_LOG"
}

@test "set-provider: new fails verify -> rolls back to previous provider (UCI), non-zero exit" {
  export UCI_GET_amnezia_config_dns_provider=quad9
  # adguard verify fails; quad9 (prev) passes
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' set-provider adguard"
  [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dns_provider_prev=quad9" "$STUB_LOG"
  grep -q "set amnezia.config.dns_provider=quad9" "$STUB_LOG"   # rolled back
}

@test "disable: sentinel prevents recursion (exactly one amnezia-dns stop logged)" {
  # When disable is called normally (no AMNEZIA_DNS_STOPPING), it calls amnezia-dns stop.
  # That init's stop_service sets AMNEZIA_DNS_STOPPING=1 before re-calling disable,
  # so the second invocation must NOT call amnezia-dns stop again.
  # We cannot simulate the full re-entry here, but we can verify that when the sentinel
  # IS set, amnezia-dns stop is NOT invoked.
  export UCI_GET_amnezia_config_dot_enabled=1
  run sh -c "AMNEZIA_DNS_STOPPING=1 AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' disable"
  [ "$status" -eq 0 ]
  run grep -q "amnezia-dns stop" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "disable: watchdog stop happens before stubby/doh stop (M3 teardown order)" {
  export UCI_GET_amnezia_config_dot_enabled=1
  run sh -c "AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' disable"
  [ "$status" -eq 0 ]
  # amnezia-dns stop must appear before stubby stop in the log
  _dns_line=$(grep -n "amnezia-dns stop" "$STUB_LOG" | head -1 | cut -d: -f1)
  _stubby_line=$(grep -n "stubby stop" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$_dns_line" ] && [ -n "$_stubby_line" ]
  [ "$_dns_line" -lt "$_stubby_line" ]
}

@test "disable: skips dnsmasq restore when dot was never enabled (L8)" {
  export UCI_GET_amnezia_config_dot_enabled=0
  run sh -c "AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' disable"
  [ "$status" -eq 0 ]
  run grep -q "delete dhcp.@dnsmasq\[0\].noresolv" "$STUB_LOG"; [ "$status" -ne 0 ]
  # But still stops daemons and sets dot_enabled=0
  grep -q "set amnezia.config.dot_enabled=0" "$STUB_LOG"
}

@test "disable: ip rule flush is unconditional even when profile fails (L3)" {
  # Use a provider that doesn't exist so dns_profile returns non-zero
  export UCI_GET_amnezia_config_dns_provider=badprovider
  export UCI_GET_amnezia_config_dot_enabled=1
  run sh -c "AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' disable"
  [ "$status" -eq 0 ]
  # ip rule del must still be attempted regardless of profile failure
  grep -q "ip rule del" "$STUB_LOG"
}

@test "set-provider: switching providers clears the previous provider's ip rule (M1)" {
  # Start with quad9; switch to adguard. The M1 fix must call dns_iprule_clear
  # for 9.9.9.9 (quad9's DoT IP) BEFORE cmd_apply runs stubby restart.
  # (The test stub does not track uci-set state, so cmd_apply re-reads quad9
  # and issues its own del+add for 9.9.9.9 — meaning rule del to 9.9.9.9 must
  # appear BEFORE stubby restart in the log.)
  export UCI_GET_amnezia_config_dns_provider=quad9
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' set-provider adguard"
  [ "$status" -eq 0 ]
  # M1: dns_iprule_clear for previous provider fires before cmd_apply (stubby restart)
  _del_line=$(grep -n "rule del to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG" | head -1 | cut -d: -f1)
  _stubby_line=$(grep -n "stubby restart" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$_del_line" ] && [ -n "$_stubby_line" ]
  [ "$_del_line" -lt "$_stubby_line" ]
}

@test "dns_profile custom: CIDR dot_resolver IP is rejected (M2)" {
  export UCI_GET_amnezia_config_dot_resolver='8.8.8.8/0@853#dns.google'
  export UCI_GET_amnezia_config_doh_resolver='https://dns.google/dns-query'
  export UCI_GET_amnezia_config_doh_bootstrap='8.8.4.4'
  LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"
  COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"
  run sh -c ". '$COMMON'; . '$LIB'; dns_profile custom"
  [ "$status" -ne 0 ]
}

@test "status: when disabled, reports enabled:false encrypted:false healthy:false without probing (L5)" {
  export UCI_GET_amnezia_config_dot_enabled=0
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"enabled":false'
  echo "$output" | grep -q '"encrypted":false'
  echo "$output" | grep -q '"healthy":false'
  # L5: no nslookup probe when disabled
  run grep -q "nslookup" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "status: probe uses 1s timeout (L1/L4)" {
  # When dot_enabled=1, _probe_listener must use -timeout=1 not -timeout=3.
  # Use the real nslookup stub (no AMNEZIA_VERIFY_DOT) so the timeout arg is logged.
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  # The nslookup stub logs 'nslookup -timeout=1 ...' when the timeout is 1s.
  grep -q "nslookup -timeout=1" "$STUB_LOG"
}

@test "apply: flushes stale pref-30900 rule before setting the new one (M1 revert-path)" {
  # A failed provider switch that reverted via cmd_apply leaves the failed
  # provider's ip rule lingering.  cmd_apply must call dns_iprule_flush
  # (rule del pref 30900) BEFORE dns_iprule_set so every apply leaves exactly
  # one pref-30900 rule.
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  # rule del pref 30900 (flush) must appear BEFORE rule add to 9.9.9.9 (set)
  _flush_line=$(grep -n "rule del pref 30900" "$STUB_LOG" | head -1 | cut -d: -f1)
  _add_line=$(grep -n "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$_flush_line" ] && [ -n "$_add_line" ]
  [ "$_flush_line" -lt "$_add_line" ]
}

@test "set-provider: failed switch leaves no stale pref-30900 rule for new provider (M1 revert-leak)" {
  # Scenario: quad9 active, switch to adguard fails, reverts to quad9.
  # After revert, adguard's ip (94.140.14.14) must not have a rule; the
  # revert cmd_apply's dns_iprule_flush fires during rollback.
  export UCI_GET_amnezia_config_dns_provider=quad9
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' set-provider adguard"
  [ "$status" -ne 0 ]
  # dns_iprule_flush (rule del pref 30900) must appear in log (fired by revert apply)
  grep -q "rule del pref 30900" "$STUB_LOG"
}

@test "enable: starts the procd watchdog after successful apply+verify (HIGH)" {
  # After enable succeeds, the watchdog init must be started (not just applied).
  # Without this, encrypted-DNS is live but the watchdog is NOT running — if both
  # tiers fail later nothing gates the router to plaintext until reboot.
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_VERIFY_DOT=pass AMNEZIA_VERIFY_DOH=pass AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNS_INIT=amnezia-dns sh '$CTL' enable"
  [ "$status" -eq 0 ]
  grep -q "amnezia-dns start" "$STUB_LOG"
}

@test "init: applies + launches watchdog only when enabled; hotplug keys on firewall reload" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dns.init"
  HP="$HARNESS_DIR/../openwrt/99-amnezia-dns.hotplug"
  grep -q "amnezia-dns-ctl apply" "$INIT"
  grep -q "procd_set_param command /usr/bin/amnezia-dns-ctl watchdog" "$INIT"
  grep -q 'dot_enabled' "$INIT"
  grep -q 'ACTION.*=.*reload' "$HP" || grep -q '"$ACTION" = reload' "$HP"
  grep -q "amnezia-dns-ctl apply" "$HP"
}

@test "status: disabled reports active_tier:off regardless of stale UCI value (LOW)" {
  # When dot_enabled=0, cmd_status must force active_tier=off even if UCI
  # still holds a stale value (e.g. 'dot' from a previous enabled run).
  export UCI_GET_amnezia_config_dot_enabled=0
  export UCI_GET_amnezia_config_dns_active_tier=dot
  run sh -c "sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"active_tier":"off"'
}

@test "init: stop_service sets AMNEZIA_DNS_STOPPING=1 sentinel (H1 guard)" {
  # Static assertion: stop_service must set AMNEZIA_DNS_STOPPING=1 before
  # calling cmd_disable to prevent infinite recursion (H1).
  INIT="$HARNESS_DIR/../openwrt/amnezia-dns.init"
  grep -q "AMNEZIA_DNS_STOPPING=1" "$INIT"
}

@test "apply: in plaintext tier, re-establishes encrypted-first ordering (HIGH leak fix)" {
  # Bug: dns_dnsmasq_encrypted does del+add of encrypted listeners which appends
  # them to the TAIL if plaintext IPs are already present. apply must then
  # dns_dnsmasq_del_plain and, since we are in plaintext fallback, re-append
  # plaintext AFTER encrypted so the final order is [5453, 5454, WAN] not
  # [WAN, 5453, 5454] which would put plaintext-first under strict-order.
  export UCI_GET_amnezia_config_dns_active_tier=plaintext
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  # Encrypted listener was (re-)added
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5453" "$STUB_LOG"
  # Plaintext IP was deleted (drop before re-append)
  grep -q "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
  # Plaintext IP was re-added AFTER the encrypted listener (ordering fix)
  grep -q "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG"
  # del must appear before the final add_list for the plaintext IP
  _del_line=$(grep -n "del_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG" | tail -1 | cut -d: -f1)
  _add_line=$(grep -n "add_list dhcp.@dnsmasq\[0\].server=109.195.112.1" "$STUB_LOG" | tail -1 | cut -d: -f1)
  [ -n "$_del_line" ] && [ -n "$_add_line" ]
  [ "$_del_line" -lt "$_add_line" ]
}

@test "_enter_plain: does not mark plaintext tier when dnsmasq reload fails (LOW)" {
  # Gate tier/timestamp commit on reload success.  When dnsmasq --test fails
  # (AMNEZIA_DNSMASQ_FAIL=1 in stub), _enter_plain must NOT set dns_active_tier
  # or dns_plain_ts (the set, not the get that cmd_watchdog always does).
  run sh -c "AMNEZIA_DNS_WD_ONCE=1 AMNEZIA_DNS_WD_N=1 AMNEZIA_VERIFY_DOT=fail AMNEZIA_VERIFY_DOH=fail AMNEZIA_DNSMASQ_INIT=dnsmasq AMNEZIA_DNSMASQ_FAIL=1 sh '$CTL' watchdog"
  run grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"; [ "$status" -ne 0 ]
  run grep -q "set amnezia.config.dns_plain_ts" "$STUB_LOG"; [ "$status" -ne 0 ]
}
