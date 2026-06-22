#!/usr/bin/env bats
load '../lib/harness.bash'
CTL="$HARNESS_DIR/../openwrt/amnezia-dns-ctl.sh"

setup() {
  export AMNEZIA_LIB="$HARNESS_DIR/../openwrt/lib"
  export UCI_GET_amnezia_config_dns_provider=quad9
  export UCI_GET_amnezia_config_dot_enabled=1
}

@test "apply (binaries present) renders both daemons, encrypted dnsmasq, ip rule, reload" {
  run sh -c "AMNEZIA_HAS_BIN=1 AMNEZIA_STUBBY_INIT=stubby AMNEZIA_DOH_INIT=https-dns-proxy AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  grep -q "stubby restart" "$STUB_LOG"
  grep -q "https-dns-proxy restart" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "dnsmasq restart" "$STUB_LOG"
}

@test "apply with missing binary -> plain + active_tier=plaintext, never wedges" {
  run sh -c "AMNEZIA_HAS_BIN=0 AMNEZIA_DNSMASQ_INIT=dnsmasq sh '$CTL' apply"
  [ "$status" -eq 0 ]
  run grep -q "stubby restart" "$STUB_LOG"; [ "$status" -ne 0 ]
  grep -q "set amnezia.config.dns_active_tier=plaintext" "$STUB_LOG"
}

@test "enable verifies the encrypted listeners (not #53) and persists enabled" {
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

@test "init: applies + launches watchdog only when enabled; hotplug keys on firewall reload" {
  INIT="$HARNESS_DIR/../openwrt/amnezia-dns.init"
  HP="$HARNESS_DIR/../openwrt/99-amnezia-dns.hotplug"
  grep -q "amnezia-dns-ctl apply" "$INIT"
  grep -q "procd_set_param command /usr/bin/amnezia-dns-ctl watchdog" "$INIT"
  grep -q 'dot_enabled' "$INIT"
  grep -q 'ACTION.*=.*reload' "$HP" || grep -q '"$ACTION" = reload' "$HP"
  grep -q "amnezia-dns-ctl apply" "$HP"
}
