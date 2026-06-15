#!/usr/bin/env bats
load '../lib/harness.bash'

@test "first-install wiring copies rt_tables, runs routing_install_rules, enables monitor, installs classifier" {
  UCI_FAKE_TUNNELS="awg1" \
    run sh "$HARNESS_DIR/../openwrt/install-amnezia-pbr.sh" --first-install --dry-run
  # rt_tables
  grep -q "install:rt_tables" "$STUB_LOG"
  # ip rules
  grep -q "ip rule add fwmark" "$STUB_LOG"
  # monitor enabled
  grep -q "/etc/init.d/amnezia-failover enable" "$STUB_LOG"
  # classifier installed
  grep -q "install:classifier" "$STUB_LOG"
  # dnsmasq ipset configured
  grep -q "uci set dhcp.amnezia_ru_tld=ipset" "$STUB_LOG"
}
