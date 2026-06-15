#!/usr/bin/env bats
load '../lib/harness.bash'

@test "configure-dnsmasq-amnezia.sh emits uci set for ru TLD ipset" {
  AMNEZIA_DRYRUN=1 sh "$HARNESS_DIR/../openwrt/configure-dnsmasq-amnezia.sh"
  grep -q "uci set dhcp.amnezia_ru_tld=ipset" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_ru_tld.name=amnezia_ru_tld4" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_ru_tld.domain=.ru" "$STUB_LOG"
}
@test "configure-dnsmasq-amnezia.sh emits uci set for sticky ipset" {
  AMNEZIA_DRYRUN=1 sh "$HARNESS_DIR/../openwrt/configure-dnsmasq-amnezia.sh"
  grep -q "uci set dhcp.amnezia_sticky=ipset" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_sticky.name=amnezia_sticky4" "$STUB_LOG"
  # Each domain from seed-sticky-domains.list must produce a uci add_list call
  grep -q "uci add_list dhcp.amnezia_sticky.domain=claude.ai" "$STUB_LOG"
  grep -q "uci add_list dhcp.amnezia_sticky.domain=anthropic.com" "$STUB_LOG"
}
@test "configure-dnsmasq-amnezia.sh commits dhcp (not just sets)" {
  AMNEZIA_DRYRUN=1 sh "$HARNESS_DIR/../openwrt/configure-dnsmasq-amnezia.sh"
  grep -q "uci commit dhcp" "$STUB_LOG"
}
