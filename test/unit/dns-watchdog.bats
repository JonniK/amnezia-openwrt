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

@test "status emits JSON and never calls apply" {
  run sh -c "AMNEZIA_VERIFY_DOT=pass sh '$CTL' status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"active_tier"'
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}
