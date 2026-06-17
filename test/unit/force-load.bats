#!/usr/bin/env bats
load '../lib/harness.bash'
SCRIPT="$HARNESS_DIR/../openwrt/amnezia-force-load.sh"
setup() {
  export FORCE_DIR="$BATS_TEST_TMPDIR/amnezia"; mkdir -p "$FORCE_DIR/force.d"
  export AMNEZIA_FAILOVER_INIT="amnezia-failover-init"   # P0 stub
  # Route dnsmasq init calls through the stub so we can assert on them.
  # (dnsmasq restart is SSH-safe unlike fw4 reload; kept synchronous.)
  export AMNEZIA_DNSMASQ_INIT="dnsmasq"
}

@test "force-load classifies IP/CIDR into the set and domains into config ipset" {
  printf '8.8.8.8\n1.2.3.0/24\nexample.com\n# comment\n\n' > "$FORCE_DIR/force.d/itdoginfo_inside.list"
  printf 'manual.example\n9.9.9.9\n' > "$FORCE_DIR/force-tunnel.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # all stubs (nft/uci/dnsmasq) record to the single $STUB_LOG
  grep -q 'amnezia_force4.*8.8.8.8' "$STUB_LOG"
  grep -q 'amnezia_force4.*1.2.3.0/24' "$STUB_LOG"
  grep -q 'amnezia_force4.*9.9.9.9' "$STUB_LOG"
  grep -q 'add_list dhcp.amnezia_force.domain=example.com' "$STUB_LOG"
  grep -q 'add_list dhcp.amnezia_force.domain=manual.example' "$STUB_LOG"
}

@test "force-load restarts dnsmasq only when the domain set changed" {
  printf 'a.example\n' > "$FORCE_DIR/force-tunnel.list"
  sh "$SCRIPT"; : > "$STUB_LOG"
  sh "$SCRIPT"                                   # no change — must NOT restart
  run grep -q 'dnsmasq.*restart' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "restarted w/o change"; false; }
  printf 'a.example\nb.example\n' > "$FORCE_DIR/force-tunnel.list"
  : > "$STUB_LOG"; sh "$SCRIPT"                   # domain added — must restart
  grep -q 'dnsmasq.*restart' "$STUB_LOG"
}

@test "save-manual writes the manual file without touching auto caches, then loads" {
  printf 'AUTO\n' > "$FORCE_DIR/force.d/x.list"
  run sh "$SCRIPT" save-manual "$(printf 'one.example\ntwo.example')"
  [ "$status" -eq 0 ]
  grep -q one.example "$FORCE_DIR/force-tunnel.list"
  grep -q AUTO "$FORCE_DIR/force.d/x.list"        # auto cache untouched
}

# H2: hotplug (IP-only invocation) must not touch dhcp config or restart dnsmasq.
@test "H2: repeated invocation with unchanged domains skips uci-commit and dnsmasq restart" {
  # Prime the hash so the second call sees no change.
  printf 'a.example\n1.2.3.4\n' > "$FORCE_DIR/force-tunnel.list"
  sh "$SCRIPT"                    # first call: commits dhcp, restarts dnsmasq, writes hash
  : > "$STUB_LOG"
  # Second call: domains unchanged, only IPs matter (simulates hotplug).
  sh "$SCRIPT"
  # nft flush/add must still happen (IP repopulation).
  grep -q 'nft.*amnezia_force4' "$STUB_LOG"
  # But NO uci commit dhcp and NO dnsmasq restart.
  run grep -q 'uci commit dhcp' "$STUB_LOG";    [ "$status" -ne 0 ] || { echo "unexpected uci commit dhcp"; false; }
  run grep -q 'dnsmasq.*restart' "$STUB_LOG";   [ "$status" -ne 0 ] || { echo "unexpected dnsmasq restart"; false; }
}

# H3: malformed IP/CIDR lines must be skipped; valid lines in the same file must load.
@test "H3: malformed IP lines are skipped; valid IPs in the same file still load" {
  printf '1.2.3.4/24\n999.999.999.999\n1.2.3.4/24x\n5.6.7.8\n' \
    > "$FORCE_DIR/force.d/mixed.list"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  # Valid entries must be in the set.
  grep -q 'amnezia_force4.*1.2.3.4/24' "$STUB_LOG"
  grep -q 'amnezia_force4.*5.6.7.8' "$STUB_LOG"
  # The garbage string must NOT appear in nft add calls.
  run grep '999.999.999.999' "$STUB_LOG"; [ "$status" -ne 0 ] || { echo "bad IP was loaded"; false; }
  run grep '1.2.3.4/24x' "$STUB_LOG";    [ "$status" -ne 0 ] || { echo "bad CIDR was loaded"; false; }
}
