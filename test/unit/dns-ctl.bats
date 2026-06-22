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
