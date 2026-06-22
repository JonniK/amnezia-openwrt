#!/usr/bin/env bats
load '../lib/harness.bash'
LIB="$HARNESS_DIR/../openwrt/lib/amnezia-dns-lib.sh"
COMMON="$HARNESS_DIR/../openwrt/lib/amnezia-common.sh"

@test "stub sanity: uci -q get round-trips a bracketed @dnsmasq[0] key" {
  # Guards the recurring trap: the @[]-bracket key must normalize to the env
  # var the reload tests set. If this fails, every candidate-render test is vacuous.
  export UCI_GET_dhcp__dnsmasq_0__server='127.0.0.1#5453'
  run sh -c 'uci -q get dhcp.@dnsmasq[0].server'
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.1#5453" ]
}

@test "dnsmasq lock uses fd 8, never fd 9" {
  grep -Eq 'exec[[:space:]]+8>|flock[[:space:]]+-x[[:space:]]+8' "$LIB"
  run grep -Eq 'exec[[:space:]]+9>|flock[[:space:]]+-x[[:space:]]+9' "$LIB"
  [ "$status" -ne 0 ]
}

@test "ip rule set is idempotent: delete-then-add with table 100 pref 30900" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_iprule_set 9.9.9.9; dns_iprule_set 9.9.9.9"
  [ "$status" -eq 0 ]
  grep -q "rule del to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
  grep -q "rule add to 9.9.9.9 lookup 100 pref 30900" "$STUB_LOG"
}

@test "encrypted dnsmasq: noresolv+strictorder+two loopback servers, no plaintext" {
  run sh -c ". '$COMMON'; . '$LIB'; dns_dnsmasq_encrypted"
  grep -q "set dhcp.@dnsmasq\[0\].noresolv=1" "$STUB_LOG"
  grep -q "set dhcp.@dnsmasq\[0\].strictorder=1" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5453" "$STUB_LOG"
  grep -q "add_list dhcp.@dnsmasq\[0\].server=127.0.0.1#5454" "$STUB_LOG"
}

@test "reload gate: a malformed server in the candidate config blocks restart" {
  export UCI_GET_dhcp__dnsmasq_0__server='not a valid server'
  export UCI_GET_dhcp__dnsmasq_0__noresolv='1'
  run sh -c ". '$COMMON'; . '$LIB'; dns_dnsmasq_reload"
  [ "$status" -ne 0 ]
  run grep -q "dnsmasq restart" "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "reload gate: a valid candidate config restarts dnsmasq" {
  export UCI_GET_dhcp__dnsmasq_0__server='127.0.0.1#5453'
  export UCI_GET_dhcp__dnsmasq_0__noresolv='1'
  export AMNEZIA_DNSMASQ_INIT=dnsmasq
  run sh -c ". '$COMMON'; . '$LIB'; dns_dnsmasq_reload"
  [ "$status" -eq 0 ]
  grep -q "dnsmasq restart" "$STUB_LOG"
}
